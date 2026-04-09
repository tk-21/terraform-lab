# OpenSearch Serverless 側の collection と、その前提になる各種ポリシーを定義する。
locals {
  aoss_collection_name = "${local.name}-kb"
}

# collection 作成前に必須となる暗号化ポリシー。
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

# ネットワーク到達条件を定義するポリシー。
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

    # provider の制約に合わせた設定値。実運用では公開範囲を別途見直す余地がある。
    AllowFromPublic = true
  }])
}

# collection / index にアクセスできる principal をここで制御する。
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
      # Terraform 実行者は index の初期作成・更新用。
      data.aws_caller_identity.current.arn,

      # Bedrock KB はこのロールでベクトルの書き込み・検索を行う。
      aws_iam_role.kb.arn
    ]
  }])
}

# 上記ポリシーがそろった後に、ベクトル検索用 collection を作成する。
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

# 後続 provider が参照する collection endpoint を local にまとめる。
locals {
  aoss_endpoint = aws_opensearchserverless_collection.kb.collection_endpoint
}
