# =============================================================================
# Step Functionsモジュール - ポストモーテム自動生成ワークフロー
# FIS実験完了後に CollectData → AnalyzeWithBedrock → FormatReport → Notify の
# 4ステップでポストモーテムを自動生成するStandard Workflowを定義する。
# =============================================================================

# ------------------------------------------------------------
# CloudWatch Logs ロググループ
# Step Functions実行ログをERRORレベルで保存する（デバッグ用）
# ------------------------------------------------------------
resource "aws_cloudwatch_log_group" "postmortem_workflow" {
  name              = "/aws/states/${var.project}-postmortem-workflow-${var.environment}"
  retention_in_days = 30

  tags = var.tags
}

# ------------------------------------------------------------
# Step Functions 実行IAMロール
# 4つのLambda関数のInvoke権限、CWLogs、X-Rayのみを付与する（最小権限）
# ------------------------------------------------------------
resource "aws_iam_role" "step_functions" {
  name = "${var.project}-step-functions-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "states.amazonaws.com" }
        Action    = "sts:AssumeRole"
        Condition = {
          # 同一アカウント・リージョンのStep Functionsのみ許可
          StringEquals = {
            "aws:SourceAccount" = var.aws_account_id
          }
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "step_functions" {
  name = "${var.project}-step-functions-policy-${var.environment}"
  role = aws_iam_role.step_functions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # ポストモーテムワークフローの4つのLambdaのみ起動を許可（最小権限）
        Sid    = "LambdaInvoke"
        Effect = "Allow"
        Action = ["lambda:InvokeFunction"]
        Resource = [
          var.data_collector_arn,
          var.bedrock_analyzer_arn,
          var.report_formatter_arn,
          var.notifier_arn,
        ]
      },
      {
        # Step Functions実行ログのCloudWatch Logs書き込み
        Sid    = "CloudWatchLogsWrite"
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:GetLogDelivery",
          "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutLogEvents",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups",
        ]
        Resource = "*"
      },
      {
        # X-Rayによる分散トレーシング（ワークフロー全体の実行時間計測）
        Sid    = "XRayTracing"
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "xray:GetSamplingRules",
          "xray:GetSamplingTargets",
        ]
        Resource = "*"
      }
    ]
  })
}

# ------------------------------------------------------------
# Step Functions ステートマシン
# ASLテンプレートファイルのLambda ARNをtemplatefileで置換する。
# Standard Workflowを使用（実行履歴が90日間保持され、デバッグに有用）
# ------------------------------------------------------------
resource "aws_sfn_state_machine" "postmortem" {
  name     = "${var.project}-postmortem-workflow-${var.environment}"
  role_arn = aws_iam_role.step_functions.arn
  type     = "STANDARD"

  # ASLのLambda ARN変数をtemplatefileで置換する
  definition = templatefile("${path.module}/postmortem_workflow.asl.json", {
    data_collector_arn   = var.data_collector_arn
    bedrock_analyzer_arn = var.bedrock_analyzer_arn
    report_formatter_arn = var.report_formatter_arn
    notifier_arn         = var.notifier_arn
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.postmortem_workflow.arn}:*"
    include_execution_data = true
    level                  = "ERROR"
  }

  tracing_configuration {
    enabled = true
  }

  depends_on = [aws_cloudwatch_log_group.postmortem_workflow]

  tags = var.tags
}
