# Security Hub Finding生成イベントをキャッチする (Config Rule由来のみ)
# Config Rulesの非準拠は Security Hub 有効化後に自動的に Findings として取り込まれる
resource "aws_cloudwatch_event_rule" "securityhub_finding" {
  name        = "csar-securityhub-finding-from-config"
  description = "Security HubのConfig Rule由来FindingをCloudWatch Logsへ記録"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Imported"]
    detail = {
      findings = {
        ProductName = ["Config"] # Config由来のFindingのみ対象
        RecordState = ["ACTIVE"]
        Workflow    = { Status = ["NEW"] }
        Compliance  = { Status = ["FAILED"] }
      }
    }
  })
}

# Findings可視化用のCloudWatch Logsグループ
resource "aws_cloudwatch_log_group" "securityhub_findings" {
  name              = "/csar/securityhub/findings"
  retention_in_days = 90
}

# EventBridgeがCloudWatch Logsへ書き込むためのリソースポリシー
resource "aws_cloudwatch_log_resource_policy" "securityhub_findings" {
  policy_name = "csar-securityhub-findings-eventbridge"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = [
            "events.amazonaws.com",
            "delivery.logs.amazonaws.com"
          ]
        }
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.securityhub_findings.arn}:*"
      }
    ]
  })
}

resource "aws_cloudwatch_event_target" "securityhub_finding_logs" {
  rule      = aws_cloudwatch_event_rule.securityhub_finding.name
  target_id = "csar-finding-to-logs"
  arn       = aws_cloudwatch_log_group.securityhub_findings.arn
}
