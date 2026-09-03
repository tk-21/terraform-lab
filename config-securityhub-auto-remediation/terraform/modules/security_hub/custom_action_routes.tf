# Custom Actionのイベントを各Lambda修復関数にルーティングする
#
# Custom Action クリック時のEventBridgeイベント形式:
# {
#   "source": "aws.securityhub",
#   "detail-type": "Security Hub Findings - Custom Action",
#   "resources": ["<custom_action_arn>"],    ← この ARN でアクションを識別する
#   "detail": { "findings": [...] }
# }
#
# detail-type だけでなく resources ARN でフィルタする理由:
# 4種のCustom Actionすべてが同一 detail-type を発行するため、
# resources ARN で区別しないと誤ったLambdaを起動してしまう。

# ── S3 Custom Action → Lambda ────────────────────────────────────────────────
resource "aws_cloudwatch_event_rule" "s3_custom_action" {
  name        = "csar-securityhub-custom-action-s3"
  description = "Security Hub Custom Action: S3修復トリガー"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Custom Action"]
    resources   = [aws_securityhub_action_target.s3_remediate.arn]
  })
}

resource "aws_cloudwatch_event_target" "s3_custom_action_lambda" {
  rule      = aws_cloudwatch_event_rule.s3_custom_action.name
  target_id = "csar-s3-custom-action-lambda"
  arn       = var.s3_remediation_lambda_arn

  dead_letter_config {
    arn = var.dlq_arn
  }
}

# ── IAM Custom Action → Lambda ───────────────────────────────────────────────
resource "aws_cloudwatch_event_rule" "iam_custom_action" {
  name        = "csar-securityhub-custom-action-iam"
  description = "Security Hub Custom Action: IAM修復トリガー"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Custom Action"]
    resources   = [aws_securityhub_action_target.iam_remediate.arn]
  })
}

resource "aws_cloudwatch_event_target" "iam_custom_action_lambda" {
  rule      = aws_cloudwatch_event_rule.iam_custom_action.name
  target_id = "csar-iam-custom-action-lambda"
  arn       = var.iam_remediation_lambda_arn

  dead_letter_config {
    arn = var.dlq_arn
  }
}

# ── SG Custom Action → Lambda ────────────────────────────────────────────────
resource "aws_cloudwatch_event_rule" "sg_custom_action" {
  name        = "csar-securityhub-custom-action-sg"
  description = "Security Hub Custom Action: SG修復トリガー"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Custom Action"]
    resources   = [aws_securityhub_action_target.sg_remediate.arn]
  })
}

resource "aws_cloudwatch_event_target" "sg_custom_action_lambda" {
  rule      = aws_cloudwatch_event_rule.sg_custom_action.name
  target_id = "csar-sg-custom-action-lambda"
  arn       = var.sg_remediation_lambda_arn

  dead_letter_config {
    arn = var.dlq_arn
  }
}

# ── RDS Custom Action → Lambda ───────────────────────────────────────────────
resource "aws_cloudwatch_event_rule" "rds_custom_action" {
  name        = "csar-securityhub-custom-action-rds"
  description = "Security Hub Custom Action: RDS修復通知トリガー"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Custom Action"]
    resources   = [aws_securityhub_action_target.rds_remediate.arn]
  })
}

resource "aws_cloudwatch_event_target" "rds_custom_action_lambda" {
  rule      = aws_cloudwatch_event_rule.rds_custom_action.name
  target_id = "csar-rds-custom-action-lambda"
  arn       = var.rds_remediation_lambda_arn

  dead_letter_config {
    arn = var.dlq_arn
  }
}
