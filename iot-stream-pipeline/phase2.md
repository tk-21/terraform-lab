# Phase 2 — Lambdaコンテナ構築 (Docker / ECR / Kinesis トリガー)

## 目標
processorとreaderのLambda関数をコンテナイメージとして構築・ECRプッシュし、
KinesisストリームのイベントソースマッピングでLambdaを自動起動できる状態にする。

## 前提条件
- Phase1が完了し `phase1_outputs.json` が存在すること
- Docker Daemonが起動していること (`docker info` で確認)
- AWS CLIのECR認証が可能なIAMロール/ユーザーを使用していること

---

## Step 1: Lambdaソースコード作成

### `lambda/processor/requirements.txt`
```
aws-lambda-powertools==2.43.0
boto3==1.34.0
```

### `lambda/processor/app.py`
```python
"""
Kinesis → DynamoDB ストリーム処理Lambda

設計方針:
- base64デコード後にJSONパースする (Kinesisはbase64エンコードしてデータを渡す)
- TTLは受信時刻+72時間で設定する (ハンズオンデータの自動クリーンアップ)
- バッチ内の1件でも失敗した場合はbisect_on_function_error=trueで部分リトライする
"""

import base64
import json
import os
import time
from datetime import datetime, timezone

import boto3
from aws_lambda_powertools import Logger
from aws_lambda_powertools.utilities.typing import LambdaContext

logger = Logger(service="iot-processor")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["DYNAMODB_TABLE_NAME"])

TTL_SECONDS = 72 * 60 * 60  # 72時間後に自動削除


@logger.inject_lambda_context(log_event=False)
def handler(event: dict, context: LambdaContext) -> dict:
    records = event.get("Records", [])
    logger.info(f"受信レコード数: {len(records)}")

    failed_items = []

    for record in records:
        try:
            # KinesisはデータをBase64エンコードして渡すため、デコードが必須
            raw_data = base64.b64decode(record["kinesis"]["data"]).decode("utf-8")
            sensor_data = json.loads(raw_data)

            device_id = sensor_data["device_id"]
            timestamp = sensor_data.get("timestamp", datetime.now(timezone.utc).isoformat())

            item = {
                "device_id": device_id,
                "timestamp": timestamp,
                "temperature": str(sensor_data.get("temperature", 0)),
                "humidity": str(sensor_data.get("humidity", 0)),
                "status": sensor_data.get("status", "unknown"),
                # TTLはUnixタイムスタンプ(秒)で指定する必要がある
                "expires_at": int(time.time()) + TTL_SECONDS,
            }

            table.put_item(Item=item)
            logger.info(f"書き込み成功: device_id={device_id}, timestamp={timestamp}")

        except Exception as e:
            logger.error(f"レコード処理失敗: {e}", exc_info=True)
            # 失敗したシーケンス番号を返すことで部分的なリトライが可能になる
            failed_items.append(
                {"itemIdentifier": record["kinesis"]["sequenceNumber"]}
            )

    # 失敗したアイテムのみKinesisに返す (bisectOnFunctionError と組み合わせる)
    return {"batchItemFailures": failed_items}
```

### `lambda/processor/Dockerfile`
```dockerfile
# AWS公式のLambda Python 3.12 arm64ベースイメージを使用する
# 理由: Graviton2(arm64)はx86_64比でコスト約20%削減かつ高性能
FROM public.ecr.aws/lambda/python:3.12-arm64

# 依存関係を先にコピーしてキャッシュを活かす
# 理由: app.pyの変更時にpip installを再実行しないようにする
COPY requirements.txt ${LAMBDA_TASK_ROOT}/
RUN pip install --no-cache-dir -r ${LAMBDA_TASK_ROOT}/requirements.txt

COPY app.py ${LAMBDA_TASK_ROOT}/

CMD ["app.handler"]
```

---

### `lambda/reader/requirements.txt`
```
aws-lambda-powertools==2.43.0
boto3==1.34.0
```

