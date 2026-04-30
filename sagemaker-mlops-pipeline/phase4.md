# ✅Phase 4: Model Monitor（Data Drift / Model Quality検知）

## Phase 1-3で作成したもの（サマリー）

**Phase 1（基盤）**: S3/IAM/ECR/VPC Endpoint/SSM

**Phase 2（Pipeline）**:
- SageMaker Pipeline: `smp-training-pipeline`（Processing→Training→Evaluation→Register）
- Model Package Group: `smp-model-group`
- スクリプト: preprocess.py / train.py / evaluate.py

**Phase 3（承認フロー + デプロイ）**:
- Lambda: `smp-approval-notifier`（Model Registry状態変化 → Chatwork通知）
- EventBridge: PendingApproval/Approved検知
- CodePipeline: Approved → SageMaker Endpoint自動更新
- SageMaker Endpoint: `smp-inference-endpoint`（Blue/Green対応）

---

## このフェーズで作成するもの

デプロイ済みEndpointに対してModel Monitorを設定し、
入力データのドリフトと予測精度の劣化を自動検知する仕組みを実装する。

---

## タスク一覧

### 1. ベースライン生成スクリプトの実装

Model Monitorは「正常な状態のベースライン統計」と比較してドリフトを検知する。
まずベースラインを生成するスクリプトを実装する。

**ファイル**: `monitor/data_quality_baseline.py`

```python
"""
Data Quality Monitorのベースライン生成

設計意図:
- 学習時のデータ統計情報（平均・分散・データ型・欠損率など）をベースラインとして記録
- SageMaker Model Monitorがこのベースラインと本番推論時の入力データを比較
- ベースラインはS3に保存され、Monitorスケジュール設定時に参照される
"""
import boto3
import sagemaker
from sagemaker.model_monitor import DefaultModelMonitor
from sagemaker.model_monitor.dataset_format import DatasetFormat

REGION = "ap-northeast-1"
PREFIX = "smp"

def create_data_quality_baseline(
    role_arn: str,
    artifacts_bucket: str,
    data_bucket: str
) -> str:
    """
    Data Quality Monitorのベースラインジョブを実行

    Returns:
        str: ベースライン統計のS3 URI
    """
    sagemaker_session = sagemaker.Session(
        boto_session=boto3.Session(region_name=REGION)
    )

    monitor = DefaultModelMonitor(
        role=role_arn,
        instance_count=1,
        instance_type="ml.m5.large",
        volume_size_in_gb=20,
        max_runtime_in_seconds=3600,
        sagemaker_session=sagemaker_session
    )

    baseline_output_uri = f"s3://{artifacts_bucket}/monitor/data-quality/baseline"

    # ベースラインジョブ実行（学習データを使ってベースライン統計を計算）
    monitor.suggest_baseline(
        baseline_dataset=f"s3://{data_bucket}/raw/sample_data.csv",
        dataset_format=DatasetFormat.csv(header=True),
        output_s3_uri=baseline_output_uri,
        wait=True,
        logs=True
    )

    print(f"Data Qualityベースライン生成完了: {baseline_output_uri}")
    return baseline_output_uri


if __name__ == "__main__":
    import argparse
    import boto3 as b3

    parser = argparse.ArgumentParser()
    parser.add_argument("--role-arn", required=True)
    parser.add_argument("--artifacts-bucket", required=True)
    parser.add_argument("--data-bucket", required=True)
    args = parser.parse_args()

    create_data_quality_baseline(
        role_arn=args.role_arn,
        artifacts_bucket=args.artifacts_bucket,
        data_bucket=args.data_bucket
    )
```

**ファイル**: `monitor/model_quality_baseline.py`

```python
"""
Model Quality Monitorのベースライン生成

設計意図:
- テストデータに対するモデルの予測結果と正解ラベルを使ってベースラインを生成
- 本番推論時の実際の予測精度とこのベースラインを比較してモデル劣化を検知
- Ground Truth（正解ラベル）は後からS3に格納される前提で設計
"""
import boto3
import sagemaker
from sagemaker.model_monitor import ModelQualityMonitor
from sagemaker.model_monitor.dataset_format import DatasetFormat

REGION = "ap-northeast-1"
PREFIX = "smp"

def create_model_quality_baseline(
    role_arn: str,
    artifacts_bucket: str,
    endpoint_name: str = f"{PREFIX}-inference-endpoint"
) -> str:
    sagemaker_session = sagemaker.Session(
        boto_session=boto3.Session(region_name=REGION)
    )

    monitor = ModelQualityMonitor(
        role=role_arn,
        instance_count=1,
        instance_type="ml.m5.large",
        sagemaker_session=sagemaker_session
    )

    baseline_output_uri = f"s3://{artifacts_bucket}/monitor/model-quality/baseline"

    monitor.suggest_baseline(
        baseline_dataset=f"s3://{artifacts_bucket}/pipeline-artifacts/test/test.csv",
        dataset_format=DatasetFormat.csv(header=True),
        output_s3_uri=baseline_output_uri,
        problem_type="BinaryClassification",
        inference_attribute="prediction",      # 推論結果のカラム名
        ground_truth_attribute="target",       # 正解ラベルのカラム名
        wait=True
    )

    print(f"Model Qualityベースライン生成完了: {baseline_output_uri}")
    return baseline_output_uri
```

