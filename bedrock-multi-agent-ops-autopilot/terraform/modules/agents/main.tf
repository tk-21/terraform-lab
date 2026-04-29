locals {
  openapi_root = "${path.root}/../agents"

  # Sub-agentモデル: コスト削減のためHaikuを使用
  sub_agent_model = "anthropic.claude-haiku-3-5-20241022-v1:0"
}

# ============================================================
# Bedrock Guardrails - 破壊的操作をDENY
# ============================================================

resource "aws_bedrock_guardrail" "ops_guardrail" {
  name        = "${var.prefix}-ops-guardrail"
  description = "運用エージェントの破壊的操作を制限するガードレール"

  blocked_input_messaging   = "この操作は安全上の理由から禁止されています。承認フローを通じて操作を依頼してください。"
  blocked_outputs_messaging = "この操作は安全上の理由から禁止されています。"

  topic_policy_config {
    topics_config {
      name       = "destructive-operations"
      definition = "EC2インスタンスの削除・終了、RDSインスタンスの削除、S3バケットの削除、IAMロールの削除・変更など、本番環境への破壊的操作"
      examples = [
        "delete instance",
        "terminate EC2",
        "drop database",
        "remove IAM role",
        "delete S3 bucket",
        "destroy infrastructure",
      ]
      type = "DENY"
    }
  }

  tags = var.common_tags
}

resource "aws_bedrock_guardrail_version" "ops_guardrail" {
  guardrail_arn = aws_bedrock_guardrail.ops_guardrail.guardrail_arn
  description   = "初期バージョン"
}

# ============================================================
# Sub-agent共通IAMロール
# ============================================================

resource "aws_iam_role" "sub_agent" {
  name = "${var.prefix}-sub-agent-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
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

resource "aws_iam_role_policy" "sub_agent_inline" {
  name = "${var.prefix}-sub-agent-inline"
  role = aws_iam_role.sub_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "BedrockInvokeHaiku"
        Effect   = "Allow"
        Action   = "bedrock:InvokeModel"
        Resource = "arn:aws:bedrock:ap-northeast-1::foundation-model/anthropic.claude-haiku-3-5-20241022-v1:0"
      },
      {
        Sid    = "InvokeLambdaActionGroups"
        Effect = "Allow"
        Action = "lambda:InvokeFunction"
        Resource = [
          var.incident_investigator_function_arn,
          var.cost_optimizer_function_arn,
          var.remediation_function_arn,
          var.reporter_function_arn,
        ]
      },
    ]
  })
}

# ============================================================
# Incident Investigator Agent
# ============================================================

resource "aws_bedrock_agent" "incident_investigator" {
  agent_name                  = "${var.prefix}-incident-investigator"
  description                 = "CloudWatch/X-Ray/Config を使ったAWS障害調査専門エージェント"
  agent_resource_role_arn     = aws_iam_role.sub_agent.arn
  foundation_model            = local.sub_agent_model
  instruction                 = file("${local.openapi_root}/incident_investigator/instruction.txt")
  idle_session_ttl_in_seconds = 600

  guardrail_configuration {
    guardrail_identifier = aws_bedrock_guardrail.ops_guardrail.guardrail_id
    guardrail_version    = aws_bedrock_guardrail_version.ops_guardrail.version
  }

  tags = var.common_tags
}

resource "aws_bedrock_agent_action_group" "incident_investigator" {
  agent_id          = aws_bedrock_agent.incident_investigator.agent_id
  agent_version     = "DRAFT"
  action_group_name = "incident-investigation-actions"
  description       = "CloudWatch/X-Ray/Config調査アクション"

  action_group_executor {
    lambda = var.incident_investigator_function_arn
  }

  api_schema {
    payload = file("${local.openapi_root}/incident_investigator/openapi.yaml")
  }
}

resource "aws_bedrock_agent_alias" "incident_investigator" {
  agent_id         = aws_bedrock_agent.incident_investigator.agent_id
  agent_alias_name = "live"
  description      = "本番エイリアス"

  tags = var.common_tags
}

# ============================================================
# Cost Optimizer Agent
# ============================================================

