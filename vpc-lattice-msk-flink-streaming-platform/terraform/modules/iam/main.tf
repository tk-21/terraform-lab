# -------------------------------------------------------
# Flink execution role
# -------------------------------------------------------
resource "aws_iam_role" "flink" {
  name = "${var.name_prefix}-flink-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "kinesisanalytics.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "flink" {
  name = "flink-policy"
  role = aws_iam_role.flink.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "MSKRead"
        Effect = "Allow"
        Action = [
          "kafka-cluster:Connect",
          "kafka-cluster:AlterCluster",
          "kafka-cluster:DescribeCluster",
          "kafka-cluster:ReadData",
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:CreateTopic",
          "kafka:DescribeCluster",
          "kafka:GetBootstrapBrokers"
        ]
        Resource = [
          "arn:aws:kafka:${var.aws_region}:${var.aws_account_id}:cluster/*",
          "arn:aws:kafka:${var.aws_region}:${var.aws_account_id}:topic/*"
        ]
      },
      {
        Sid    = "S3Write"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:DeleteObject"
        ]
        Resource = [
          var.flink_app_bucket_arn,
          "${var.flink_app_bucket_arn}/*",
          var.output_bucket_arn,
          "${var.output_bucket_arn}/*"
        ]
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/kinesis-analytics/*"
      },
      {
        # FlinkのVPC内実行にはENI作成権限が必要
        Sid    = "VpcEni"
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeVpcs"
        ]
        Resource = "*"
      }
    ]
  })
}

# -------------------------------------------------------
# Lambda Producer execution role
# -------------------------------------------------------
resource "aws_iam_role" "producer" {
  name = "${var.name_prefix}-producer-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "producer" {
  name = "producer-policy"
  role = aws_iam_role.producer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Lambda ProducerはMSK書き込みのみ許可。読み込み権限は付与しない（最小権限）
        Sid    = "MSKWrite"
        Effect = "Allow"
        Action = [
          "kafka-cluster:Connect",
          "kafka-cluster:AlterCluster",
          "kafka-cluster:DescribeCluster",
          "kafka-cluster:WriteData",
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:CreateTopic",
          "kafka:DescribeCluster",
          "kafka:GetBootstrapBrokers"
        ]
        Resource = [
          "arn:aws:kafka:${var.aws_region}:${var.aws_account_id}:cluster/*",
          "arn:aws:kafka:${var.aws_region}:${var.aws_account_id}:topic/*"
        ]
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/lambda/*"
      },
      {
        Sid    = "VpcEni"
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface"
        ]
        Resource = "*"
      }
    ]
  })
}

# -------------------------------------------------------
# GitHub Actions OIDC provider
# GitHub ActionsはOIDCで一時クレデンシャルを取得。アクセスキー不使用
# -------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
  tags            = var.tags
}

resource "aws_iam_role" "github_actions" {
  name = "${var.name_prefix}-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github_actions.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:*"
          }
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "github_actions" {
  name = "github-actions-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TerraformStateBucket"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::*terraform*",
          "arn:aws:s3:::*terraform*/*"
        ]
      },
      {
        Sid    = "TerraformPlanApply"
        Effect = "Allow"
        Action = [
          "ec2:Describe*",
          "vpc-lattice:*",
          "kafka:*",
          "kinesisanalytics:*",
          "lambda:*",
          "s3:*",
          "iam:GetRole",
          "iam:GetRolePolicy",
          "iam:ListRolePolicies",
          "iam:PassRole",
          "logs:*"
        ]
        Resource = "*"
      }
    ]
  })
}
