data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda"
  output_path = "${path.module}/lambda.zip"
}

# ロググループを先に作っておく（未作成だと初回実行前に logs tail が失敗し、destroy でも残る）
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/sg-auto-remediation"
  retention_in_days = 7
}

resource "aws_lambda_function" "remediation" {
  filename      = "lambda.zip"
  function_name = "sg-auto-remediation"
  role          = aws_iam_role.lambda_role.arn
  handler       = "handler.lambda_handler"
  runtime       = "python3.12"
  architectures = ["arm64"]
  timeout       = 30

  environment {
    variables = {
      SNS_TOPIC_ARN = aws_sns_topic.notify.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]

  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
}