### `lambda/reader/app.py`
```python
"""
API Gateway → DynamoDB 読み取りLambda

設計方針:
- device_idによる最新データ取得と、時系列範囲クエリの2パターンをサポートする
- Lambda Proxy統合を前提とし、API Gatewayがそのままレスポンスを返す形式にする
- Decimalはfloatに変換してJSONシリアライズエラーを防ぐ
"""

import json
import os
from decimal import Decimal

import boto3
from aws_lambda_powertools import Logger
from boto3.dynamodb.conditions import Key
from aws_lambda_powertools.utilities.typing import LambdaContext

logger = Logger(service="iot-reader")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["DYNAMODB_TABLE_NAME"])


def decimal_to_float(obj):
    """DynamoDBのDecimal型をJSONシリアライズ可能なfloatに変換する"""
    if isinstance(obj, Decimal):
        return float(obj)
    raise TypeError(f"シリアライズ不可能な型: {type(obj)}")


@logger.inject_lambda_context(log_event=True)
def handler(event: dict, context: LambdaContext) -> dict:
    path_params = event.get("pathParameters") or {}
    query_params = event.get("queryStringParameters") or {}

    device_id = path_params.get("device_id")
    if not device_id:
        return {
            "statusCode": 400,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": "device_idは必須パラメータです"}),
        }

    limit = int(query_params.get("limit", 10))

    try:
        # ScanIndexForward=Falseで最新データを先頭に取得する
        # 理由: センサー監視では最新の状態を最優先で確認するユースケースが多い
        response = table.query(
            KeyConditionExpression=Key("device_id").eq(device_id),
            ScanIndexForward=False,
            Limit=limit,
        )
        items = response.get("Items", [])
        logger.info(f"取得件数: {len(items)}, device_id={device_id}")

        return {
            "statusCode": 200,
            "headers": {
                "Content-Type": "application/json",
                "Access-Control-Allow-Origin": "*",
            },
            "body": json.dumps(
                {"device_id": device_id, "count": len(items), "items": items},
                default=decimal_to_float,
                ensure_ascii=False,
            ),
        }

    except Exception as e:
        logger.error(f"DynamoDBクエリ失敗: {e}", exc_info=True)
        return {
            "statusCode": 500,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": "データ取得に失敗しました"}),
        }
```

### `lambda/reader/Dockerfile`
```dockerfile
FROM public.ecr.aws/lambda/python:3.12-arm64

COPY requirements.txt ${LAMBDA_TASK_ROOT}/
RUN pip install --no-cache-dir -r ${LAMBDA_TASK_ROOT}/requirements.txt

COPY app.py ${LAMBDA_TASK_ROOT}/

CMD ["app.handler"]
```

---

## Step 2: Lambdaモジュール作成 (Terraform)

### `terraform/modules/lambda/variables.tf`
```hcl
variable "project_name" { type = string }
variable "processor_image_uri" { type = string }
variable "reader_image_uri" { type = string }
variable "dynamodb_table_name" { type = string }
variable "dynamodb_table_arn" { type = string }
variable "kinesis_stream_arn" { type = string }
```

