terraform {
  required_providers {
    archive = {
      source = "hashicorp/archive"
    }
  }
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${var.name_prefix}-receiver"
  retention_in_days = 7
}

data "archive_file" "receiver" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/receiver.zip"
}

resource "aws_lambda_function" "this" {
  function_name    = "${var.name_prefix}-receiver"
  runtime          = "python3.12"
  handler          = "receiver.lambda_handler"
  architectures    = ["arm64"]
  timeout          = 30
  memory_size      = 256
  role             = var.receiver_role_arn
  filename         = data.archive_file.receiver.output_path
  source_code_hash = data.archive_file.receiver.output_base64sha256

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [var.sg_lambda_receiver_id]
  }

  environment {
    variables = {
      FIREHOSE_STREAM_NAME    = var.firehose_stream_name
      POWERTOOLS_SERVICE_NAME = "http-receiver"
      LOG_LEVEL               = "INFO"
    }
  }

  depends_on = [aws_cloudwatch_log_group.this]
}

resource "aws_lambda_permission" "allow_alb" {
  count = var.alb_target_group_arn != "" ? 1 : 0

  statement_id  = "AllowALBInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this.function_name
  principal     = "elasticloadbalancing.amazonaws.com"
  source_arn    = var.alb_target_group_arn
}
