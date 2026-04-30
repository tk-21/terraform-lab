# ✅Phase 3: Model Registry承認フロー + 自動デプロイ（CodePipeline + SageMaker Endpoint）

## Phase 1-2で作成したもの（サマリー）

**Phase 1（基盤）**:
- S3: `smp-artifacts-{account_id}`, `smp-data-{account_id}`
- IAM: `smp-pipeline-role`, `smp-endpoint-role`, `smp-lambda-base-role`
- SSM: `/smp/chatwork/room_id`, `/smp/chatwork/api_token`

**Phase 2（Pipeline定義）**:
- SageMaker Model Package Group: `smp-model-group`
- SageMaker Pipeline: `smp-training-pipeline`
  - ProcessingStep（前処理）→ TrainingStep（XGBoost, スポットインスタンス）
  → EvaluationStep → ConditionStep（精度 >= 0.8）→ RegisterModel（`PendingApproval`）
- スクリプト: `preprocess.py`, `train.py`, `evaluate.py`
- サンプルデータ生成: `scripts/generate_sample_data.py`

---

## このフェーズで作成するもの

モデルがModel Registryに `PendingApproval` で登録された後の承認フローと
`Approved` 時の自動デプロイパイプラインを実装する。

---

## タスク一覧

### 1. lambda/approval_notifier/handler.py の実装

Model Registryの承認ステータス変更イベントをChatworkに通知するLambda。

```python
"""
Model Registry承認通知Lambda

設計意図:
- SageMaker Model PackageのステータスがPendingApprovalに変わったとき
  担当者にChatwork通知を送り、承認/却下を促す
- 承認操作はAWSコンソールまたはCLIで実施（このLambdaは通知のみ）
- Lambda Powertoolsで構造化ログ出力
"""
import json
import urllib.parse
import urllib.request
import boto3
from aws_lambda_powertools import Logger, Tracer, Metrics
from aws_lambda_powertools.utilities.typing import LambdaContext

logger = Logger()
tracer = Tracer()
metrics = Metrics(namespace="SMP/ApprovalNotifier")

ssm = boto3.client('ssm', region_name='ap-northeast-1')

def get_ssm_params() -> tuple[str, str]:
    """SSMからChatwork認証情報を取得"""
    response = ssm.get_parameters(
        Names=['/smp/chatwork/room_id', '/smp/chatwork/api_token'],
        WithDecryption=True
    )
    params = {p['Name']: p['Value'] for p in response['Parameters']}
    return params['/smp/chatwork/room_id'], params['/smp/chatwork/api_token']

def send_chatwork_message(room_id: str, api_token: str, message: str) -> None:
    """Chatwork APIにメッセージ送信"""
    url = f"https://api.chatwork.com/v2/rooms/{room_id}/messages"
    data = urllib.parse.urlencode({'body': message}).encode('utf-8')
    req = urllib.request.Request(
        url,
        data=data,
        headers={'X-ChatWorkToken': api_token},
        method='POST'
    )
    with urllib.request.urlopen(req) as resp:
        logger.info("Chatwork通知送信完了", status_code=resp.status)

@logger.inject_lambda_context
@tracer.capture_lambda_handler
def handler(event: dict, context: LambdaContext) -> dict:
    """
    EventBridgeからSageMaker Model Package状態変更イベントを受け取る
    イベント構造: event['detail']['ModelPackageStatus'] == 'PendingApproval'
    """
    logger.info("Model Registry イベント受信", event=event)

    detail = event.get('detail', {})
    model_package_arn = detail.get('ModelPackageArn', 'Unknown')
    model_package_name = detail.get('ModelPackageName', 'Unknown')
    status = detail.get('ModelPackageStatus', 'Unknown')
    group_name = detail.get('ModelPackageGroupName', 'Unknown')

    if status == 'PendingApproval':
        # 承認依頼メッセージ
        message = (
            f"[info][title]🤖 MLOpsパイプライン: モデル承認依頼[/title]"
            f"新しいモデルバージョンがModel Registryに登録されました。\n\n"
            f"📦 モデルグループ: {group_name}\n"
            f"🏷️ バージョン: {model_package_name}\n"
            f"📊 ステータス: PendingApproval\n\n"
            f"✅ 承認コマンド:\n"
            f"aws sagemaker update-model-package \\\n"
            f"  --model-package-arn {model_package_arn} \\\n"
            f"  --model-approval-status Approved\n\n"
            f"❌ 却下コマンド:\n"
            f"aws sagemaker update-model-package \\\n"
            f"  --model-package-arn {model_package_arn} \\\n"
            f"  --model-approval-status Rejected[/info]"
        )
    elif status == 'Approved':
        message = (
            f"[info][title]✅ MLOpsパイプライン: モデル承認済み[/title]"
            f"モデルが承認されました。自動デプロイを開始します。\n\n"
            f"📦 モデルグループ: {group_name}\n"
            f"🏷️ バージョン: {model_package_name}[/info]"
        )
    else:
        logger.info("通知対象外のステータス", status=status)
        return {"statusCode": 200, "body": "skip"}

    room_id, api_token = get_ssm_params()
    send_chatwork_message(room_id, api_token, message)

    metrics.add_metric(name="NotificationSent", unit="Count", value=1)
    return {"statusCode": 200, "body": "notification sent"}
```

