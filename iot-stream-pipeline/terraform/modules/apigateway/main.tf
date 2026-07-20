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
  rest_api_id = aws_api_gateway_rest_api.sensors.id
  resource_id = aws_api_gateway_resource.device.id
  http_method = "GET"
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
  integration_http_method = "POST" # Lambda呼び出しは常にPOST
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
  source_arn = "${aws_api_gateway_rest_api.sensors.execution_arn}/*/*"
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
      requestId          = "$context.requestId"
      ip                 = "$context.identity.sourceIp"
      requestTime        = "$context.requestTime"
      httpMethod         = "$context.httpMethod"
      resourcePath       = "$context.resourcePath"
      status             = "$context.status"
      responseLength     = "$context.responseLength"
      integrationLatency = "$context.integrationLatency"
    })
  }

  tags = {
    Project = var.project_name
  }
}

resource "aws_cloudwatch_log_group" "apigw" {
  name = "/aws/apigateway/${var.project_name}"
  # ログは7日間保持する (ハンズオン用途では短期間で十分)
  retention_in_days = 7
}