### `terraform/modules/lambda/main.tf`
```hcl
# Lambda実行ロール (processor用)
# 理由: processorとreaderでDynamoDBへの操作が異なるため、ロールを分離する
resource "aws_iam_role" "processor" {
  name = "${var.project_name}-processor-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "processor" {
  name = "${var.project_name}-processor-policy"
  role = aws_iam_role.processor.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # CloudWatch Logsへの書き込み権限
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        # Kinesisからの読み取り権限 (ESMが使用する)
        Effect = "Allow"
        Action = [
          "kinesis:GetRecords",
          "kinesis:GetShardIterator",
          "kinesis:DescribeStream",
          "kinesis:ListShards",
          "kinesis:ListStreams"
        ]
        # 特定のストリームARNのみに限定する
        Resource = var.kinesis_stream_arn
      },
      {
        # DynamoDBへの書き込み権限のみ (読み取り不要)
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:BatchWriteItem"]
        Resource = var.dynamodb_table_arn
      }
    ]
  })
}

resource "aws_lambda_function" "processor" {
  function_name = "${var.project_name}-processor"
  role          = aws_iam_role.processor.arn
  package_type  = "Image"
  image_uri     = var.processor_image_uri

  # Graviton2 arm64を使用する
  # 理由: x86_64比でコスト約20%削減、同等以上のパフォーマンス
  architectures = ["arm64"]

  timeout      = 60   # Kinesisバッチ処理のタイムアウト余裕を持たせる
  memory_size  = 256

  environment {
    variables = {
      DYNAMODB_TABLE_NAME = var.dynamodb_table_name
      POWERTOOLS_LOG_LEVEL = "INFO"
    }
  }

  tags = {
    Project = var.project_name
    Role    = "Kinesisストリーム処理"
  }
}

# Kinesisイベントソースマッピング
resource "aws_lambda_event_source_mapping" "kinesis_processor" {
  event_source_arn  = var.kinesis_stream_arn
  function_name     = aws_lambda_function.processor.arn
  starting_position = "LATEST"

  # バッチサイズを100に設定する
  # 理由: Lambda起動オーバーヘッドを減らしつつ、メモリ使用量を抑えるバランス
  batch_size = 100

  # bisect_on_function_errorで失敗バッチを2分割してリトライする
  # 理由: 1件の不正レコードでバッチ全体が止まることを防ぐ
  bisect_batch_on_function_error = true

  # 最大10分間バッファリングしてバッチを大きくする
  maximum_batching_window_in_seconds = 10
}

# reader Lambda用ロール
resource "aws_iam_role" "reader" {
  name = "${var.project_name}-reader-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "reader" {
  name = "${var.project_name}-reader-policy"
  role = aws_iam_role.reader.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        # 読み取り専用 — 書き込み権限は意図的に除外する
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:Query"]
        Resource = var.dynamodb_table_arn
      }
    ]
  })
}

resource "aws_lambda_function" "reader" {
  function_name = "${var.project_name}-reader"
  role          = aws_iam_role.reader.arn
  package_type  = "Image"
  image_uri     = var.reader_image_uri
  architectures = ["arm64"]
  timeout       = 10
  memory_size   = 128

  environment {
    variables = {
      DYNAMODB_TABLE_NAME  = var.dynamodb_table_name
      POWERTOOLS_LOG_LEVEL = "INFO"
    }
  }

  tags = {
    Project = var.project_name
    Role    = "API Gateway経由DynamoDB読み取り"
  }
}
```

### `terraform/modules/lambda/outputs.tf`
```hcl
output "processor_function_name" {
  value = aws_lambda_function.processor.function_name
}

output "reader_function_name" {
  value = aws_lambda_function.reader.function_name
}

output "reader_function_arn" {
  value = aws_lambda_function.reader.arn
}

output "reader_invoke_arn" {
  value = aws_lambda_function.reader.invoke_arn
}
```

---

## Step 3: Dockerビルド & ECRプッシュスクリプト

### `scripts/push_images.sh`
```bash
#!/bin/bash
set -euo pipefail

# phase1_outputs.jsonからECR URLとアカウントIDを取得する
ACCOUNT_ID=$(jq -r '.aws_account_id.value' phase1_outputs.json)
REGION="ap-northeast-1"
PROCESSOR_URL=$(jq -r '.ecr_processor_url.value' phase1_outputs.json)
READER_URL=$(jq -r '.ecr_reader_url.value' phase1_outputs.json)

echo "=== ECRログイン ==="
aws ecr get-login-password --region "${REGION}" | \
  docker login --username AWS --password-stdin \
  "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "=== processorイメージビルド & プッシュ ==="
# arm64でビルドする (Graviton2 Lambda対応)
# ローカルがx86_64の場合はbuildxを使ってクロスコンパイルする
docker buildx build \
  --platform linux/arm64 \
  --tag "${PROCESSOR_URL}:latest" \
  --push \
  lambda/processor/

echo "=== readerイメージビルド & プッシュ ==="
docker buildx build \
  --platform linux/arm64 \
  --tag "${READER_URL}:latest" \
  --push \
  lambda/reader/

echo "=== プッシュ完了 ==="
echo "processor: ${PROCESSOR_URL}:latest"
echo "reader:    ${READER_URL}:latest"

# image URIをファイルに保存 (Phase2のTerraform applyで使用)
cat > phase2_image_uris.env << EOF
PROCESSOR_IMAGE_URI=${PROCESSOR_URL}:latest
READER_IMAGE_URI=${READER_URL}:latest
EOF
echo "image URIを phase2_image_uris.env に保存しました"
```

