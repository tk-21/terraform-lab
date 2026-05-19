# =============================================================
# Spoke-Prod VPC に VPC Endpointを配置
# EC2がNAT GW・インターネットなしにAWS APIを使えるようにする
# =============================================================

module "endpoints" {
  source = "../../modules/endpoint"

  prefix   = local.prefix
  vpc_id   = module.vpc.vpc_id
  vpc_cidr = module.vpc.vpc_cidr

  # Interface EndpointのENIをマルチAZで配置
  subnet_ids = module.vpc.private_subnet_ids

  # Gateway EndpointのルートはprivateサブネットのRTBに追加
  # route_table_ids outputはmap型のため values() でリスト化
  route_table_ids = values(module.vpc.route_table_ids)

  # ==========================================================
  # Gateway型: S3・DynamoDB
  # コストゼロ・ルートテーブルへの自動追加で動作
  # ==========================================================
  gateway_endpoints = {
    "s3" = {
      # S3アクセス制限ポリシー（本番では特定バケットARNに絞る）
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Effect    = "Allow"
          Principal = "*"
          Action    = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
          Resource  = "*"
        }]
      })
    }
    "dynamodb" = {
      policy = null # デフォルト（全許可）
    }
  }

  # ==========================================================
  # Interface型: SSM関連3サービス（Session Manager動作に必須）
  # - ssm: SSM APIエンドポイント（パラメータストア・セッション開始）
  # - ssmmessages: Session Managerのデータチャネル（WebSocket通信）
  # - ec2messages: Run Commandのメッセージング
  # この3つが揃わないとSession Managerが接続できない
  # ==========================================================
  interface_endpoints = toset([
    "ssm",
    "ssmmessages",
    "ec2messages",
  ])

  tags = local.common_tags
}
