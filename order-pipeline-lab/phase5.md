# Phase 5: 可観測性・障害テスト・仕上げ

## 目標
CloudWatch ダッシュボード / アラームを整備し、意図的に障害を発生させて
「障害耐性が実際に機能する」ことを数値で確認する。
面接で語れる具体的な数字 (成功率・DLQ 到達数・リトライ回数) を記録する。

---

## Task 1: CloudWatch ダッシュボード

### `terraform/modules/monitoring/` モジュールを新規作成

**`terraform/modules/monitoring/variables.tf`**
```hcl
variable "project" { type = string }
variable "common_tags" { type = map(string) }
variable "state_machine_arn" { type = string }
variable "state_machine_name" { type = string }
variable "inventory_check_function" { type = string }
variable "notification_function" { type = string }
variable "dlq_reprocessor_function" { type = string }
variable "sfn_trigger_function" { type = string }
variable "orders_queue_name" { type = string }
variable "orders_dlq_name" { type = string }
variable "ecs_cluster_name" { type = string }
variable "dynamodb_table_name" { type = string }
```

**`terraform/modules/monitoring/main.tf`**

以下の CloudWatch リソースをすべて実装すること:

```hcl
# ダッシュボード: 注文処理パイプライン全体
resource "aws_cloudwatch_dashboard" "pipeline" {
  dashboard_name = "${var.project}-pipeline"

  dashboard_body = jsonencode({
    widgets = [
      # Row 1: Step Functions
      {
        type   = "metric"
        width  = 8
        height = 6
        properties = {
          title  = "Step Functions - 実行結果"
          period = 300
          stat   = "Sum"
          metrics = [
            ["AWS/States", "ExecutionsSucceeded", "StateMachineArn", var.state_machine_arn],
            ["AWS/States", "ExecutionsFailed",    "StateMachineArn", var.state_machine_arn],
            ["AWS/States", "ExecutionsTimedOut",  "StateMachineArn", var.state_machine_arn]
          ]
        }
      },
      {
        type   = "metric"
        width  = 8
        height = 6
        properties = {
          title  = "Step Functions - 実行時間 (ms)"
          period = 300
          stat   = "Average"
          metrics = [
            ["AWS/States", "ExecutionTime", "StateMachineArn", var.state_machine_arn]
          ]
        }
      },
      # Row 2: SQS
      {
        type   = "metric"
        width  = 8
        height = 6
        properties = {
          title  = "SQS - メッセージ数"
          period = 60
          stat   = "Maximum"
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible",    "QueueName", var.orders_queue_name],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible",    "QueueName", var.orders_dlq_name],
            ["AWS/SQS", "NumberOfMessagesSent",                  "QueueName", var.orders_queue_name],
            ["AWS/SQS", "NumberOfMessagesDeleted",               "QueueName", var.orders_queue_name]
          ]
        }
      },
      # Row 3: Lambda
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title  = "Lambda - エラー率"
          period = 300
          stat   = "Sum"
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", var.inventory_check_function],
            ["AWS/Lambda", "Errors", "FunctionName", var.notification_function],
            ["AWS/Lambda", "Errors", "FunctionName", var.dlq_reprocessor_function]
          ]
        }
      },
      # Row 4: ECS
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title  = "ECS - タスク実行"
          period = 300
          stat   = "Sum"
          metrics = [
            ["ECS/ContainerInsights", "TaskCount", "ClusterName", var.ecs_cluster_name],
            ["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", var.ecs_cluster_name]
          ]
        }
      },
      # Row 5: カスタムメトリクス (OrderPipeline namespace)
      {
        type   = "metric"
        width  = 24
        height = 6
        properties = {
          title  = "カスタムメトリクス - 業務KPI"
          period = 300
          stat   = "Sum"
          metrics = [
            ["OrderPipeline", "InventoryCheckSuccess",  "service", "inventory-check"],
            ["OrderPipeline", "InventoryShortage",      "service", "inventory-check"],
            ["OrderPipeline", "NotificationSent",       "service", "notification"],
            ["OrderPipeline", "CompensationExecuted",   "service", "dlq-reprocessor"],
            ["OrderPipeline", "CompensationFailed",     "service", "dlq-reprocessor"]
          ]
        }
      }
    ]
  })
}

# アラーム: Step Functions 失敗数
resource "aws_cloudwatch_metric_alarm" "sfn_failures" {
  alarm_name          = "${var.project}-sfn-failures"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ExecutionsFailed"
  namespace           = "AWS/States"
  period              = 300
  statistic           = "Sum"
  threshold           = 3  # なぜ: 5分間に3回以上失敗したら異常と判断

  dimensions = {
    StateMachineArn = var.state_machine_arn
  }

  alarm_description = "Step Functions の実行失敗が多発しています"
  tags              = var.common_tags
}

# アラーム: Lambda エラー率 (在庫確認)
resource "aws_cloudwatch_metric_alarm" "inventory_errors" {
  alarm_name          = "${var.project}-inventory-check-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 5

  dimensions = {
    FunctionName = var.inventory_check_function
  }

  alarm_description = "在庫確認 Lambda のエラーが増加しています"
  tags              = var.common_tags
}
```

