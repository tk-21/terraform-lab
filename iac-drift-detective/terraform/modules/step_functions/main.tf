# Step Functions State Machine定義
# drift-detector → bedrock-analyzer → pr-creator の3ステップをオーケストレーション

# ASL定義内のLambda ARNプレースホルダーを実際のARNに置換する
locals {
  asl_definition = templatefile(
    "${path.module}/../../../step_functions/drift_workflow.asl.json",
    {
      DriftDetectorFunctionArn    = var.drift_detector_function_arn
      BedrockAnalyzerFunctionArn  = var.bedrock_analyzer_function_arn
      PRCreatorFunctionArn        = var.pr_creator_function_arn
    }
  )
}

resource "aws_sfn_state_machine" "drift_detection" {
  name       = "DriftDetectionWorkflow"
  role_arn   = var.sfn_role_arn
  definition = local.asl_definition
  type       = "STANDARD"

  # ERRORレベルのログのみCloudWatch Logsに出力（コスト最適化）
  logging_configuration {
    log_destination        = "${var.log_group_arn}:*"
    include_execution_data = true
    level                  = "ERROR"
  }

  tags = merge(var.tags, { Name = "DriftDetectionWorkflow" })
}