### 2. EventBridgeルール（Model Registry承認イベント）

`terraform/modules/registry/main.tf`:

```hcl
# Model Registry承認イベントをLambdaにルーティング
resource "aws_cloudwatch_event_rule" "model_approval" {
  name        = "${local.prefix}-model-approval"
  description = "Model RegistryのPendingApproval/Approved状態変化を検知"

  event_pattern = jsonencode({
    source      = ["aws.sagemaker"]
    detail-type = ["SageMaker Model Package State Change"]
    detail = {
      ModelPackageGroupName = ["${local.prefix}-model-group"]
      ModelPackageStatus    = ["PendingApproval", "Approved", "Rejected"]
    }
  })
  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "approval_notifier" {
  rule = aws_cloudwatch_event_rule.model_approval.name
  arn  = var.approval_notifier_lambda_arn
}

resource "aws_lambda_permission" "eventbridge_approval" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = var.approval_notifier_lambda_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.model_approval.arn
}

# Approvedイベントを検知してCodePipelineをトリガー
resource "aws_cloudwatch_event_rule" "model_approved" {
  name        = "${local.prefix}-model-approved"
  description = "モデル承認時にCodePipelineでデプロイを自動起動"

  event_pattern = jsonencode({
    source      = ["aws.sagemaker"]
    detail-type = ["SageMaker Model Package State Change"]
    detail = {
      ModelPackageGroupName = ["${local.prefix}-model-group"]
      ModelPackageStatus    = ["Approved"]
    }
  })
  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "deploy_pipeline" {
  rule     = aws_cloudwatch_event_rule.model_approved.name
  arn      = "arn:aws:codepipeline:ap-northeast-1:${local.account_id}:${local.prefix}-deploy-pipeline"
  role_arn = aws_iam_role.eventbridge_codepipeline_role.arn
}
```

### 3. SageMaker Endpoint定義

`terraform/modules/endpoint/main.tf`:

```hcl
# SageMaker Endpoint Configuration（Blue/Greenデプロイ設定）
resource "aws_sagemaker_endpoint_configuration" "main" {
  name = "${local.prefix}-endpoint-config"

  production_variants {
    variant_name           = "primary"
    # 日本語コメント: モデルはCodePipeline経由で動的に差し替えるため、
    # initial_instance_countを1に固定。スケールアウトはApplication Auto Scalingで制御
    initial_instance_count = 1
    instance_type          = var.endpoint_instance_type  # default: ml.t2.medium
    initial_variant_weight = 1.0
  }

  # Blue/Greenデプロイ設定
  # 日本語コメント: 新モデルへの切り替えをダウンタイムなしで実施
  # 本番環境ではCanary(10%→全量)またはLinear(10%ずつ)を推奨
  deployment_config {
    blue_green_update_policy {
      traffic_routing_configuration {
        type                     = "ALL_AT_ONCE"  # テスト環境: 一括切り替え
        wait_interval_in_seconds = 0
      }
      termination_wait_in_seconds = 0
    }
  }

  tags = local.common_tags
}

resource "aws_sagemaker_endpoint" "main" {
  name                 = "${local.prefix}-inference-endpoint"
  endpoint_config_name = aws_sagemaker_endpoint_configuration.main.name
  tags                 = local.common_tags

  # 日本語コメント: テスト後は必ずコンソールまたはCLIで削除してコスト最適化
  # aws sagemaker delete-endpoint --endpoint-name smp-inference-endpoint
}
```

