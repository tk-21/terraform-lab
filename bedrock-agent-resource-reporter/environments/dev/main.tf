data "aws_caller_identity" "current" {}

# ─── KMS ──────────────────────────────────────────────────────────────────────

resource "aws_kms_key" "reports" {
  description             = "KMS key for Bedrock Agent reports S3 bucket"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = { Name = "bedrock-agent-reporter-kms" }
}

resource "aws_kms_alias" "reports" {
  name          = "alias/bedrock-agent-reporter"
  target_key_id = aws_kms_key.reports.key_id
}

# ─── S3 ───────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "reports" {
  bucket        = "bedrock-agent-reporter-reports-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = { Name = "bedrock-agent-reporter-reports" }
}

resource "aws_s3_bucket_versioning" "reports" {
  bucket = aws_s3_bucket.reports.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.reports.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id
  rule {
    id     = "expire-old-reports"
    status = "Enabled"
    filter { prefix = "reports/" }
    expiration { days = 90 }
    noncurrent_version_expiration { noncurrent_days = 30 }
  }
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket                  = aws_s3_bucket.reports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ─── SNS ──────────────────────────────────────────────────────────────────────

resource "aws_sns_topic" "notifications" {
  name = "bedrock-agent-reporter-notifications"
  tags = { Name = "bedrock-agent-reporter-notifications" }
}

# ─── Modules ──────────────────────────────────────────────────────────────────

module "networking" {
  source   = "../../modules/networking"
  vpc_cidr = var.vpc_cidr
  region   = var.region
}

module "lambda_actions" {
  source              = "../../modules/lambda-actions"
  region              = var.region
  reports_bucket_name = aws_s3_bucket.reports.id
  reports_bucket_arn  = aws_s3_bucket.reports.arn
  sns_topic_arn       = aws_sns_topic.notifications.arn
  kms_key_arn         = aws_kms_key.reports.arn
}

module "bedrock_agent" {
  source                   = "../../modules/bedrock-agent"
  bedrock_model_id         = var.bedrock_model_id
  aws_inspector_lambda_arn = module.lambda_actions.aws_inspector_lambda_arn
  report_writer_lambda_arn = module.lambda_actions.report_writer_lambda_arn
  notifier_lambda_arn      = module.lambda_actions.notifier_lambda_arn
}
