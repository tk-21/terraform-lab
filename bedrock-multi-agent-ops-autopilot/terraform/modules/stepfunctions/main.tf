# Supervisor Agent呼び出しのラッパー。実行履歴管理とタイムアウト・リトライ制御が責務

# ============================================================
# Step Functions用IAMロール
# ============================================================

resource "aws_iam_role" "sfn_orchestrator" {
  name = "${var.prefix}-sfn-orchestrator-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = var.account_id
        }
      }
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "sfn_orchestrator_inline" {
  name = "${var.prefix}-sfn-orchestrator-inline"
  role = aws_iam_role.sfn_orchestrator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BedrockInvokeAgent"
        Effect = "Allow"
        Action = "bedrock:InvokeAgent"
        Resource = "arn:aws:bedrock:ap-northeast-1:${var.account_id}:agent-alias/${var.supervisor_agent_id}/*"
      },
      {
        Sid    = "DynamoDBExecutionHistory"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:GetItem"
        ]
        Resource = var.execution_history_table_arn
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:PutLogEvents",
          "logs:GetLogDelivery",
          "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups"
        ]
        Resource = "*"
      }
    ]
  })
}

# ============================================================
# Step Functions ステートマシン
# ============================================================

resource "aws_sfn_state_machine" "ops_orchestrator" {
  name     = "${var.prefix}-ops-orchestrator"
  role_arn = aws_iam_role.sfn_orchestrator.arn
  type     = "STANDARD"

  definition = templatefile("${path.module}/../../../../stepfunctions/ops_orchestrator.asl.json", {
    execution_history_table   = var.execution_history_table_name
    supervisor_agent_id       = var.supervisor_agent_id
    supervisor_agent_alias_id = var.supervisor_agent_alias_id
  })

  logging_configuration {
    log_destination        = "${var.cloudwatch_log_group_arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  tracing_configuration {
    enabled = true
  }

  tags = var.common_tags
}

# ============================================================
# EventBridge → Step Functions用IAMロール
# EventBridgeがStep Functionsを起動するための最小権限ロール
# ============================================================

resource "aws_iam_role" "eventbridge_sfn" {
  name = "${var.prefix}-eventbridge-sfn-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = var.account_id
        }
      }
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "eventbridge_sfn_inline" {
  name = "${var.prefix}-eventbridge-sfn-inline"
  role = aws_iam_role.eventbridge_sfn.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "states:StartExecution"
      Resource = aws_sfn_state_machine.ops_orchestrator.arn
    }]
  })
}

# ============================================================
# EventBridgeルール: コスト異常検知
# ============================================================

resource "aws_cloudwatch_event_rule" "cost_anomaly" {
  name        = "${var.prefix}-cost-anomaly"
  description = "AWS Cost Anomaly Detectionの異常検知イベントをキャプチャ"

  event_pattern = jsonencode({
    source      = ["aws.ce"]
    detail-type = ["Cost Anomaly Detection Alert"]
  })

  tags = var.common_tags
}

resource "aws_cloudwatch_event_target" "cost_anomaly_to_sfn" {
  rule     = aws_cloudwatch_event_rule.cost_anomaly.name
  arn      = aws_sfn_state_machine.ops_orchestrator.arn
  role_arn = aws_iam_role.eventbridge_sfn.arn

  input_transformer {
    input_paths = {
      anomaly_id   = "$.detail.anomalyId"
      total_impact = "$.detail.impact.totalImpact"
    }
    input_template = <<-EOF
    {
      "event_type": "COST_ANOMALY",
      "event_detail": {
        "anomaly_id": "<anomaly_id>",
        "total_impact_usd": "<total_impact>"
      }
    }
    EOF
  }
}

# ============================================================
# EventBridgeルール: CloudWatchアラーム状態変化
# ============================================================

resource "aws_cloudwatch_event_rule" "cloudwatch_alarm" {
  name        = "${var.prefix}-cloudwatch-alarm"
  description = "CloudWatchアラームのALARM状態遷移をキャプチャ"

  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      state = {
        value = ["ALARM"]
      }
    }
  })

  tags = var.common_tags
}

resource "aws_cloudwatch_event_target" "cloudwatch_alarm_to_sfn" {
  rule     = aws_cloudwatch_event_rule.cloudwatch_alarm.name
  arn      = aws_sfn_state_machine.ops_orchestrator.arn
  role_arn = aws_iam_role.eventbridge_sfn.arn

  input_transformer {
    input_paths = {
      alarm_name = "$.detail.alarmName"
      state      = "$.detail.state.value"
      reason     = "$.detail.state.reason"
    }
    input_template = <<-EOF
    {
      "event_type": "CLOUDWATCH_ALARM",
      "event_detail": {
        "alarm_name": "<alarm_name>",
        "state": "<state>",
        "reason": "<reason>"
      }
    }
    EOF
  }
}