**`terraform/modules/monitoring/outputs.tf`**
```hcl
output "dashboard_url" {
  value = "https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home#dashboards:name=${var.project}-pipeline"
}
```

---

## Task 2: main.tf に monitoring モジュール追加

```hcl
module "monitoring" {
  source = "./modules/monitoring"

  project                   = local.project
  common_tags               = local.common_tags
  state_machine_arn         = module.step_functions.state_machine_arn
  state_machine_name        = module.step_functions.state_machine_name
  inventory_check_function  = "order-pipeline-inventory-check"
  notification_function     = "order-pipeline-notification"
  dlq_reprocessor_function  = "order-pipeline-dlq-reprocessor"
  sfn_trigger_function      = "order-pipeline-sfn-trigger"
  orders_queue_name         = "order-pipeline-orders-queue"
  orders_dlq_name           = "order-pipeline-orders-dlq"
  ecs_cluster_name          = module.ecs.ecs_cluster_name
  dynamodb_table_name       = aws_dynamodb_table.orders.name
}
```

---

## Task 3: 障害テストスクリプト

### `scripts/chaos-test.sh`

```bash
#!/bin/bash
# 障害耐性テスト: 大量注文を投入し DLQ・リトライ動作を確認する
set -euo pipefail

REGION="ap-northeast-1"
QUEUE_URL=$(cd terraform && terraform output -raw orders_queue_url)
STATE_MACHINE_ARN=$(cd terraform && terraform output -raw state_machine_arn)
TABLE_NAME="order-pipeline-orders"

echo "=== 障害耐性テスト開始 ==="
echo "注文 20件を連続投入します..."

SUCCESS=0
for i in $(seq 1 20); do
  ORDER_ID="chaos-$(date +%s)-${i}"
  AMOUNT=$((RANDOM % 10000 + 1000))

  aws sqs send-message \
    --queue-url "${QUEUE_URL}" \
    --message-body "{
      \"order_id\": \"${ORDER_ID}\",
      \"amount\": ${AMOUNT},
      \"items\": [{\"sku\": \"SKU-$(( RANDOM % 5 + 1 ))\", \"qty\": $(( RANDOM % 3 + 1 ))}]
    }" \
    --region "${REGION}" > /dev/null

  SUCCESS=$((SUCCESS + 1))
  echo "  投入: ${ORDER_ID} (amount=${AMOUNT})"
  sleep 0.5  # レートリミット回避
done

echo ""
echo "=== 投入完了: ${SUCCESS}件 ==="
echo "30秒後に結果を集計します..."
sleep 30

echo ""
echo "=== Step Functions 実行結果 ==="
aws stepfunctions list-executions \
  --state-machine-arn "${STATE_MACHINE_ARN}" \
  --region "${REGION}" \
  --max-results 25 \
  | jq -r '
    .executions | 
    group_by(.status) | 
    map({status: .[0].status, count: length}) | 
    .[] | "\(.status): \(.count)件"
  '

echo ""
echo "=== DLQ メッセージ数 ==="
DLQ_URL=$(cd terraform && terraform output -raw orders_dlq_url 2>/dev/null || echo "")
if [ -n "${DLQ_URL}" ]; then
  aws sqs get-queue-attributes \
    --queue-url "${DLQ_URL}" \
    --attribute-names ApproximateNumberOfMessages \
    --region "${REGION}" \
    | jq -r '.Attributes.ApproximateNumberOfMessages + " 件が DLQ に到達"'
fi

echo ""
echo "=== DynamoDB ステータス集計 ==="
# 注: scan は本番禁止だがテスト目的で使用
aws dynamodb scan \
  --table-name "${TABLE_NAME}" \
  --filter-expression "begins_with(order_id, :prefix)" \
  --expression-attribute-values '{":prefix": {"S": "chaos-"}}' \
  --region "${REGION}" \
  | jq -r '
    .Items | 
    group_by(.status.S) | 
    map({status: .[0].status.S, count: length}) | 
    .[] | "\(.status): \(.count)件"
  '

echo ""
echo "=== テスト完了 ==="
echo "CloudWatch ダッシュボードで詳細を確認してください"
```

```bash
chmod +x scripts/chaos-test.sh
```

---

## Task 4: DLQ 強制テストスクリプト

