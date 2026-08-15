locals {
  name_prefix = "${var.project}-${var.environment}"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# -----------------------------------------------------------------
# Action Handler Lambda パッケージング
# -----------------------------------------------------------------
data "archive_file" "action_handler" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/dist/action_handler.zip"
}

# -----------------------------------------------------------------
# CloudWatch Log Group for Action Handler Lambda
# -----------------------------------------------------------------
resource "aws_cloudwatch_log_group" "action_handler" {
  name              = "/aws/lambda/${local.name_prefix}-agent-action-handler"
  retention_in_days = 30

  tags = {
    Name = "${local.name_prefix}-agent-action-handler-logs"
  }
}

# -----------------------------------------------------------------
# IAM Role for Action Handler Lambda
# -----------------------------------------------------------------
resource "aws_iam_role" "action_handler" {
  name = "${local.name_prefix}-agent-action-handler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })

  tags = { Name = "${local.name_prefix}-agent-action-handler-role" }
}

resource "aws_iam_policy" "action_handler" {
  name = "${local.name_prefix}-agent-action-handler-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.action_handler.arn}:*"
      },
      {
        Sid      = "AllowXRay"
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      },
      {
        Sid      = "AllowUsageScan"
        Effect   = "Allow"
        Action   = ["dynamodb:Scan"]
        Resource = [var.usage_table_arn]
      }
    ]
  })

  tags = { Name = "${local.name_prefix}-agent-action-handler-policy" }
}

resource "aws_iam_role_policy_attachment" "action_handler" {
  role       = aws_iam_role.action_handler.name
  policy_arn = aws_iam_policy.action_handler.arn
}

# -----------------------------------------------------------------
# Action Handler Lambda
# -----------------------------------------------------------------
resource "aws_lambda_function" "action_handler" {
  function_name    = "${local.name_prefix}-agent-action-handler"
  description      = "Handles Bedrock Agent Action Group (infra-ops) requests"
  role             = aws_iam_role.action_handler.arn
  handler          = "index.lambda_handler"
  runtime          = "python3.12"
  memory_size      = var.lambda_memory_mb
  timeout          = 30
  filename         = data.archive_file.action_handler.output_path
  source_code_hash = data.archive_file.action_handler.output_base64sha256

  environment {
    variables = {
      USAGE_TABLE = var.usage_table_name
    }
  }

  tracing_config { mode = "Active" }

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.action_handler.name
  }

  tags = { Name = "${local.name_prefix}-agent-action-handler" }

  depends_on = [
    aws_iam_role_policy_attachment.action_handler,
    aws_cloudwatch_log_group.action_handler,
  ]
}

# Bedrock Agent が Action Handler Lambda を呼び出せる Permission
resource "aws_lambda_permission" "bedrock_agent" {
  count = var.enable_bedrock_agent ? 1 : 0

  statement_id  = "AllowBedrockAgentInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.action_handler.function_name
  principal     = "bedrock.amazonaws.com"
  source_arn    = "arn:aws:bedrock:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:agent/*"
}

# -----------------------------------------------------------------
# IAM Role for Bedrock Agent
# -----------------------------------------------------------------
resource "aws_iam_role" "bedrock_agent" {
  count = var.enable_bedrock_agent ? 1 : 0

  name = "${local.name_prefix}-bedrock-agent-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowBedrockAssume"
      Effect    = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnLike = {
          "aws:SourceArn" = "arn:aws:bedrock:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:agent/*"
        }
      }
    }]
  })

  tags = { Name = "${local.name_prefix}-bedrock-agent-role" }
}

resource "aws_iam_policy" "bedrock_agent" {
  count = var.enable_bedrock_agent ? 1 : 0

  name = "${local.name_prefix}-bedrock-agent-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowFoundationModel"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
        ]
        Resource = [var.agent_model_arn]
      },
      {
        Sid    = "AllowKnowledgeBaseRetrieve"
        Effect = "Allow"
        Action = ["bedrock:Retrieve"]
        Resource = [
          "arn:aws:bedrock:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:knowledge-base/${var.knowledge_base_id}"
        ]
      },
      {
        Sid    = "AllowGuardrail"
        Effect = "Allow"
        Action = ["bedrock:ApplyGuardrail"]
        Resource = [
          "arn:aws:bedrock:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:guardrail/${var.guardrail_id}"
        ]
      }
    ]
  })

  tags = { Name = "${local.name_prefix}-bedrock-agent-policy" }
}

resource "aws_iam_role_policy_attachment" "bedrock_agent" {
  count = var.enable_bedrock_agent ? 1 : 0

  role       = aws_iam_role.bedrock_agent[0].name
  policy_arn = aws_iam_policy.bedrock_agent[0].arn
}

# -----------------------------------------------------------------
# Bedrock Agent
# -----------------------------------------------------------------
resource "aws_bedrockagent_agent" "main" {
  count = var.enable_bedrock_agent ? 1 : 0

  agent_name                  = "${local.name_prefix}-agent"
  description                 = "Infrastructure operations AI agent with RAG and action groups"
  agent_resource_role_arn     = aws_iam_role.bedrock_agent[0].arn
  foundation_model            = var.agent_model_id
  idle_session_ttl_in_seconds = var.idle_session_ttl
  prepare_agent               = true

  instruction = <<-EOT
    あなたは AWS インフラ運用アシスタントです。
    以下の役割を担っています：

    1. インフラ状態確認: インフラコンポーネントの稼働状況を報告する
    2. コスト分析: 月次コストの概算と内訳を提供する
    3. ナレッジ検索: 登録されたドキュメントからインフラ情報を検索・回答する
    4. アラート管理: 発生したアラートの確認・管理を行う

    回答は日本語で行い、技術的な内容はわかりやすく説明してください。
    コスト情報は概算であることを必ず明示してください。
  EOT

  guardrail_configuration {
    guardrail_identifier = var.guardrail_id
    guardrail_version    = var.guardrail_version
  }

  tags = {
    Name = "${local.name_prefix}-bedrock-agent"
  }

  depends_on = [aws_iam_role_policy_attachment.bedrock_agent[0]]
}

# -----------------------------------------------------------------
# Action Group: infra-ops
# -----------------------------------------------------------------
resource "aws_bedrockagent_agent_action_group" "infra_ops" {
  count = var.enable_bedrock_agent ? 1 : 0

  agent_id          = aws_bedrockagent_agent.main[0].agent_id
  agent_version     = "DRAFT"
  action_group_name = "infra-ops"
  description       = "Infrastructure operations actions: status, costs, and alert management"

  action_group_executor {
    lambda = aws_lambda_function.action_handler.arn
  }

  api_schema {
    payload = file("${path.module}/schema/infra_ops.json")
  }
}

# -----------------------------------------------------------------
# Knowledge Base Association
# -----------------------------------------------------------------
resource "aws_bedrockagent_agent_knowledge_base_association" "main" {
  count = var.enable_bedrock_agent ? 1 : 0

  agent_id             = aws_bedrockagent_agent.main[0].agent_id
  agent_version        = "DRAFT"
  description          = "Infrastructure knowledge base for RAG-based Q&A"
  knowledge_base_id    = var.knowledge_base_id
  knowledge_base_state = "ENABLED"
}
