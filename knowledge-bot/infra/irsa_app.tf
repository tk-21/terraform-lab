data "aws_iam_policy_document" "app_bedrock" {
  statement {
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream"
    ]
    resources = ["*"]
  }

  # Knowledge Bases / Agent Runtime を使う場合（RetrieveAndGenerate等）
  statement {
    effect = "Allow"
    actions = [
      "bedrock:Retrieve",
      "bedrock:RetrieveAndGenerate"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "app_bedrock" {
  name   = "${local.name}-app-bedrock"
  policy = data.aws_iam_policy_document.app_bedrock.json
  tags   = local.tags
}

module "irsa_app" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${local.name}-app"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["knowledgebot:knowledgebot-sa"]
    }
  }

  role_policy_arns = { bedrock = aws_iam_policy.app_bedrock.arn }
  tags             = local.tags
}
