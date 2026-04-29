# Supervisor Agent本体
# SupervisorモードでSub-agent委譲を有効化し、Multi-Agent Collaborationを実現
resource "aws_bedrock_agent" "supervisor" {
  agent_name              = "${var.prefix}-supervisor"
  agent_resource_role_arn = var.supervisor_agent_role_arn
  foundation_model        = "anthropic.claude-3-7-sonnet-20250219-v1:0"
  instruction             = file("${path.module}/../../../agents/supervisor/instruction.txt")
  description             = "AWS運用タスクを自律的に判断しSub-agentに委譲するSupervisorエージェント"

  agent_collaboration = "SUPERVISOR"

  memory_configuration {
    enabled_memory_types = ["SESSION_SUMMARY"]
    storage_days         = 30
  }

  guardrail_configuration {
    guardrail_identifier = aws_bedrock_guardrail.ops_guardrail.guardrail_id
    guardrail_version    = aws_bedrock_guardrail_version.ops_guardrail.version
  }

  tags = var.common_tags
}

# Incident Investigator Sub-agent委譲設定
resource "aws_bedrock_agent_collaborator" "incident_investigator" {
  agent_id                  = aws_bedrock_agent.supervisor.agent_id
  agent_version             = "DRAFT"
  collaboration_instruction = "障害調査が必要な場合にこのエージェントに委譲する"
  collaborator_name         = "IncidentInvestigator"

  agent_descriptor {
    alias_arn = aws_bedrock_agent_alias.incident_investigator.agent_alias_arn
  }
}

# Cost Optimizer Sub-agent委譲設定
resource "aws_bedrock_agent_collaborator" "cost_optimizer" {
  agent_id                  = aws_bedrock_agent.supervisor.agent_id
  agent_version             = "DRAFT"
  collaboration_instruction = "コスト異常分析・最適化推奨が必要な場合にこのエージェントに委譲する"
  collaborator_name         = "CostOptimizer"

  agent_descriptor {
    alias_arn = aws_bedrock_agent_alias.cost_optimizer.agent_alias_arn
  }
}

# Remediation Sub-agent委譲設定
resource "aws_bedrock_agent_collaborator" "remediation" {
  agent_id                  = aws_bedrock_agent.supervisor.agent_id
  agent_version             = "DRAFT"
  collaboration_instruction = "承認済みの修復アクション実行が必要な場合にこのエージェントに委譲する"
  collaborator_name         = "Remediation"

  agent_descriptor {
    alias_arn = aws_bedrock_agent_alias.remediation.agent_alias_arn
  }
}

# Reporter Sub-agent委譲設定
resource "aws_bedrock_agent_collaborator" "reporter" {
  agent_id                  = aws_bedrock_agent.supervisor.agent_id
  agent_version             = "DRAFT"
  collaboration_instruction = "HTMLレポート生成・Chatwork通知が必要な場合にこのエージェントに委譲する"
  collaborator_name         = "Reporter"

  agent_descriptor {
    alias_arn = aws_bedrock_agent_alias.reporter.agent_alias_arn
  }
}

# Supervisor Agentエイリアス
resource "aws_bedrock_agent_alias" "supervisor" {
  agent_id         = aws_bedrock_agent.supervisor.agent_id
  agent_alias_name = "production"
  description      = "本番環境用Supervisorエイリアス"
  tags             = var.common_tags
}
