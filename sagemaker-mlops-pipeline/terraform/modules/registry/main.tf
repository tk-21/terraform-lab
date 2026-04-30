# Lambdaコードをzipに圧縮してデプロイ
data "archive_file" "approval_notifier" {
  type        = "zip"
  source_file = "${path.root}/../lambda/approval_notifier/handler.py"
  output_path = "${path.module}/approval_notifier.zip"
}

# Model Registry承認通知Lambda関数
resource "aws_lambda_function" "approval_notifier" {
  function_name = "${local.prefix}-approval-notifier"
  role          = aws_iam_role.approval_notifier.arn
  runtime       = "python3.12"
  handler       = "handler.handler"
  architectures = ["arm64"]
  timeout       = 30

  filename         = data.archive_file.approval_notifier.output_path
  source_code_hash = data.archive_file.approval_notifier.output_base64sha256

  # AWS Lambda Powertoolsマネージドレイヤー（arm64）
  # バージョンは定期的に最新版に更新すること: https://docs.powertools.aws.dev/lambda/python/latest/#lambda-layer
  layers = [
    "arn:aws:lambda:${local.region}:017000801446:layer:AWSLambdaPowertoolsPythonV2-Arm64:${var.powertools_layer_version}"
  ]

  environment {
    variables = {
      POWERTOOLS_SERVICE_NAME = "approval-notifier"
      LOG_LEVEL               = "INFO"
    }
  }

  tags = local.common_tags
}

# Model RegistryのPendingApproval/Approved/Rejected変化をLambdaにルーティング
resource "aws_cloudwatch_event_rule" "model_approval" {
  name        = "${local.prefix}-model-approval"
  description = "Model RegistryのPendingApproval/Approved状態変化を検知"

  event_pattern = jsonencode({
    source      = ["aws.sagemaker"]
    detail-type = ["SageMaker Model Package State Change"]
    detail = {
      ModelPackageGroupName = ["${local.prefix}-model-group"]
      ModelPackageStatus    = ["PendingApproval", "Approved", "Rejected"]
    }
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "approval_notifier" {
  rule = aws_cloudwatch_event_rule.model_approval.name
  arn  = aws_lambda_function.approval_notifier.arn
}

resource "aws_lambda_permission" "eventbridge_approval" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.approval_notifier.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.model_approval.arn
}

# モデル承認時にCodePipelineで自動デプロイを起動
resource "aws_cloudwatch_event_rule" "model_approved" {
  name        = "${local.prefix}-model-approved"
  description = "モデル承認時にCodePipelineでデプロイを自動起動"

  event_pattern = jsonencode({
    source      = ["aws.sagemaker"]
    detail-type = ["SageMaker Model Package State Change"]
    detail = {
      ModelPackageGroupName = ["${local.prefix}-model-group"]
      ModelPackageStatus    = ["Approved"]
    }
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "deploy_pipeline" {
  rule     = aws_cloudwatch_event_rule.model_approved.name
  arn      = var.codepipeline_arn
  role_arn = var.eventbridge_codepipeline_role_arn
}
