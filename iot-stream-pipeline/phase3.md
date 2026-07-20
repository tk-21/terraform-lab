# Phase 3 — API Gateway 構築 (REST API / Lambda プロキシ統合)

## 目標
DynamoDBに蓄積されたセンサーデータをHTTP GETで取得できるREST APIを構築する。
`GET /sensors/{device_id}` エンドポイントをAPI Gatewayで公開し、readerLambdaと接続する。

## 前提条件
- Phase2が完了し `phase2_outputs.json` が存在すること
- reader Lambdaが正常に動作確認済みであること

---

## Step 1: API Gatewayモジュール作成

### `terraform/modules/apigateway/variables.tf`
```hcl
variable "project_name" { type = string }
variable "reader_invoke_arn" { type = string }
variable "reader_function_name" { type = string }
```

### `terraform/modules/apigateway/main.tf`
```hcl
# REST APIを選択する
# 理由: HTTP APIより機能が豊富で、将来的なAPIキー認証やUsagePlanの追加が容易
resource "aws_api_gateway_rest_api" "sensors" {
  name        = "${var.project_name}-api"
  description = "IoTセンサーデータ取得API"

  endpoint_configuration {
    # REGIONALエンドポイントを使用する
    # 理由: ハンズオン用途ではCloudFront統合が不要のため、シンプルな構成にする
    types = ["REGIONAL"]
  }

  tags = {
    Project = var.project_name
  }
}

# /sensors リソース
resource "aws_api_gateway_resource" "sensors" {
  rest_api_id = aws_api_gateway_rest_api.sensors.id
  parent_id   = aws_api_gateway_rest_api.sensors.root_resource_id
  path_part   = "sensors"
}

# /sensors/{device_id} リソース
resource "aws_api_gateway_resource" "device" {
  rest_api_id = aws_api_gateway_rest_api.sensors.id
  parent_id   = aws_api_gateway_resource.sensors.id
  path_part   = "{device_id}"
}

# GET メソッド (認証なし — ハンズオン用途)
resource "aws_api_gateway_method" "get_device" {
  rest_api_id   = aws_api_gateway_rest_api.sensors.id
  resource_id   = aws_api_gateway_resource.device.id
  http_method   = "GET"
  # 本番ではAWS_IAMまたはCOGNITO_USER_POOLSを使用する
  authorization = "NONE"

  request_parameters = {
    # limitクエリパラメータをオプションとして宣言する
    "method.request.querystring.limit" = false
  }
}

# Lambda プロキシ統合
# 理由: プロキシ統合を使うことで、Lambda側でレスポンス形式を完全に制御できる
#       マッピングテンプレートの管理が不要になる
resource "aws_api_gateway_integration" "lambda_proxy" {
  rest_api_id             = aws_api_gateway_rest_api.sensors.id
  resource_id             = aws_api_gateway_resource.device.id
  http_method             = aws_api_gateway_method.get_device.http_method
  integration_http_method = "POST"  # Lambda呼び出しは常にPOST
  type                    = "AWS_PROXY"
  uri                     = var.reader_invoke_arn
}

# API GatewayにLambda呼び出し権限を付与する
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = var.reader_function_name
  principal     = "apigateway.amazonaws.com"
  # 特定のAPIとメソッドのみに限定する
  source_arn    = "${aws_api_gateway_rest_api.sensors.execution_arn}/*/*"
}

# ステージデプロイ
resource "aws_api_gateway_deployment" "v1" {
  rest_api_id = aws_api_gateway_rest_api.sensors.id

  # メソッドと統合の変更後に再デプロイするためのトリガー
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_method.get_device,
      aws_api_gateway_integration.lambda_proxy,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_method.get_device,
    aws_api_gateway_integration.lambda_proxy,
  ]
}

resource "aws_api_gateway_stage" "v1" {
  deployment_id = aws_api_gateway_deployment.v1.id
  rest_api_id   = aws_api_gateway_rest_api.sensors.id
  stage_name    = "v1"

  # アクセスログを有効化する
  # 理由: リクエスト/レスポンスのトレーサビリティをCloudWatchで確認するため
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.apigw.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      resourcePath   = "$context.resourcePath"
      status         = "$context.status"
      responseLength = "$context.responseLength"
      integrationLatency = "$context.integrationLatency"
    })
  }

  tags = {
    Project = var.project_name
  }
}

resource "aws_cloudwatch_log_group" "apigw" {
  name              = "/aws/apigateway/${var.project_name}"
  # ログは7日間保持する (ハンズオン用途では短期間で十分)
  retention_in_days = 7
}
```