### 2. Model Monitor Terraform定義

`terraform/modules/monitor/main.tf`:

```hcl
# =====================
# Data Quality Monitor
# =====================
resource "aws_sagemaker_data_quality_job_definition" "main" {
  name     = "${local.prefix}-data-quality-monitor"
  role_arn = var.pipeline_role_arn

  data_quality_app_specification {
    # AWS提供のビルトインモニタリングコンテナ
    image_uri = "156387875391.dkr.ecr.ap-northeast-1.amazonaws.com/sagemaker-model-monitor-analyzer"
  }

  data_quality_baseline_config {
    constraints_resource {
      s3_uri = "${var.data_quality_baseline_uri}/constraints.json"
    }
    statistics_resource {
      s3_uri = "${var.data_quality_baseline_uri}/statistics.json"
    }
  }

  data_quality_job_input {
    endpoint_input {
      endpoint_name         = var.endpoint_name
      local_path            = "/opt/ml/processing/input/endpoint"
      # 日本語コメント: 推論リクエストデータをキャプチャするためにEndpoint Data Captureが必要
      s3_input_mode         = "File"
      s3_data_distribution_type = "FullyReplicated"
    }
  }

  data_quality_job_output_config {
    monitoring_outputs {
      s3_output {
        local_path    = "/opt/ml/processing/output"
        s3_uri        = "s3://${var.artifacts_bucket}/monitor/data-quality/output"
        s3_upload_mode = "EndOfJob"
      }
    }
  }

  job_resources {
    cluster_config {
      instance_count    = 1
      instance_type     = "ml.m5.large"
      volume_size_in_gb = 20
    }
  }

  tags = local.common_tags
}

# Data Quality Monitorスケジュール（1時間ごと）
resource "aws_sagemaker_monitoring_schedule" "data_quality" {
  name = "${local.prefix}-data-quality-schedule"

  monitoring_schedule_config {
    monitoring_job_definition_name = aws_sagemaker_data_quality_job_definition.main.name
    monitoring_type                = "DataQuality"

    schedule_config {
      # 日本語コメント: 1時間ごとに実行。コスト最適化のため最小間隔を使用
      schedule_expression = "cron(0 * ? * * *)"
    }
  }

  tags = local.common_tags
}

# =====================
# Model Quality Monitor
# =====================
resource "aws_sagemaker_model_quality_job_definition" "main" {
  name     = "${local.prefix}-model-quality-monitor"
  role_arn = var.pipeline_role_arn

  model_quality_app_specification {
    image_uri    = "156387875391.dkr.ecr.ap-northeast-1.amazonaws.com/sagemaker-model-monitor-analyzer"
    problem_type = "BinaryClassification"
  }

  model_quality_baseline_config {
    constraints_resource {
      s3_uri = "${var.model_quality_baseline_uri}/constraints.json"
    }
  }

  model_quality_job_input {
    endpoint_input {
      endpoint_name              = var.endpoint_name
      local_path                 = "/opt/ml/processing/input/endpoint"
      inference_attribute        = "prediction"
      probability_attribute      = "probability"
      probability_threshold_attribute = 0.5
    }
    ground_truth_s3_input {
      # 日本語コメント: 実際の正解ラベルは別システムから定期的にS3に格納される前提
      s3_uri = "s3://${var.data_bucket}/ground-truth/"
    }
  }

  model_quality_job_output_config {
    monitoring_outputs {
      s3_output {
        local_path    = "/opt/ml/processing/output"
        s3_uri        = "s3://${var.artifacts_bucket}/monitor/model-quality/output"
        s3_upload_mode = "EndOfJob"
      }
    }
  }

  job_resources {
    cluster_config {
      instance_count    = 1
      instance_type     = "ml.m5.large"
      volume_size_in_gb = 20
    }
  }

  tags = local.common_tags
}

resource "aws_sagemaker_monitoring_schedule" "model_quality" {
  name = "${local.prefix}-model-quality-schedule"

  monitoring_schedule_config {
    monitoring_job_definition_name = aws_sagemaker_model_quality_job_definition.main.name
    monitoring_type                = "ModelQuality"

    schedule_config {
      schedule_expression = "cron(0 * ? * * *)"
    }
  }

  tags = local.common_tags
}

# =====================
# Endpoint Data Capture（推論データ収集）
# =====================
# 日本語コメント: Data Quality MonitorがEndpointへの入力データを収集するために必要
# Endpointデプロイ時にこの設定を有効化する
resource "aws_sagemaker_endpoint_configuration" "with_data_capture" {
  name = "${local.prefix}-endpoint-config-with-capture"

  production_variants {
    variant_name           = "primary"
    initial_instance_count = 1
    instance_type          = var.endpoint_instance_type
    initial_variant_weight = 1.0
  }

  data_capture_config {
    enable_capture              = true
    initial_sampling_percentage = 100  # 日本語コメント: テスト環境では全件キャプチャ。本番は10-20%推奨
    destination_s3_uri          = "s3://${var.artifacts_bucket}/monitor/data-capture"

    capture_options {
      capture_mode = "Input"   # 推論リクエストをキャプチャ
    }
    capture_options {
      capture_mode = "Output"  # 推論レスポンスをキャプチャ
    }

    capture_content_type_header {
      json_content_types = ["application/json"]
      csv_content_types  = ["text/csv"]
    }
  }

  tags = local.common_tags
}
```

