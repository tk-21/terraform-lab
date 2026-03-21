resource "aws_bedrockagent_agent" "this" {
  agent_name              = "bedrock-agent-resource-reporter"
  agent_resource_role_arn = aws_iam_role.bedrock_agent.arn
  foundation_model        = var.bedrock_model_id
  instruction             = "あなたは AWS インフラの調査エージェントです。ユーザーの依頼に応じて、aws-inspector で情報を収集し、report-writer でレポートを生成・S3に保存し、notifier でSNS通知してください。複数のアクションを組み合わせて自律的にタスクを完了してください。"
  prepare_agent           = true
}

resource "aws_bedrockagent_agent_alias" "this" {
  agent_id         = aws_bedrockagent_agent.this.id
  agent_alias_name = "dev"

  depends_on = [
    aws_bedrockagent_agent_action_group.aws_inspector,
    aws_bedrockagent_agent_action_group.report_writer,
    aws_bedrockagent_agent_action_group.notifier,
  ]
}
