locals {
  common_tags = {
    Project   = "mail-infra-handson"
    ManagedBy = "terraform"
  }
}

# ============================================================
# DNS基盤（Route 53 Hosted Zone + MX / SPF / DMARC）
# ============================================================

module "dns" {
  source = "./modules/dns"

  domain_name  = var.domain_name
  aws_region   = var.aws_region
  spf_policy   = var.spf_policy
  dmarc_policy = var.dmarc_policy
  dmarc_pct    = var.dmarc_pct
  tags         = local.common_tags
}

# ============================================================
# SES Email Identity（ドメイン検証 + DKIM）
# ============================================================

module "ses_identity" {
  source = "./modules/ses-identity"

  domain_name    = var.domain_name
  hosted_zone_id = module.dns.hosted_zone_id
  tags           = local.common_tags
}

# ============================================================
# バウンス・苦情パイプライン（SNS + DynamoDB + Lambda）
# ============================================================

module "bounce_pipeline" {
  source = "./modules/bounce-pipeline"

  aws_region               = var.aws_region
  powertools_layer_version = var.powertools_layer_version
  tags                     = local.common_tags
}

# ============================================================
# SES Configuration Set（メトリクス収集 + イベント転送）
# ============================================================

module "ses_config" {
  source = "./modules/ses-config"

  ses_identity_name       = var.domain_name
  bounce_sns_topic_arn    = module.bounce_pipeline.bounce_sns_topic_arn
  complaint_sns_topic_arn = module.bounce_pipeline.complaint_sns_topic_arn
  tags                    = local.common_tags
}

# ============================================================
# 受信パイプライン（S3 + Receipt Rules + spam Lambda）
# ============================================================

module "inbound_pipeline" {
  source = "./modules/inbound-pipeline"

  aws_region               = var.aws_region
  domain_name              = var.domain_name
  suppression_table_name   = module.bounce_pipeline.suppression_table_name
  suppression_table_arn    = module.bounce_pipeline.suppression_table_arn
  powertools_layer_version = var.powertools_layer_version
  tags                     = local.common_tags
}

# ============================================================
# サプレッションリスト同期（Lambda + EventBridge）
# ============================================================

module "suppression_sync" {
  source = "./modules/suppression-sync"

  aws_region               = var.aws_region
  suppression_table_name   = module.bounce_pipeline.suppression_table_name
  suppression_table_arn    = module.bounce_pipeline.suppression_table_arn
  powertools_layer_version = var.powertools_layer_version
  tags                     = local.common_tags
}

# ============================================================
# 監視（CloudWatch Dashboard + Alarm + SNS）
# ============================================================

module "monitoring" {
  source = "./modules/monitoring"

  admin_email                  = var.admin_email
  bounce_handler_function_name = module.bounce_pipeline.bounce_handler_function_name
  spam_handler_function_name   = module.inbound_pipeline.spam_handler_function_name
  tags                         = local.common_tags
}

# ============================================================
# VPC Endpoint（SES SMTP PrivateLink）
# ============================================================

module "vpc_endpoint" {
  source = "./modules/vpc-endpoint"

  aws_region       = var.aws_region
  ec2_iam_role_arn = var.ec2_iam_role_arn
  tags             = local.common_tags
}