### 3. CloudWatch Alarm定義

`terraform/modules/monitor/alarms.tf`:

```hcl
# Data Qualityドリフト検知アラーム
resource "aws_cloudwatch_metric_alarm" "data_drift" {
  alarm_name          = "${local.prefix}-data-drift-alarm"
  alarm_description   = "入力データのドリフトがベースラインから逸脱"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "feature_baseline_drift_max"
  namespace           = "aws/sagemaker/Endpoints/data-metrics"
  period              = 3600
  statistic           = "Maximum"
  threshold           = 0.5  # 日本語コメント: PSI(人口安定性指数) > 0.5で有意なドリフト

  dimensions = {
    MonitoringSchedule = aws_sagemaker_monitoring_schedule.data_quality.name
    Endpoint           = var.endpoint_name
  }

  alarm_actions = [aws_sns_topic.monitor_alerts.arn]
  ok_actions    = [aws_sns_topic.monitor_alerts.arn]
  tags          = local.common_tags
}

# Model Qualityアラーム
resource "aws_cloudwatch_metric_alarm" "model_quality" {
  alarm_name          = "${local.prefix}-model-quality-alarm"
  alarm_description   = "モデル予測精度がベースラインから劣化"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "binary_classification_accuracy"
  namespace           = "aws/sagemaker/Endpoints/model-metrics"
  period              = 3600
  statistic           = "Average"
  threshold           = 0.75  # 日本語コメント: 精度75%を下回ったら再学習トリガー

  dimensions = {
    MonitoringSchedule = aws_sagemaker_monitoring_schedule.model_quality.name
    Endpoint           = var.endpoint_name
  }

  alarm_actions = [aws_sns_topic.monitor_alerts.arn]
  tags          = local.common_tags
}

# SNS Topic（CloudWatch Alarm → Lambda）
resource "aws_sns_topic" "monitor_alerts" {
  name = "${local.prefix}-monitor-alerts"
  tags = local.common_tags
}

resource "aws_sns_topic_subscription" "drift_handler" {
  topic_arn = aws_sns_topic.monitor_alerts.arn
  protocol  = "lambda"
  endpoint  = var.drift_handler_lambda_arn
}
```

### 4. lambda/drift_handler/handler.py の実装

