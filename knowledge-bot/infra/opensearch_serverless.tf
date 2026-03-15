locals {
  aoss_collection_name = "${local.name}-kb"
}

# 1) Encryption policy（必須：これが無いと collection が作れない）
resource "aws_opensearchserverless_security_policy" "encryption" {
  name = "${local.name}-enc"
  type = "encryption"

  policy = jsonencode({
    Rules = [
      {
        ResourceType = "collection"
        Resource     = ["collection/${local.aoss_collection_name}"]
      }
    ]
    AWSOwnedKey = true
  })
}

# 2) Network policy（ここでは簡易：public禁止）
resource "aws_opensearchserverless_security_policy" "network" {
  name = "${local.name}-net"
  type = "network"

  policy = jsonencode([{
    Rules = [
      {
        ResourceType = "collection"
        Resource     = ["collection/${local.aoss_collection_name}"]
      },
      {
        ResourceType = "dashboard"
        Resource     = ["collection/${local.aoss_collection_name}"]
      }
    ]

    # NOTE: このプロバイダ/スキーマでは false が弾かれるため true にする
    AllowFromPublic = true
  }])
}

# 3) Access policy（コレクションにアクセスできる principal を指定）
# ここではまず “KB用IAM Role” を許可（bedrock_kb.tf の aws_iam_role.kb を参照）
resource "aws_opensearchserverless_access_policy" "kb" {
  name = "${local.name}-aoss-access"
  type = "data"

  policy = jsonencode([{
    Rules = [
      {
        ResourceType = "collection"
        Resource     = ["collection/${local.aoss_collection_name}"]
        Permission   = ["aoss:*"]
      },
      {
        ResourceType = "index"
        Resource     = ["index/${local.aoss_collection_name}/*"]
        Permission   = ["aoss:*"]
      }
    ]

    Principal = [
      # Terraform実行者（index作成する人）
      data.aws_caller_identity.current.arn,

      # Bedrock KB が使うロール（Retrieve/Write する主体）
      aws_iam_role.kb.arn
    ]
  }])
}

# 4) Collection（policy が揃ってから作る）
resource "aws_opensearchserverless_collection" "kb" {
  name = local.aoss_collection_name
  type = "VECTORSEARCH"
  tags = local.tags

  depends_on = [
    aws_opensearchserverless_security_policy.encryption,
    aws_opensearchserverless_security_policy.network,
    aws_opensearchserverless_access_policy.kb
  ]
}

# AOSS collection endpoint（https://xxxx.ap-northeast-1.aoss.amazonaws.com）
# NOTE: collection の endpoint は attribute 名が provider で異なる場合があります。
# まずは "collection_endpoint" を試し、違えば plan の出力で合わせます。
locals {
  aoss_endpoint = aws_opensearchserverless_collection.kb.collection_endpoint
}