### `scripts/test-dlq.sh`
```bash
#!/bin/bash
# DLQ テスト: 意図的に壊れたメッセージを投入し DLQ 動作を確認
set -euo pipefail

REGION="ap-northeast-1"
QUEUE_URL=$(cd terraform && terraform output -raw orders_queue_url)

echo "=== DLQ テスト: 不正メッセージを投入 ==="

# order_id なし → sfn-trigger Lambda がエラー → SQS が maxReceiveCount 後に DLQ へ
for i in $(seq 1 3); do
  aws sqs send-message \
    --queue-url "${QUEUE_URL}" \
    --message-body '{"amount": 1000, "items": []}' \
    --region "${REGION}"
  echo "  不正メッセージ ${i}/3 を投入"
  sleep 2
done

echo ""
echo "3分後に DLQ を確認してください:"
echo "  aws sqs get-queue-attributes --queue-url <DLQ_URL> --attribute-names All"
```

---

## Task 5: クリーンアップスクリプト

### `scripts/cleanup.sh`
```bash
#!/bin/bash
# 全リソースを削除してコストをゼロにする
set -euo pipefail

echo "=== リソース削除開始 ==="
echo "WARNING: すべての AWS リソースが削除されます"
read -p "続行しますか？ (yes/no): " CONFIRM

if [ "${CONFIRM}" != "yes" ]; then
  echo "キャンセルしました"
  exit 0
fi

# ECR イメージを先に削除 (terraform destroy が ECR リポジトリを削除できるようにする)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="ap-northeast-1"

echo "ECR イメージを削除中..."
aws ecr list-images \
  --repository-name "order-pipeline/payment-processor" \
  --region "${REGION}" \
  --query 'imageIds[*]' \
  --output json 2>/dev/null | \
  xargs -I{} aws ecr batch-delete-image \
    --repository-name "order-pipeline/payment-processor" \
    --image-ids "{}" \
    --region "${REGION}" 2>/dev/null || true

echo "Terraform destroy を実行中..."
cd terraform
terraform destroy -auto-approve

echo ""
echo "=== クリーンアップ完了 ==="
```

---

## 最終動作確認

```bash
# 1. 全リソースのデプロイ確認
cd terraform && terraform output

# 2. E2E 正常ケーステスト
aws sqs send-message \
  --queue-url $(terraform output -raw orders_queue_url) \
  --message-body '{
    "order_id": "final-test-001",
    "amount": 3000,
    "items": [{"sku": "X001", "qty": 1}]
  }' \
  --region ap-northeast-1

# 3. 30秒待って確認
sleep 30
aws dynamodb get-item \
  --table-name order-pipeline-orders \
  --key '{"order_id": {"S": "final-test-001"}}' \
  --region ap-northeast-1 | jq '.Item.status.S'

# 4. 障害耐性テスト
./scripts/chaos-test.sh

# 5. DLQ テスト
./scripts/test-dlq.sh
```

---

## 面接で語れる数字の記録シート

テスト実行後、以下を `docs/test-results.md` に記録すること:

```markdown
# テスト結果記録

## 実施日
YYYY-MM-DD

## E2E テスト結果 (20件投入)
- 成功: X件 (X%)
- 在庫不足による失敗: X件
- 決済失敗によるリトライ後成功: X件
- DLQ 到達: X件

## パフォーマンス
- 平均 Step Functions 実行時間: X秒
- 決済処理 (ECS) 平均時間: X秒

## DLQ 動作確認
- DLQ 到達件数: X件
- 補償処理実行数: X件
- 補償処理成功率: X%

## 面接で話せるポイント
- [ ] SQS visibility_timeout の設定理由を説明できる
- [ ] Step Functions Retry の BackoffRate を使った理由を説明できる
- [ ] FARGATE_SPOT を選んだ根拠を説明できる
- [ ] DLQ の監視設計を説明できる
- [ ] 補償トランザクションと saga パターンの違いを説明できる
```

---

## フェーズ完了チェックリスト

- [ ] CloudWatch ダッシュボードが表示される
- [ ] `chaos-test.sh` で 20件投入、結果を集計できる
- [ ] DLQ テストでメッセージが DLQ に到達し、補償処理が動作する
- [ ] X-Ray トレースで処理フロー全体が可視化できる
- [ ] `docs/test-results.md` に数値が記録されている
- [ ] 全 ADR (001/002/003) が自分の言葉で記述完了

## 最終口頭説明チェック
「このシステムのアーキテクチャを 15分で説明する」練習をすること。
話すべき項目:
1. なぜこのアーキテクチャを選んだか
2. 障害が起きたときに何が起こるか (DLQ フローを追って)
3. コストをどう抑えているか (NAT GW なし / Spot / arm64)
4. 本番運用で追加すべき改善点は何か