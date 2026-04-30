# Phase 5: E2Eデプロイ・動作確認・CI/CD・公開準備

## Phase 1-4で作成したもの（サマリー）

**Phase 1（基盤）**: S3/IAM/ECR/VPC Endpoint/SSM

**Phase 2（Pipeline）**:
- SageMaker Pipeline: `smp-training-pipeline`
  （Processing→Training[スポット]→Evaluation→ConditionStep→RegisterModel[PendingApproval]）
- スクリプト: preprocess.py / train.py / evaluate.py
- サンプルデータ生成: `scripts/generate_sample_data.py`

**Phase 3（承認フロー + デプロイ）**:
- Lambda: `smp-approval-notifier`（Chatwork通知）
- EventBridge: PendingApproval/Approved → Lambda/CodePipeline
- CodePipeline: Approved → SageMaker Endpoint自動更新
- SageMaker Endpoint: `smp-inference-endpoint`（Blue/Green）

**Phase 4（Model Monitor）**:
- Data Quality Monitor: 入力データドリフト検知（PSI > 0.5でアラーム）
- Model Quality Monitor: 予測精度劣化検知（accuracy < 0.75でアラーム）
- Lambda: `smp-drift-handler`（ドリフト検知 → Chatwork通知 + Pipeline再実行）
- CloudWatch Alarm → SNS → drift_handler Lambda

---

## このフェーズで実施するもの

E2Eデプロイ・動作確認・権限最小化・CI/CD・ポートフォリオ公開準備を完成させる。

---

## タスク一覧

### 1. AmazonSageMakerFullAccessの最小権限ポリシーへの置き換え（ADR-002実行）

Phase 1で一時的に付与した `AmazonSageMakerFullAccess` を、
実際に必要な権限のみのインラインポリシーに置き換える。

`terraform/modules/foundation/iam.tf` の `smp-pipeline-role` を以下に更新:

```hcl
# AmazonSageMakerFullAccessを削除し、最小権限インラインポリシーに置き換える
resource "aws_iam_role_policy" "pipeline_minimal" {
  name = "${local.prefix}-pipeline-minimal-policy"
  role = aws_iam_role.pipeline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Processing / Training / Evaluation ジョブ実行
      {
        Effect = "Allow"
        Action = [
          "sagemaker:CreateProcessingJob",
          "sagemaker:DescribeProcessingJob",
          "sagemaker:StopProcessingJob",
          "sagemaker:CreateTrainingJob",
          "sagemaker:DescribeTrainingJob",
          "sagemaker:StopTrainingJob",
          "sagemaker:CreateModel",
          "sagemaker:DescribeModel",
          "sagemaker:CreateModelPackage",
          "sagemaker:DescribeModelPackage",
          "sagemaker:UpdateModelPackage",
          "sagemaker:ListModelPackages",
        ]
        Resource = "*"
        # 日本語コメント: SageMakerジョブ系は動的にARNが決まるため * を使用
        # タグベースの条件でプロジェクトスコープに絞ることを推奨
      },
      # Pipeline実行
      {
        Effect = "Allow"
        Action = [
          "sagemaker:StartPipelineExecution",
          "sagemaker:DescribePipelineExecution",
          "sagemaker:ListPipelineExecutionSteps",
        ]
        Resource = "arn:aws:sagemaker:ap-northeast-1:*:pipeline/smp-*"
      },
      # Model Monitor
      {
        Effect = "Allow"
        Action = [
          "sagemaker:CreateDataQualityJobDefinition",
          "sagemaker:CreateModelQualityJobDefinition",
          "sagemaker:CreateMonitoringSchedule",
          "sagemaker:DescribeMonitoringSchedule",
        ]
        Resource = "*"
      },
      # ECRイメージ取得
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
        Resource = "arn:aws:ecr:ap-northeast-1:*:repository/smp-*"
      },
      # CloudWatch Logs
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
      }
    ]
  })
}
```

### 2. デプロイ実行スクリプト `scripts/deploy.sh`

