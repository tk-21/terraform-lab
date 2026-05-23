# ✅Phase 5 — EventBridge + S3トリガー連携・E2Eテスト

## 目標
- S3にファイルをアップロードするだけでパイプラインが自動起動する仕組みを作る
- EventBridge ルールで `input/` プレフィックスのオブジェクト作成イベントを検知する
- E2Eテストで全コンポーネントの疎通を確認する

---

## タスク一覧

### 5-1. S3 EventBridge通知を有効化

S3バケットのEventBridge通知は `aws_s3_bucket_notification` リソースで有効化する。
`terraform/modules/s3/main.tf` に追記:

```hcl
# S3→EventBridgeの通知を有効化
# EventBridge経由にすることで複数ターゲットへのルーティングが柔軟になる
resource "aws_s3_bucket_notification" "input" {
  bucket      = aws_s3_bucket.input.id
  eventbridge = true  # S3のイベントをEventBridgeに転送する
}
```

---

### 5-2. EventBridgeモジュール作成

`terraform/modules/eventbridge/main.tf`:

```hcl
# S3オブジェクト作成イベントをStep Functionsに転送するルール
resource "aws_cloudwatch_event_rule" "s3_to_sfn" {
  name        = "${var.name_prefix}-s3-input-trigger"
  description = "S3 input/配下へのファイルアップロードでパイプラインを起動"

  # EventBridgeのイベントパターン
  # input/ プレフィックスのオブジェクト作成のみにフィルタリング
  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = {
        name = [var.input_bucket_name]
      }
      object = {
        # CSVとJSONのみ処理対象（他のファイルは無視）
        key = [{ prefix = "input/" }]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "sfn" {
  rule     = aws_cloudwatch_event_rule.s3_to_sfn.name
  arn      = var.sfn_arn
  role_arn = var.eventbridge_role_arn

  # EventBridgeのイベントをStep Functionsの入力形式に変換
  # S3イベントのバケット名とキーをパイプラインの入力変数にマッピング
  input_transformer {
    input_paths = {
      bucket = "$.detail.bucket.name"
      key    = "$.detail.object.key"
    }
    # Step Functionsが期待するJSON形式に変換
    input_template = <<-EOT
    {
      "input_bucket": "<bucket>",
      "s3_key": "<key>"
    }
    EOT
  }
}
```

`terraform/modules/eventbridge/variables.tf`:

```hcl
variable "name_prefix"        { type = string }
variable "input_bucket_name"  { type = string }
variable "sfn_arn"            { type = string }
variable "eventbridge_role_arn" { type = string }
```

`terraform/modules/eventbridge/outputs.tf`:

```hcl
output "rule_name" { value = aws_cloudwatch_event_rule.s3_to_sfn.name }
output "rule_arn"  { value = aws_cloudwatch_event_rule.s3_to_sfn.arn }
```

---

### 5-3. environments/dev/main.tf にEventBridgeを追加

```hcl
module "eventbridge" {
  source               = "../../modules/eventbridge"
  name_prefix          = local.name_prefix
  input_bucket_name    = module.s3.input_bucket_name
  sfn_arn              = module.step_functions.state_machine_arn
  eventbridge_role_arn = module.iam.eventbridge_role_arn
}
```

`terraform/environments/dev/outputs.tf` に追記:

```hcl
output "state_machine_arn" { value = module.step_functions.state_machine_arn }
output "eventbridge_rule"  { value = module.eventbridge.rule_name }
```

---

### 5-4. Apply

```bash
cd terraform/environments/dev
terraform apply -auto-approve

# EventBridgeルールが作成されているか確認
aws events list-rules --name-prefix "aip-dev" --region ap-northeast-1
```

---

### 5-5. E2Eテストスクリプト作成

`scripts/e2e_test.sh`:

