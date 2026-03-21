# ============================================================
# modules/workflow
# Step Functions ステートマシン（FinOps レポート生成ワークフロー）
#
# 実行順序:
#   collector → anomaly-detector → ai-reporter → html-formatter → chatwork-notifier
# ============================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ============================================================
# IAM Role - Step Functions 実行ロール
# ============================================================

resource "aws_iam_role" "state_machine" {
  name = "${var.project_name}-workflow-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "states.${data.aws_region.current.name}.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        # SourceAccount 条件で Confused Deputy 問題を防止
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

# IAM Policy: 各 Lambda の InvokeFunction のみ許可
resource "aws_iam_role_policy" "state_machine_lambda" {
  name = "${var.project_name}-workflow-lambda-policy-${var.environment}"
  role = aws_iam_role.state_machine.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeLambdas"
        Effect = "Allow"
        Action = ["lambda:InvokeFunction"]
        Resource = [
          # ARN 直接指定 + :* でバージョン・エイリアス呼び出しにも対応
          var.collector_lambda_arn,
          var.anomaly_detector_lambda_arn,
          var.ai_reporter_lambda_arn,
          var.html_formatter_lambda_arn,
          var.chatwork_notifier_lambda_arn,
          "${var.collector_lambda_arn}:*",
          "${var.anomaly_detector_lambda_arn}:*",
          "${var.ai_reporter_lambda_arn}:*",
          "${var.html_formatter_lambda_arn}:*",
          "${var.chatwork_notifier_lambda_arn}:*",
        ]
      }
    ]
  })
}

# IAM Policy: CloudWatch Logs への実行ログ配信
# CloudWatch Logs Delivery 系の Action はリソース指定不可のため "*" が必要
resource "aws_iam_role_policy" "state_machine_logs" {
  name = "${var.project_name}-workflow-logs-policy-${var.environment}"
  role = aws_iam_role.state_machine.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogsDelivery"
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:GetLogDelivery",
          "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups",
        ]
        Resource = ["*"]
      }
    ]
  })
}

# IAM Policy: X-Ray トレーシング
resource "aws_iam_role_policy" "state_machine_xray" {
  name = "${var.project_name}-workflow-xray-policy-${var.environment}"
  role = aws_iam_role.state_machine.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "XRayTracing"
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "xray:GetSamplingRules",
          "xray:GetSamplingTargets",
        ]
        Resource = ["*"]
      }
    ]
  })
}

# ============================================================
# CloudWatch Logs Group
# ============================================================

resource "aws_cloudwatch_log_group" "state_machine" {
  name              = "/aws/states/${var.project_name}-workflow-${var.environment}"
  retention_in_days = 30
}

# ============================================================
# Step Functions State Machine
# ============================================================

resource "aws_sfn_state_machine" "finops_workflow" {
  name     = "${var.project_name}-workflow-${var.environment}"
  role_arn = aws_iam_role.state_machine.arn

  # Standard Workflow: 実行履歴を最大1年保持（Express と異なり監査証跡として活用可能）
  type = "STANDARD"

  # ASL 定義は templatefile() で Lambda ARN を注入（definition.asl.json.tftpl）
  definition = templatefile("${path.module}/definition.asl.json.tftpl", {
    collector_lambda_arn         = var.collector_lambda_arn
    anomaly_detector_lambda_arn  = var.anomaly_detector_lambda_arn
    ai_reporter_lambda_arn       = var.ai_reporter_lambda_arn
    html_formatter_lambda_arn    = var.html_formatter_lambda_arn
    chatwork_notifier_lambda_arn = var.chatwork_notifier_lambda_arn
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.state_machine.arn}:*"
    include_execution_data = true
    level                  = var.log_level
  }

  tracing_configuration {
    enabled = true
  }

  depends_on = [
    aws_cloudwatch_log_group.state_machine,
    aws_iam_role_policy.state_machine_logs,
  ]
}