```bash
#!/bin/bash
set -euo pipefail

REGION="ap-northeast-1"
PREFIX="smp"

echo "========================================="
echo "SageMaker MLOps Pipeline デプロイ開始"
echo "========================================="

# Step 1: Terraform Apply（段階的）
echo "[1/6] Terraform Apply - foundation"
cd terraform
terraform apply -target=module.foundation -var="environment=dev" -auto-approve

echo "[2/6] Terraform Apply - pipeline"
terraform apply -target=module.pipeline -var="environment=dev" -auto-approve

echo "[3/6] Terraform Apply - registry + endpoint"
terraform apply -target=module.registry -target=module.endpoint -var="environment=dev" -auto-approve

echo "[4/6] Terraform Apply - monitor"
terraform apply -target=module.monitor -var="environment=dev" -auto-approve

echo "[5/6] Terraform Apply - 残り"
terraform apply -var="environment=dev" -auto-approve

cd ..

# Step 2: SSMパラメータ確認
echo "[6/6] SSMパラメータ確認"
ROOM_ID=$(aws ssm get-parameter --name "/smp/chatwork/room_id" \
  --query 'Parameter.Value' --output text --region $REGION 2>/dev/null || echo "REPLACE_ME")

if [ "$ROOM_ID" = "REPLACE_ME" ]; then
  echo ""
  echo "⚠️  Chatworkパラメータを設定してください:"
  echo "  aws ssm put-parameter --name /smp/chatwork/room_id --value YOUR_ROOM_ID --type SecureString --overwrite"
  echo "  aws ssm put-parameter --name /smp/chatwork/api_token --value YOUR_TOKEN --type SecureString --overwrite"
fi

echo ""
echo "✅ デプロイ完了"
echo "次のステップ: bash scripts/run_pipeline.sh"
```

### 3. パイプライン実行スクリプト `scripts/run_pipeline.sh`

```bash
#!/bin/bash
set -euo pipefail

REGION="ap-northeast-1"
PREFIX="smp"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ARTIFACTS_BUCKET="${PREFIX}-artifacts-${ACCOUNT_ID}"
DATA_BUCKET="${PREFIX}-data-${ACCOUNT_ID}"
PIPELINE_ROLE_ARN=$(terraform -chdir=terraform output -raw pipeline_role_arn)

echo "========================================="
echo "MLOps パイプライン E2Eテスト"
echo "========================================="

# Step 1: サンプルデータ生成・アップロード
echo "[1/4] サンプルデータ生成"
python scripts/generate_sample_data.py \
  --bucket $DATA_BUCKET \
  --n-samples 1000

# Step 2: Pipeline定義をデプロイ
echo "[2/4] Pipeline定義をAWSにアップロード"
python pipeline/pipeline_definition.py \
  --action upsert \
  --role-arn $PIPELINE_ROLE_ARN \
  --artifacts-bucket $ARTIFACTS_BUCKET \
  --data-bucket $DATA_BUCKET

# Step 3: Pipeline実行
echo "[3/4] パイプライン実行開始"
EXECUTION_ARN=$(aws sagemaker start-pipeline-execution \
  --pipeline-name "${PREFIX}-training-pipeline" \
  --pipeline-execution-display-name "e2e-test-$(date +%Y%m%d%H%M%S)" \
  --region $REGION \
  --query 'PipelineExecutionArn' \
  --output text)

echo "実行ARN: $EXECUTION_ARN"

# Step 4: 完了待機（最大30分）
echo "[4/4] パイプライン完了を待機中..."
for i in $(seq 1 60); do
  STATUS=$(aws sagemaker describe-pipeline-execution \
    --pipeline-execution-arn "$EXECUTION_ARN" \
    --region $REGION \
    --query 'PipelineExecutionStatus' \
    --output text)

  echo "  [$i/60] Status: $STATUS"

  if [ "$STATUS" = "Succeeded" ]; then
    echo "✅ パイプライン完了: $STATUS"
    break
  elif [ "$STATUS" = "Failed" ] || [ "$STATUS" = "Stopped" ]; then
    echo "❌ パイプライン失敗: $STATUS"
    exit 1
  fi

  sleep 30
done

echo ""
echo "次のステップ:"
echo "  1. Model Registryで新モデルを確認"
echo "  2. Chatworkで承認依頼通知を確認"
echo "  3. 承認コマンドを実行してデプロイをトリガー"
```

### 4. GitHub Actions CI/CD

