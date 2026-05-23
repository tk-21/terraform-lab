# Lambda用ロググループ（保持期間を短くしてコスト抑制）
resource "aws_cloudwatch_log_group" "bedrock" {
  name              = "/aws/lambda/${var.name_prefix}-invoke-bedrock"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "notify" {
  name              = "/aws/lambda/${var.name_prefix}-notify-chatwork"
  retention_in_days = 7
}

# Bedrock推論Lambdaのパッケージング
# Lambda Powertoolsはlayerで提供されているためzipには含めない
data "archive_file" "invoke_bedrock" {
  type        = "zip"
  source_dir  = "${path.root}/../../../lambda/invoke_bedrock"
  output_path = "${path.module}/artifacts/invoke_bedrock.zip"
}

data "archive_file" "notify_chatwork" {
  type        = "zip"
  source_dir  = "${path.root}/../../../lambda/notify_chatwork"
  output_path = "${path.module}/artifacts/notify_chatwork.zip"
}

# Lambda Powertoolsのマネージドレイヤー（arm64用、クロスアカウント公開レイヤー）
# バージョン未指定で最新を取得する
data "aws_lambda_layer_version" "powertools" {
  layer_name = "arn:aws:lambda:ap-northeast-1:017000801446:layer:AWSLambdaPowertoolsPythonV3-python312-arm64"
}

resource "aws_lambda_function" "invoke_bedrock" {
  function_name = "${var.name_prefix}-invoke-bedrock"
  role          = var.lambda_bedrock_role_arn
  handler       = "main.handler"
  runtime       = "python3.12"

  # Graviton2でコスト最適化
  architectures = ["arm64"]
  timeout       = 120 # Bedrock推論は最大60秒程度かかる場合があるため余裕を持たせる
  memory_size   = 256

  filename         = data.archive_file.invoke_bedrock.output_path
  source_code_hash = data.archive_file.invoke_bedrock.output_base64sha256

  layers = [data.aws_lambda_layer_version.powertools.arn]

  environment {
    variables = {
      DYNAMODB_TABLE          = var.dynamodb_table_name
      BEDROCK_MODEL_ID        = "anthropic.claude-3-haiku-20240307-v1:0"
      OUTPUT_BUCKET           = var.output_bucket_name
      POWERTOOLS_SERVICE_NAME = "invoke-bedrock"
      LOG_LEVEL               = "INFO"
    }
  }

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  depends_on = [aws_cloudwatch_log_group.bedrock]
}

resource "aws_lambda_function" "notify_chatwork" {
  function_name = "${var.name_prefix}-notify-chatwork"
  role          = var.lambda_notify_role_arn
  handler       = "main.handler"
  runtime       = "python3.12"
  architectures = ["arm64"]
  timeout       = 30
  memory_size   = 128 # 通知のみのため最小メモリで十分

  filename         = data.archive_file.notify_chatwork.output_path
  source_code_hash = data.archive_file.notify_chatwork.output_base64sha256

  layers = [data.aws_lambda_layer_version.powertools.arn]

  environment {
    variables = {
      CHATWORK_ROOM_ID        = var.chatwork_room_id
      SSM_TOKEN_PATH          = "/aip/${var.env}/chatwork/token"
      POWERTOOLS_SERVICE_NAME = "notify-chatwork"
      LOG_LEVEL               = "INFO"
    }
  }

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  depends_on = [aws_cloudwatch_log_group.notify]
}

# Lambdaのセキュリティグループ
resource "aws_security_group" "lambda" {
  name        = "${var.name_prefix}-lambda-sg"
  description = "Lambda関数用 - VPC Endpoint経由のAWSサービス通信のみ"
  vpc_id      = var.vpc_id

  # アウトバウンドのみ（インバウンドルールなし = Step Functionsからの呼び出しはSG不要）
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS: VPC Endpoint / Chatwork API"
  }
}