### `terraform/modules/apigateway/outputs.tf`
```hcl
output "api_endpoint" {
  description = "センサーデータ取得APIのベースURL"
  value       = "${aws_api_gateway_stage.v1.invoke_url}/sensors"
}

output "api_id" {
  value = aws_api_gateway_rest_api.sensors.id
}
```

---

## Step 2: main.tf にAPI Gatewayモジュールを追加

`terraform/main.tf` に追記:
```hcl
module "apigateway" {
  source = "./modules/apigateway"

  project_name         = var.project_name
  reader_invoke_arn    = module.lambda.reader_invoke_arn
  reader_function_name = module.lambda.reader_function_name
}
```

`terraform/outputs.tf` に追記:
```hcl
output "api_endpoint" {
  description = "センサーデータ取得APIエンドポイント"
  value       = module.apigateway.api_endpoint
}
```

---

## Step 3: デプロイ実行

```bash
# image URIを再読み込み (セッションが切れている場合)
source phase2_image_uris.env

cd terraform
terraform apply \
  -var="processor_image_uri=${PROCESSOR_IMAGE_URI}" \
  -var="reader_image_uri=${READER_IMAGE_URI}" \
  -auto-approve

terraform output -json > ../phase3_outputs.json
API_ENDPOINT=$(jq -r '.api_endpoint.value' ../phase3_outputs.json)
echo "API エンドポイント: ${API_ENDPOINT}"
```

---

## Step 4: API動作確認

```bash
API_ENDPOINT=$(jq -r '.api_endpoint.value' phase3_outputs.json)

# device-001のデータを取得
curl -s "${API_ENDPOINT}/device-001" | jq .

# limit=3で最新3件を取得
curl -s "${API_ENDPOINT}/device-001?limit=3" | jq .

# 存在しないdevice_idの場合のレスポンス確認
curl -s "${API_ENDPOINT}/device-999" | jq .
```

期待するレスポンス例:
```json
{
  "device_id": "device-001",
  "count": 1,
  "items": [
    {
      "device_id": "device-001",
      "timestamp": "2024-01-01T00:00:00Z",
      "temperature": "25.3",
      "humidity": "60.1",
      "status": "normal"
    }
  ]
}
```

---

## 完了チェックリスト

```bash
# API GatewayのステージがACTIVEか
aws apigateway get-stage \
  --rest-api-id $(jq -r '.api_id // empty' phase3_outputs.json 2>/dev/null || \
    aws apigateway get-rest-apis --query 'items[?name==`iot-pipeline-api`].id' --output text) \
  --stage-name v1 \
  --query 'deploymentId'

# CloudWatchにアクセスログが記録されているか (curl後に確認)
aws logs tail /aws/apigateway/iot-pipeline --since 5m
```

---

## 口頭説明チェックポイント ✅

1. **Lambda プロキシ統合と非プロキシ統合の違いは？** (マッピングテンプレートの有無とユースケース)
2. **API Gatewayのデプロイメントとステージの関係は？** (イミュータブルなスナップショットとステージ参照)
3. **`integration_http_method = "POST"` にする理由は？** (LambdaのInvoke APIがPOSTを使う仕様)
4. **アクセスログとCloudWatch X-Rayトレーシングの違いは？** (ログvsトレース)