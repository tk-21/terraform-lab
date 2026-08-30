data "archive_file" "triage_handler" {
  type        = "zip"
  source_dir  = "${path.module}/../../../lambda/triage_handler"
  output_path = "${path.module}/../../../lambda/triage_handler.zip"
}

resource "aws_lambda_function" "triage_handler" {
  function_name = "${var.project_name}-triage-handler-${var.environment}"
  role          = var.lambda_role_arn

  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.triage_handler.output_path
  source_code_hash = data.archive_file.triage_handler.output_base64sha256

  memory_size = 256
  timeout     = 30

  environment {
    variables = {
      DYNAMODB_TABLE_NAME = var.dynamodb_table_name
      S3_BUCKET_NAME      = var.s3_bucket_name
      SNS_TOPIC_ARN       = var.sns_topic_arn
      BEDROCK_MODEL_ID    = var.bedrock_model_id
    }
  }

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
