data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda"
  output_path = "${path.module}/lambda.zip"
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
      CHATWORK_API_TOKEN = var.chatwork_api_token
      CHATWORK_ROOM_ID   = var.chatwork_room_id
    }
  }

  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
}