```python
"""
Model Monitorドリフト検知ハンドラー Lambda

設計意図:
- CloudWatch Alarm → SNS → このLambdaの流れでドリフトを検知したときに起動
- Chatworkにアラート通知を送信
- 同時にSageMaker Pipelineを再実行して最新データでモデルを再学習
- 再学習は自動実行するが、デプロイは人間承認フロー（Phase3）を経由するため安全
"""
import json
import boto3
import urllib.parse
import urllib.request
from aws_lambda_powertools import Logger, Tracer, Metrics
from aws_lambda_powertools.utilities.typing import LambdaContext

logger = Logger()
tracer = Tracer()
metrics = Metrics(namespace="SMP/DriftHandler")

ssm = boto3.client('ssm', region_name='ap-northeast-1')
sagemaker = boto3.client('sagemaker', region_name='ap-northeast-1')

PIPELINE_NAME = "smp-training-pipeline"
PREFIX = "smp"

def get_ssm_params() -> tuple[str, str]:
    response = ssm.get_parameters(
        Names=['/smp/chatwork/room_id', '/smp/chatwork/api_token'],
        WithDecryption=True
    )
    params = {p['Name']: p['Value'] for p in response['Parameters']}
    return params['/smp/chatwork/room_id'], params['/smp/chatwork/api_token']

def send_chatwork_message(room_id: str, api_token: str, message: str) -> None:
    url = f"https://api.chatwork.com/v2/rooms/{room_id}/messages"
    data = urllib.parse.urlencode({'body': message}).encode('utf-8')
    req = urllib.request.Request(
        url, data=data,
        headers={'X-ChatWorkToken': api_token},
        method='POST'
    )
    with urllib.request.urlopen(req) as resp:
        logger.info("Chatwork通知完了", status_code=resp.status)

def trigger_retraining() -> str:
    """SageMaker Pipelineを再実行して最新データで再学習"""
    import datetime
    execution_name = f"retrain-{datetime.datetime.now().strftime('%Y%m%d%H%M%S')}"

    response = sagemaker.start_pipeline_execution(
        PipelineName=PIPELINE_NAME,
        PipelineExecutionDisplayName=execution_name,
        PipelineExecutionDescription="Model Monitorドリフト検知による自動再学習",
    )

    logger.info("パイプライン再実行開始", execution_arn=response['PipelineExecutionArn'])
    return response['PipelineExecutionArn']

@logger.inject_lambda_context
@tracer.capture_lambda_handler
def handler(event: dict, context: LambdaContext) -> dict:
    logger.info("ドリフト検知イベント受信", event=event)

    # SNSメッセージからアラーム情報を解析
    for record in event.get('Records', []):
        sns_message = json.loads(record['Sns']['Message'])
        alarm_name = sns_message.get('AlarmName', 'Unknown')
        alarm_state = sns_message.get('NewStateValue', 'Unknown')
        alarm_reason = sns_message.get('NewStateReason', '')

        if alarm_state != 'ALARM':
            logger.info("ALARMでないイベントをスキップ", state=alarm_state)
            continue

        # ドリフトタイプの判定
        if 'data-drift' in alarm_name:
            drift_type = "データドリフト（入力データの分布変化）"
            action = "再学習パイプラインを自動起動します"
        elif 'model-quality' in alarm_name:
            drift_type = "モデル品質劣化（予測精度の低下）"
            action = "再学習パイプラインを自動起動します"
        else:
            drift_type = "不明なアラーム"
            action = "手動確認が必要です"

        # 再学習トリガー（データドリフト・モデル劣化どちらでも起動）
        execution_arn = trigger_retraining()

        # Chatwork通知
        message = (
            f"[info][title]⚠️ MLOps Model Monitor アラート[/title]"
            f"検知種別: {drift_type}\n"
            f"アラーム名: {alarm_name}\n"
            f"検知理由: {alarm_reason}\n\n"
            f"🔄 対応: {action}\n"
            f"パイプライン実行ARN:\n{execution_arn}\n\n"
            f"再学習完了後、新モデルはModel Registryで承認が必要です。[/info]"
        )

        room_id, api_token = get_ssm_params()
        send_chatwork_message(room_id, api_token, message)
        metrics.add_metric(name="DriftDetected", unit="Count", value=1)

    return {"statusCode": 200, "body": "drift handled"}
```

### 5. Lambda（drift_handler）のIAMロール

`terraform/modules/monitor/iam.tf`:

- ロール名: `${local.prefix}-drift-handler-role`
- ベースロール継承 + 追加権限:
  - `sagemaker:StartPipelineExecution` on `smp-training-pipeline`
  - `sagemaker:DescribePipelineExecution`
  - SSMはベースロールで対応済み
- 日本語コメント: 「再学習パイプラインの起動権限のみ。Endpoint操作権限は付与しない（デプロイは承認フロー経由）」

---

## 完了条件

- [ ] `monitor/data_quality_baseline.py` が構文エラーなく動作すること
- [ ] `monitor/model_quality_baseline.py` が構文エラーなく動作すること
- [ ] `terraform validate` が全モジュールで通ること
- [ ] CloudWatch Alarmが適切な閾値で設定されていること
- [ ] drift_handler LambdaがPipelineを再実行し、Chatworkに通知できること

---

## 次フェーズの予告

Phase 5では以下を実施:
- E2Eデプロイ（terraform apply → サンプルデータ投入 → Pipeline実行）
- 動作確認（承認フロー / Chatwork通知 / Model Monitor起動）
- GitHub Actions CI/CD（OIDC認証）
- README.md + Zenn記事下書き
- `AmazonSageMakerFullAccess` の最小権限ポリシーへの置き換え（ADR-002の実行）