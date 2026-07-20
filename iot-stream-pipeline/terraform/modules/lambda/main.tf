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
        # 理由: このLambdaのロググループのみに限定し、他のロググループへの書き込みを防ぐ
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = [
          "arn:aws:logs:*:*:log-group:/aws/lambda/${var.project_name}-processor",
          "arn:aws:logs:*:*:log-group:/aws/lambda/${var.project_name}-processor:*",
        ]
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

  timeout     = 60 # Kinesisバッチ処理のタイムアウト余裕を持たせる
  memory_size = 256

  environment {
    variables = {
      DYNAMODB_TABLE_NAME  = var.dynamodb_table_name
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

  # bisect_batch_on_function_errorで失敗バッチを2分割してリトライする
  # 理由: 1件の不正レコードでバッチ全体が止まることを防ぐ
  bisect_batch_on_function_error = true

  # 最大10秒間バッファリングしてバッチを大きくする
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
        Resource = [
          "arn:aws:logs:*:*:log-group:/aws/lambda/${var.project_name}-reader",
          "arn:aws:logs:*:*:log-group:/aws/lambda/${var.project_name}-reader:*",
        ]
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
