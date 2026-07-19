module "origin" {
  source = "./modules/origin"

  project         = var.project
  env             = var.env
  vpc_cidr        = var.vpc_cidr
  container_image = var.container_image
  domain_name     = var.domain_name

  providers = {
    aws      = aws
    aws.use1 = aws.use1
  }
}

# WAF WebACL: CLOUDFRONT スコープは us-east-1 でのみ作成可能
module "waf" {
  source = "./modules/waf"

  providers = {
    aws = aws.use1
  }

  project = var.project
  env     = var.env
}

# SSM Parameter Store からシークレットを取得 (us-east-1 で参照)
# 事前に以下を手動で登録しておくこと:
#   aws ssm put-parameter --region us-east-1 \
#     --name "/wcsl/dev/cloudfront-secret" \
#     --value "<ランダム文字列>" --type SecureString
data "aws_ssm_parameter" "cloudfront_secret" {
  provider = aws.use1
  name     = "/${var.project}/${var.env}/cloudfront-secret"
}

# WAF ログ分析基盤: Kinesis Firehose → S3 → Athena
# Firehose は WAF WebACL と同じ us-east-1 に作成する必要がある
module "waf_logs" {
  source = "./modules/waf-logs"

  providers = {
    aws = aws.use1
  }

  project    = var.project
  env        = var.env
  webacl_arn = module.waf.webacl_arn
}

module "cloudfront" {
  source = "./modules/cloudfront"

  project                  = var.project
  env                      = var.env
  alb_dns_name             = module.origin.alb_dns_name
  webacl_arn               = module.waf.webacl_arn
  acm_certificate_arn_use1 = module.origin.acm_certificate_arn_use1
  cloudfront_secret        = data.aws_ssm_parameter.cloudfront_secret.value
  domain_name              = var.domain_name
}

# WAF ブロック数監視 + Chatwork 通知パイプライン
# CloudFront スコープの WAF メトリクスは us-east-1 にのみ存在するため
# CloudWatch Alarm・EventBridge・Lambda すべてを us-east-1 に配置する
module "alert" {
  source = "./modules/alert"

  providers = {
    aws = aws.use1
  }

  project          = var.project
  env              = var.env
  webacl_name      = module.waf.webacl_name
  chatwork_room_id = var.chatwork_room_id
}