resource "aws_bedrock_agent" "cost_optimizer" {
  agent_name                  = "${var.prefix}-cost-optimizer"
  description                 = "AWSコスト異常検出・最適化推奨専門エージェント"
  agent_resource_role_arn     = aws_iam_role.sub_agent.arn
  foundation_model            = local.sub_agent_model
  instruction                 = file("${local.openapi_root}/cost_optimizer/instruction.txt")
  idle_session_ttl_in_seconds = 600

  guardrail_configuration {
    guardrail_identifier = aws_bedrock_guardrail.ops_guardrail.guardrail_id
    guardrail_version    = aws_bedrock_guardrail_version.ops_guardrail.version
  }

  tags = var.common_tags
}

resource "aws_bedrock_agent_action_group" "cost_optimizer" {
  agent_id          = aws_bedrock_agent.cost_optimizer.agent_id
  agent_version     = "DRAFT"
  action_group_name = "cost-optimization-actions"
  description       = "コスト異常検出・最適化推奨アクション"

  action_group_executor {
    lambda = var.cost_optimizer_function_arn
  }

  api_schema {
    payload = file("${local.openapi_root}/cost_optimizer/openapi.yaml")
  }
}

resource "aws_bedrock_agent_alias" "cost_optimizer" {
  agent_id         = aws_bedrock_agent.cost_optimizer.agent_id
  agent_alias_name = "live"
  description      = "本番エイリアス"

  tags = var.common_tags
}

# ============================================================
# Remediation Agent
# ============================================================

resource "aws_bedrock_agent" "remediation" {
  agent_name                  = "${var.prefix}-remediation"
  description                 = "承認フロー経由のAWS修復実行専門エージェント"
  agent_resource_role_arn     = aws_iam_role.sub_agent.arn
  foundation_model            = local.sub_agent_model
  instruction                 = file("${local.openapi_root}/remediation/instruction.txt")
  idle_session_ttl_in_seconds = 600

  guardrail_configuration {
    guardrail_identifier = aws_bedrock_guardrail.ops_guardrail.guardrail_id
    guardrail_version    = aws_bedrock_guardrail_version.ops_guardrail.version
  }

  tags = var.common_tags
}

resource "aws_bedrock_agent_action_group" "remediation" {
  agent_id          = aws_bedrock_agent.remediation.agent_id
  agent_version     = "DRAFT"
  action_group_name = "remediation-actions"
  description       = "承認済みSSMコマンド実行アクション"

  action_group_executor {
    lambda = var.remediation_function_arn
  }

  api_schema {
    payload = file("${local.openapi_root}/remediation/openapi.yaml")
  }
}

resource "aws_bedrock_agent_alias" "remediation" {
  agent_id         = aws_bedrock_agent.remediation.agent_id
  agent_alias_name = "live"
  description      = "本番エイリアス"

  tags = var.common_tags
}

# ============================================================
# Reporter Agent
# ============================================================

resource "aws_bedrock_agent" "reporter" {
  agent_name                  = "${var.prefix}-reporter"
  description                 = "HTMLレポート生成・Chatwork通知専門エージェント"
  agent_resource_role_arn     = aws_iam_role.sub_agent.arn
  foundation_model            = local.sub_agent_model
  instruction                 = file("${local.openapi_root}/reporter/instruction.txt")
  idle_session_ttl_in_seconds = 600

  guardrail_configuration {
    guardrail_identifier = aws_bedrock_guardrail.ops_guardrail.guardrail_id
    guardrail_version    = aws_bedrock_guardrail_version.ops_guardrail.version
  }

  tags = var.common_tags
}

resource "aws_bedrock_agent_action_group" "reporter" {
  agent_id          = aws_bedrock_agent.reporter.agent_id
  agent_version     = "DRAFT"
  action_group_name = "reporting-actions"
  description       = "HTMLレポート生成・Chatwork通知アクション"

  action_group_executor {
    lambda = var.reporter_function_arn
  }

  api_schema {
    payload = file("${local.openapi_root}/reporter/openapi.yaml")
  }
}

resource "aws_bedrock_agent_alias" "reporter" {
  agent_id         = aws_bedrock_agent.reporter.agent_id
  agent_alias_name = "live"
  description      = "本番エイリアス"

  tags = var.common_tags
}