### 4. CodePipeline定義（モデル自動デプロイ）

`terraform/modules/endpoint/codepipeline.tf`:

以下の構成でCodePipelineを実装:

**ステージ1: Source**
- S3バケット（`smp-artifacts-{account_id}/deploy-config/`）からデプロイ設定JSONを取得
- EventBridgeからのトリガーで自動起動

**ステージ2: Deploy**
- CodeBuildでデプロイスクリプトを実行:
  ```bash
  # 最新承認済みモデルのARNを取得
  MODEL_ARN=$(aws sagemaker list-model-packages \
    --model-package-group-name smp-model-group \
    --model-approval-status Approved \
    --sort-by CreationTime \
    --sort-order Descending \
    --max-results 1 \
    --query 'ModelPackageSummaryList[0].ModelPackageArn' \
    --output text)

  # SageMakerモデルリソース作成
  aws sagemaker create-model \
    --model-name smp-model-$(date +%Y%m%d%H%M%S) \
    --primary-container ModelPackageName=$MODEL_ARN \
    --execution-role-arn $ENDPOINT_ROLE_ARN

  # Endpoint Configuration更新
  aws sagemaker update-endpoint \
    --endpoint-name smp-inference-endpoint \
    --endpoint-config-name smp-endpoint-config
  ```

必要なTerraformリソース:
- `aws_codepipeline`
- `aws_codebuild_project`
- IAMロール（CodePipelineがCodeBuildとS3にアクセス）
- S3バケット（CodePipelineアーティファクト用、既存の `smp-artifacts-*` を流用）

### 5. IAM: approval_notifier Lambda専用ロール

`terraform/modules/registry/iam.tf`:

- ロール名: `${local.prefix}-approval-notifier-role`
- ベースロール（`smp-lambda-base-role`）を継承
- 追加権限:
  - `sagemaker:DescribeModelPackage`
  - `sagemaker:ListModelPackages`
  - EventBridgeからの呼び出し許可（Lambda Permission）
- 日本語コメント: 「通知専用のため書き込み系SageMaker権限は一切付与しない」

### 6. terraform/modules/endpoint/iam.tf

EventBridge → CodePipelineトリガー用IAMロール:

```hcl
resource "aws_iam_role" "eventbridge_codepipeline_role" {
  name = "${local.prefix}-eventbridge-codepipeline-role"
  # 日本語コメント: EventBridgeがCodePipelineを起動するための最小権限ロール

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "eventbridge_codepipeline" {
  role = aws_iam_role.eventbridge_codepipeline_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["codepipeline:StartPipelineExecution"]
      Resource = "arn:aws:codepipeline:ap-northeast-1:${local.account_id}:${local.prefix}-deploy-pipeline"
    }]
  })
}
```

---

## 完了条件

- [ ] `terraform validate` が全モジュールで通ること
- [ ] EventBridgeルールがModel Registryイベントを正しくフィルタリングすること
- [ ] Lambda（approval_notifier）がChatwork通知を送信できること
- [ ] CodePipelineがApprovedイベントで自動起動する設定になっていること
- [ ] SageMaker EndpointがTerraformで定義されていること

---

## 次フェーズの予告

Phase 4では以下を実装する:
- Model Monitor: Data Quality Monitor（入力データドリフト検知）
- Model Monitor: Model Quality Monitor（予測精度劣化検知）
- Lambda（drift_handler）: ドリフト検知 → Chatwork通知 + Pipeline再実行トリガー
- CloudWatch Alarm + SNS連携