---

## Step 4: main.tfにLambdaモジュールを追加

`terraform/main.tf` に以下を追記する:

```hcl
# image URIはECRプッシュ後に確定するため、variableとして渡す
module "lambda" {
  source = "./modules/lambda"

  project_name        = var.project_name
  processor_image_uri = var.processor_image_uri
  reader_image_uri    = var.reader_image_uri
  dynamodb_table_name = module.dynamodb.table_name
  dynamodb_table_arn  = module.dynamodb.table_arn
  kinesis_stream_arn  = module.kinesis.stream_arn
}
```

`terraform/variables.tf` に追記:
```hcl
variable "processor_image_uri" {
  description = "processorLambdaのECRイメージURI"
  type        = string
}

variable "reader_image_uri" {
  description = "readerLambdaのECRイメージURI"
  type        = string
}
```

`terraform/outputs.tf` に追記:
```hcl
output "reader_invoke_arn" {
  description = "readerLambdaのinvoke ARN (API Gateway設定で使用)"
  value       = module.lambda.reader_invoke_arn
}
```

---

## Step 5: 実行

```bash
# 1. Dockerビルド & ECRプッシュ
chmod +x scripts/push_images.sh
./scripts/push_images.sh

# 2. image URIを読み込み
source phase2_image_uris.env

# 3. Lambdaリソースをデプロイ
cd terraform
terraform apply \
  -var="processor_image_uri=${PROCESSOR_IMAGE_URI}" \
  -var="reader_image_uri=${READER_IMAGE_URI}" \
  -auto-approve

terraform output -json > ../phase2_outputs.json
```

---

## 完了チェックリスト

```bash
# processorが存在し、イメージURIが設定されているか
aws lambda get-function \
  --function-name iot-pipeline-processor \
  --query 'Configuration.{State:State,Arch:Architectures}'

# KinesisとLambdaのイベントソースマッピングが有効か
aws lambda list-event-source-mappings \
  --function-name iot-pipeline-processor \
  --query 'EventSourceMappings[*].{State:State,BatchSize:BatchSize}'

# テストレコードを送信して動作確認
aws kinesis put-record \
  --stream-name iot-pipeline-stream \
  --partition-key "device-001" \
  --data "$(echo '{"device_id":"device-001","temperature":25.3,"humidity":60.1,"status":"normal","timestamp":"2024-01-01T00:00:00Z"}' | base64)"

# 30秒後にDynamoDBで確認
sleep 30
aws dynamodb get-item \
  --table-name iot-pipeline-table \
  --key '{"device_id":{"S":"device-001"},"timestamp":{"S":"2024-01-01T00:00:00Z"}}'
```

---

## 口頭説明チェックポイント ✅

1. **なぜLambdaをZIPではなくコンテナイメージでデプロイするか？** (依存関係管理・イメージサイズ・ポータビリティの観点から)
2. **bisect_on_function_errorは何のために設定するか？** (1件の不正データでバッチ全体が止まる問題の解決策)
3. **arm64 (linux/arm64) でビルドする理由は？** (コスト・パフォーマンスのトレードオフ)
4. **processorとreaderのIAMロールを分離した理由は？** (最小権限原則の観点から)