```bash
#!/bin/bash
# E2Eテスト: S3アップロードからChatwork通知までの全フローを検証
set -euo pipefail

cd "$(dirname "$0")/../terraform/environments/dev"

INPUT_BUCKET=$(terraform output -raw input_bucket_name)
SFN_ARN=$(terraform output -raw state_machine_arn)
DYNAMODB_TABLE=$(terraform output -raw dynamodb_table_name)
REGION="ap-northeast-1"

echo "======================================"
echo "AI推論パイプライン E2Eテスト開始"
echo "======================================"

# Step 1: テストデータ生成・アップロード
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TEST_KEY="input/e2e_test_${TIMESTAMP}.csv"

cat << EOF > /tmp/e2e_input.csv
id,title,description,category
1,ECS Fargate,サーバーレスコンテナ実行環境,infra
2,Amazon Bedrock,生成AI基盤サービス,ai
3,Step Functions,サーバーレスワークフローオーケストレーター,serverless
4,Terraform,IaCツール,devops
EOF

echo "[1/5] テストデータをS3にアップロード中..."
aws s3 cp /tmp/e2e_input.csv "s3://$INPUT_BUCKET/$TEST_KEY" --region "$REGION"
echo "    完了: s3://$INPUT_BUCKET/$TEST_KEY"

# Step 2: Step Functions実行の開始を検知（EventBridge経由のため数秒待機）
echo "[2/5] EventBridgeトリガーを待機中 (15秒)..."
sleep 15

# 最新の実行ARNを取得
EXECUTION_ARN=$(aws stepfunctions list-executions \
  --state-machine-arn "$SFN_ARN" \
  --status-filter "RUNNING" \
  --max-results 1 \
  --query 'executions[0].executionArn' \
  --output text \
  --region "$REGION")

if [ "$EXECUTION_ARN" = "None" ] || [ -z "$EXECUTION_ARN" ]; then
  # RUNNINGがなければ最新の実行（SUCCEEDED/FAILEDも含む）を確認
  EXECUTION_ARN=$(aws stepfunctions list-executions \
    --state-machine-arn "$SFN_ARN" \
    --max-results 1 \
    --query 'executions[0].executionArn' \
    --output text \
    --region "$REGION")
fi

echo "    実行ARN: $EXECUTION_ARN"

# Step 3: 実行完了まで待機（最大5分）
echo "[3/5] パイプライン完了を待機中..."
MAX_WAIT=300
ELAPSED=0
INTERVAL=15

while [ $ELAPSED -lt $MAX_WAIT ]; do
  STATUS=$(aws stepfunctions describe-execution \
    --execution-arn "$EXECUTION_ARN" \
    --query 'status' \
    --output text \
    --region "$REGION")

  echo "    ステータス: $STATUS (経過: ${ELAPSED}秒)"

  if [ "$STATUS" = "SUCCEEDED" ]; then
    echo "    ✅ パイプライン成功"
    break
  elif [ "$STATUS" = "FAILED" ] || [ "$STATUS" = "ABORTED" ] || [ "$STATUS" = "TIMED_OUT" ]; then
    echo "    ❌ パイプライン失敗: $STATUS"
    # 失敗詳細を表示
    aws stepfunctions describe-execution \
      --execution-arn "$EXECUTION_ARN" \
      --region "$REGION" \
      --query '{cause: cause, error: error}'
    exit 1
  fi

  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
  echo "タイムアウト: ${MAX_WAIT}秒以内に完了しませんでした"
  exit 1
fi

# Step 4: DynamoDB結果確認
echo "[4/5] DynamoDB結果を確認..."
RESULT=$(aws dynamodb scan \
  --table-name "$DYNAMODB_TABLE" \
  --filter-expression "#s = :completed" \
  --expression-attribute-names '{"#s": "status"}' \
  --expression-attribute-values '{":completed": {"S": "completed"}}' \
  --query 'Count' \
  --output text \
  --region "$REGION")

echo "    DynamoDB完了レコード数: $RESULT"

if [ "$RESULT" -gt 0 ]; then
  echo "    ✅ DynamoDB確認OK"
else
  echo "    ❌ DynamoDBにレコードが存在しません"
  exit 1
fi

# Step 5: 実行時間計測
echo "[5/5] パフォーマンス計測..."
aws stepfunctions describe-execution \
  --execution-arn "$EXECUTION_ARN" \
  --region "$REGION" \
  --query '{
    StartDate: startDate,
    StopDate: stopDate,
    Status: status
  }'

echo ""
echo "======================================"
echo "✅ E2Eテスト完了"
echo "======================================"
```

```bash
chmod +x scripts/e2e_test.sh
```

---

### 5-6. E2Eテスト実行

```bash
bash scripts/e2e_test.sh
```

---

### 5-7. CloudWatch Logs Insightsでパフォーマンス確認

AWSコンソール → CloudWatch → Logs Insights で以下のクエリを実行:

```
# Step Functions実行ログ（/aip/dev/step-functions）
fields @timestamp, type, details.name, details.output
| filter type = "TaskStateExited"
| sort @timestamp asc
```

```
# Lambda Bedrock処理時間（/aws/lambda/aip-dev-invoke-bedrock）
fields @timestamp, @duration, @billedDuration
| stats avg(@duration), max(@duration), min(@duration) by bin(5m)
```

---

## 完了チェックリスト

- [ ] S3アップロードだけでStep Functionsが自動起動する
- [ ] E2Eテストが `✅ E2Eテスト完了` で終了する
- [ ] DynamoDBに推論結果が蓄積されている
- [ ] Chatworkに通知が届いている
- [ ] CloudWatch Logsで全コンポーネントのログが確認できる

## 計測値の記録（面接で使える数字）
以下を実測して記録しておくこと:

| 指標 | 計測値 |
|---|---|
| パイプライン総実行時間（E2E） | ___秒 |
| ECS前処理タスク実行時間 | ___秒 |
| Bedrock推論レイテンシ | ___ms |
| EventBridgeトリガーのラグ | ___秒 |
| DynamoDB書き込みレイテンシ | ___ms |

## 口頭説明チェックポイント
- 「なぜSNSではなくEventBridgeを使うのか？」
- 「input_transformerで何を行っているか？」
- 「S3の `eventbridge = true` と従来のSNS通知の違いは？」