`.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:
  id-token: write
  contents: read

jobs:
  terraform:
    name: Terraform Validate & Format
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ap-northeast-1

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.7.0"

      - name: Terraform Init
        run: cd terraform && terraform init -backend=false

      - name: Terraform Validate
        run: cd terraform && terraform validate

      - name: Terraform Format Check
        run: cd terraform && terraform fmt -check -recursive

  python:
    name: Python Lint & Type Check
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"

      - name: Install dependencies
        run: |
          pip install ruff mypy boto3 sagemaker \
            aws-lambda-powertools pandas scikit-learn xgboost

      - name: Lint (ruff)
        run: ruff check pipeline/ lambda/ monitor/ scripts/

      - name: Type check (mypy)
        run: mypy pipeline/pipeline_definition.py --ignore-missing-imports
```

### 5. README.md の作成（GitHub公開用）

以下の構成で作成:

```markdown
# 🏭 SageMaker MLOps Pipeline

> モデル非依存の汎用MLOpsパイプライン基盤。
> データ前処理→学習→評価→承認→デプロイ→監視を完全自動化。

## アーキテクチャ

[Mermaidアーキテクチャ図（Phase1のdocs/architecture.mdから引用）]

## 技術スタック

| カテゴリ | 技術 |
|---|---|
| MLパイプライン | Amazon SageMaker Pipelines |
| モデル管理 | SageMaker Model Registry |
| デプロイ | CodePipeline + SageMaker Endpoint (Blue/Green) |
| 監視 | SageMaker Model Monitor (Data Quality / Model Quality) |
| IaC | Terraform >= 1.7 |
| 通知 | Chatwork API |

## パイプラインのフロー

1. **Processing**: データ前処理・特徴量エンジニアリング
2. **Training**: XGBoost学習（スポットインスタンスでコスト削減）
3. **Evaluation**: 精度評価（accuracy >= 0.8でModel Registryへ登録）
4. **Approval**: Chatwork通知 → 人間承認
5. **Deploy**: 承認後に自動デプロイ（Blue/Green）
6. **Monitor**: Data Drift / Model Quality を1時間ごとに監視、劣化で自動再学習

## セットアップ

[デプロイ手順]

## コスト設計

- 月額目安: $5-15（Endpoint停止運用時）
- スポットインスタンスで学習コストを最大70%削減
- Endpointはテスト後に削除: `aws sagemaker delete-endpoint --endpoint-name smp-inference-endpoint`
```

### 6. docs/zenn-article-draft.md の作成

```
タイトル: SageMaker Pipelinesで本番MLOps基盤を作った話
         ― モデル学習から監視まで完全自動化

## はじめに
なぜMLOpsが必要か（手動デプロイの問題点）

## アーキテクチャ全体像

## 実装のポイント

### 1. SageMaker Pipelinesのステップ設計
ConditionStepで精度チェック → PendingApprovalパターン

### 2. スポットインスタンスで学習コストを削減
use_spot_instances=True の設定と注意点

### 3. Human-in-the-loop承認フロー
Model Registry + EventBridge + Chatwork通知

### 4. Blue/Greenデプロイでダウンタイムゼロ
deployment_config の設定詳細

### 5. Model Monitorでドリフトを自動検知
Data Quality / Model Quality の違いと設定

### 6. Terraform IaCで全リソースを管理
AmazonSageMakerFullAccessから最小権限へのリファクタリング

## ハマったポイント
- PropertyFileとJsonGetの使い方
- スポットインスタンスのmax_wait設定
- Data CaptureなしでModel Monitorが動かない問題

## まとめ
インフラエンジニアがMLOpsを作ると何が違うか
```

---

## 完了条件

- [ ] `bash scripts/deploy.sh` でエラーなくデプロイ完了
- [ ] `bash scripts/run_pipeline.sh` でパイプラインがSucceededで完了
- [ ] Chatworkに承認依頼通知が届くこと
- [ ] モデル承認後にCodePipelineが自動起動すること
- [ ] Model Monitorスケジュールが起動していること
- [ ] GitHub ActionsのCIがパスすること
- [ ] README.mdが公開レベルのクオリティで完成
- [ ] `AmazonSageMakerFullAccess` が最小権限ポリシーに置き換わっていること

---

## プロジェクト完了後の展開

1. **GitHubに公開**: `sagemaker-mlops-pipeline` リポジトリ
2. **Zenn記事公開**: MLOps実装の解説記事
3. **2プロジェクトの組み合わせアピール**:
   - `bedrock-multi-agent-ops-autopilot` × `sagemaker-mlops-pipeline`
   - 「AI基盤の構築（MLOps）と運用自動化（Multi-Agent）を両方できるエンジニア」として訴求