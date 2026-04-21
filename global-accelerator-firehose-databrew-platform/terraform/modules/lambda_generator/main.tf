terraform {
  required_providers {
    archive = {
      source = "hashicorp/archive"
    }
  }
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${var.name_prefix}-generator"
  retention_in_days = 7
}

data "archive_file" "generator" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/generator.zip"
}

resource "aws_lambda_function" "this" {
  function_name    = "${var.name_prefix}-generator"
  runtime          = "python3.12"
  handler          = "generator.lambda_handler"
  architectures    = ["arm64"]
  timeout          = 120
  memory_size      = 128
  role             = var.generator_role_arn
  filename         = data.archive_file.generator.output_path
  source_code_hash = data.archive_file.generator.output_base64sha256

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [var.sg_lambda_generator_id]
  }

  environment {
    variables = {
      ACCELERATOR_ENDPOINT    = var.accelerator_endpoint
      POWERTOOLS_SERVICE_NAME = "request-generator"
      LOG_LEVEL               = "INFO"
    }
  }

  depends_on = [aws_cloudwatch_log_group.this]
}

resource "aws_scheduler_schedule" "generator" {
  name = "${var.name_prefix}-generator-schedule"

  schedule_expression = "rate(3 minutes)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.this.arn
    role_arn = var.scheduler_role_arn
    input    = "{}"
  }
}
