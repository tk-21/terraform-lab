resource "aws_cloudwatch_log_group" "lambda_approval_notifier" {
  name              = "/aws/lambda/${var.prefix}-approval-notifier"
  retention_in_days = 14

  tags = var.common_tags
}

resource "aws_cloudwatch_log_group" "lambda_drift_handler" {
  name              = "/aws/lambda/${var.prefix}-drift-handler"
  retention_in_days = 14

  tags = var.common_tags
}

resource "aws_cloudwatch_log_group" "sagemaker_pipeline" {
  name              = "/aws/sagemaker/pipelines/${var.prefix}-training-pipeline"
  retention_in_days = 14

  tags = var.common_tags
}
