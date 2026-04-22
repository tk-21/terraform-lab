# terraform apply前に scripts/build_lambda.sh でlambda_producer.zipの生成が必要
resource "aws_lambda_function" "producer" {
  function_name = "${var.name_prefix}-producer"
  role          = var.lambda_role_arn
  runtime       = "python3.12"
  handler       = "producer.lambda_handler"
  architectures = ["arm64"]
  timeout       = 60
  memory_size   = 256

  filename         = "${path.module}/lambda_producer.zip"
  source_code_hash = filebase64sha256("${path.module}/lambda_producer.zip")

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [var.sg_lambda_id]
  }

  environment {
    variables = {
      MSK_BOOTSTRAP_SERVERS   = var.msk_bootstrap_brokers
      KAFKA_TOPIC             = "streaming-events"
      POWERTOOLS_SERVICE_NAME = "kafka-producer"
      LOG_LEVEL               = "INFO"
    }
  }

  depends_on = [aws_cloudwatch_log_group.producer]

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "producer" {
  name              = "/aws/lambda/${var.name_prefix}-producer"
  retention_in_days = 7
  tags              = var.tags
}

# EventBridge Scheduler用IAMロール（LambdaInvokeを許可）
resource "aws_iam_role" "scheduler" {
  name = "${var.name_prefix}-scheduler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "scheduler.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "scheduler_invoke" {
  name = "${var.name_prefix}-scheduler-invoke-policy"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.producer.arn
    }]
  })
}

# EventBridge Scheduler: 5分おきにLambdaを自動実行
resource "aws_scheduler_schedule" "producer" {
  name       = "${var.name_prefix}-producer-schedule"
  group_name = "default"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression = "rate(5 minutes)"

  target {
    arn      = aws_lambda_function.producer.arn
    role_arn = aws_iam_role.scheduler.arn
  }
}
