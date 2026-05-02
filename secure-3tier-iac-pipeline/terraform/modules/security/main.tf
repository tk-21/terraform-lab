data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  common_tags              = merge(var.common_tags, { Module = "security" })
  session_logs_bucket_name = "s3t-prod-session-logs-${data.aws_caller_identity.current.account_id}"
}

# ---------------------------------------------------------------------------
# S3 バケット — Session Manager セッションログ保存先
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "session_logs" {
  bucket = local.session_logs_bucket_name

  tags = merge(local.common_tags, {
    Name    = local.session_logs_bucket_name
    Purpose = "ssm-session-logs"
  })
}

resource "aws_s3_bucket_versioning" "session_logs" {
  bucket = aws_s3_bucket.session_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "session_logs" {
  bucket = aws_s3_bucket.session_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "session_logs" {
  bucket                  = aws_s3_bucket.session_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# [コスト] ログのコスト削減: 90日で Glacier、365日で削除
resource "aws_s3_bucket_lifecycle_configuration" "session_logs" {
  bucket = aws_s3_bucket.session_logs.id

  rule {
    id     = "session-log-tiering"
    status = "Enabled"

    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }

    expiration {
      days = 365
    }
  }
}

resource "aws_s3_bucket_policy" "session_logs" {
  bucket = aws_s3_bucket.session_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # [セキュリティ] SSM がセッションログを書き込むための権限
        Sid    = "AllowSSMPutObject"
        Effect = "Allow"
        Principal = {
          Service = "ssm.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.session_logs.arn}/sessions/*"
        Condition = {
          Bool = {
            "aws:SecureTransport" = "true"
          }
        }
      },
      {
        # [セキュリティ] SSL/TLS 必須。平文 HTTP での S3 アクセスを全拒否
        Sid    = "DenyNonSSL"
        Effect = "Deny"
        Principal = "*"
        Action   = "s3:*"
        Resource = [
          aws_s3_bucket.session_logs.arn,
          "${aws_s3_bucket.session_logs.arn}/*",
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# IAM ロール — EC2 インスタンス用
# ---------------------------------------------------------------------------
resource "aws_iam_role" "ec2" {
  name = "s3t-prod-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEC2AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "s3t-prod-ec2-role"
  })
}

# [セキュリティ] SSMコアは AmazonSSMManagedInstanceCore マネージドポリシーで最小限の権限を確保
resource "aws_iam_role_policy_attachment" "ssm_managed_core" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# [セキュリティ] SSM:* は与えない。Session Manager動作に必要なアクションのみ明示的に許可
resource "aws_iam_role_policy" "ssm_session_manager" {
  name = "ssm-session-manager"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSSMSessionManager"
        Effect = "Allow"
        Action = [
          "ssm:UpdateInstanceInformation",
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel",
          "s3:GetEncryptionConfiguration"
        ]
        Resource = "*"
      }
    ]
  })
}

# [セキュリティ] GetSecretValue のみ許可。RotateSecret 等の管理操作は不可
resource "aws_iam_role_policy" "secrets_manager" {
  name = "secrets-manager-rds"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRDSSecretGet"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${var.rds_secret_arn_prefix}"
      }
    ]
  })
}

# [設計意図] AmazonCloudWatchFullAccess は使わず必要なアクションのみ許可
resource "aws_iam_role_policy" "cloudwatch_agent" {
  name = "cloudwatch-agent"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudWatchAgentMetrics"
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"
      }
    ]
  })
}

# [セキュリティ] Decrypt と GenerateDataKey のみ許可。KMS CMK ARN で Resource を限定
resource "aws_iam_role_policy" "kms" {
  name = "kms-cmk-decrypt"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCMKDecryptAndGenerateDataKey"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = var.kms_key_arn
      }
    ]
  })
}

# [セキュリティ] セッションログの PutObject のみ。特定パスに限定
resource "aws_iam_role_policy" "s3_session_logs" {
  name = "s3-session-logs"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSessionLogsPutObject"
        Effect = "Allow"
        Action = [
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.session_logs.arn}/sessions/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "s3t-prod-ec2-profile"
  role = aws_iam_role.ec2.name

  tags = merge(local.common_tags, {
    Name = "s3t-prod-ec2-profile"
  })
}

# ---------------------------------------------------------------------------
# セキュリティグループ
# ---------------------------------------------------------------------------

# 1. ALB セキュリティグループ
resource "aws_security_group" "alb" {
  name        = "s3t-prod-alb-sg"
  description = "Security group for Application Load Balancer"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, {
    Name = "s3t-prod-alb-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from internet"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https_ipv6" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from internet (IPv6)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv6         = "::/0"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP for HTTPS redirect"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http_ipv6" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP for HTTPS redirect (IPv6)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv6         = "::/0"
}

# [設計意図] ALBからEC2へのトラフィックをポート8080のみに最小化
resource "aws_vpc_security_group_egress_rule" "alb_to_ec2" {
  security_group_id            = aws_security_group.alb.id
  description                  = "ALB to EC2 app port"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.ec2.id
}

# 2. EC2 セキュリティグループ
# [セキュリティ] SSHポート(22)は一切開放しない。SSM Session Manager を使用
resource "aws_security_group" "ec2" {
  name        = "s3t-prod-web-sg"
  description = "Security group for EC2 web instances — SSH not allowed, use SSM Session Manager"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, {
    Name = "s3t-prod-web-sg"
  })
}

# [セキュリティ] IPではなくSG参照で動的に対応
resource "aws_vpc_security_group_ingress_rule" "ec2_from_alb" {
  security_group_id            = aws_security_group.ec2.id
  description                  = "App traffic from ALB only"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "ec2_https_out" {
  security_group_id = aws_security_group.ec2.id
  description       = "HTTPS to AWS APIs (SSM, Secrets Manager, CloudWatch)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# [セキュリティ] RDSへのアクセスはSG参照で限定
resource "aws_vpc_security_group_egress_rule" "ec2_to_rds" {
  security_group_id            = aws_security_group.ec2.id
  description                  = "MySQL to RDS SG only"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = aws_security_group.rds.id
}

# 3. RDS セキュリティグループ
# [セキュリティ] DB層はインターネットから2段階隔離（NATなし + SG制限）
resource "aws_security_group" "rds" {
  name        = "s3t-prod-rds-sg"
  description = "Security group for RDS Aurora — accessible only from EC2 web SG"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, {
    Name = "s3t-prod-rds-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_ec2" {
  security_group_id            = aws_security_group.rds.id
  description                  = "MySQL from EC2 web instances only"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = aws_security_group.ec2.id
}
# [設計意図] RDS SGのアウトバウンドルールは設定しない
# ステートフルなので応答パケットは自動で通る
