resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${var.name_prefix}-receiver"
  retention_in_days = 7
}

resource "aws_lambda_function" "this" {
  function_name    = "${var.name_prefix}-receiver"
  runtime          = "python3.12"
  handler          = "receiver.lambda_handler"
  architectures    = ["arm64"]
  timeout          = 30
  memory_size      = 256
  role             = var.receiver_role_arn
  filename         = "${path.module}/receiver.zip"
  source_code_hash = filebase64sha256("${path.module}/receiver.zip")

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
