# =============================================================
# Hub VPCでPrivateLinkサービスを公開する
# =============================================================

# 現在のAWSアカウントIDを動的に取得
data "aws_caller_identity" "current" {}

module "privatelink_service" {
  source = "../../modules/privatelink"

  prefix = "${local.prefix}-svc"

  vpc_id            = module.vpc.vpc_id
  service_subnet_id = module.vpc.subnet_ids["private-1a"]
  nlb_subnet_ids    = module.vpc.private_subnet_ids

  # Nginxへのアクセス元: NLBは自VPC CIDRから転送
  # NLBのヘルスチェックとSpokeからの透過転送を許可
  allowed_cidr_blocks = [
    "10.0.0.0/16", # Hub VPC（NLBからEC2へ）
    "10.1.0.0/16", # Spoke-Prod（NLBの透過転送でクライアントIPが見える場合）
    "10.2.0.0/16", # Spoke-Dev
  ]

  # 同一AWSアカウントからのConsumer Endpointを許可
  allowed_principals = [
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
  ]

  tags = local.common_tags
}
