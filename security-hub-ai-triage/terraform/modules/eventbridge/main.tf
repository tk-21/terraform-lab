resource "aws_cloudwatch_event_rule" "security_hub_findings" {
  name        = "${var.project_name}-findings-rule-${var.environment}"
  description = "Security Hub Findings を Lambda に転送するルール"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Imported"]
    detail = {
      findings = {
        Severity = {
          Label = ["CRITICAL", "HIGH", "MEDIUM", "LOW"]
        }
      }
    }
  })

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_cloudwatch_event_target" "lambda" {
  rule      = aws_cloudwatch_event_rule.security_hub_findings.name
  target_id = "TriggerTriageLambda"
  arn       = var.lambda_function_arn
}

# Lambda に EventBridge からの呼び出しを許可するリソースベースポリシー
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.security_hub_findings.arn
}
