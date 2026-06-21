# ──────────────────────────────────────────
# Task Execution Role
# ──────────────────────────────────────────
#
# 役割: ECSコントロールプレーン(AWS)がコンテナを起動する際に使用するロール
# - ECRからイメージをPullする
# - CloudWatch Logsにログを書き込む
# - SSM Parameter StoreからシークレットをFargateエージェントが取得する
#
# Task Roleと分離する理由:
# コンテナ内部のアプリケーション(Atlantis)が使う権限と、
# コンテナを起動するインフラ側が使う権限を分離することで最小権限を実現する。
# 混在させるとAtlantisプロセスがECRやSSMに直接アクセスできてしまい過剰権限になる。
# ──────────────────────────────────────────

resource "aws_iam_role" "task_execution" {
  # 64文字以内のAWSハード制限に対応
  name        = "atlantis-task-execution-role"
  description = "ECS Fargateがコンテナ起動時に使用するExecution Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ecs-tasks.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = local.common_tags
}

# ECSの標準実行権限 (ECRイメージPull、CloudWatch Logsへの書き込みを含む)
resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# SSM Parameter Storeからシークレットを取得する追加権限
# AtlantisのGitHubトークンとWebhookシークレットをFargateエージェントが取得するために必要
resource "aws_iam_role_policy" "task_execution_ssm" {
  name = "atlantis-execution-ssm-policy"
  role = aws_iam_role.task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameters",
          "ssm:GetParameter"
        ]
        # /atlantis/ プレフィックス配下のパラメータのみに限定
        Resource = "arn:aws:ssm:ap-northeast-1:${local.account_id}:parameter/atlantis/*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "arn:aws:kms:ap-northeast-1:${local.account_id}:key/*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "ssm.ap-northeast-1.amazonaws.com"
          }
        }
      }
    ]
  })
}

# ──────────────────────────────────────────
# Task Role (Atlantisが terraform plan/apply を実行する権限)
# ──────────────────────────────────────────
#
# 役割: コンテナ内部のAtlantisプロセスが使用するロール
# - Terraformがsample-infraのリソースを管理する権限
# - TerraformステートをS3で読み書きする権限
# - DynamoDBでステートロックを管理する権限
#
# wildcard禁止の理由:
# AtlantisはGitHub PRのコードを自動実行するため、
# 悪意あるPRによる意図しないリソース操作を防ぐために最小権限が必須
# ──────────────────────────────────────────

resource "aws_iam_role" "task_role" {
  name        = "atlantis-task-role"
  description = "AtlantisコンテナがTerraformを実行するためのTask Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ecs-tasks.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = local.common_tags
}

# Terraformステート操作権限 (S3)
# sample-infraのtfstateファイルを読み書きするために必要
resource "aws_iam_role_policy" "task_role_tfstate_s3" {
  name = "atlantis-task-tfstate-s3-policy"
  role = aws_iam_role.task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        # ステートバケット内のオブジェクトのみに限定 (バケット名はbootstrapで確定)
        Resource = "arn:aws:s3:::tfstate-pr-driven-iac-lab-${local.account_id}/sample-infra/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketVersioning"
        ]
        Resource = "arn:aws:s3:::tfstate-pr-driven-iac-lab-${local.account_id}"
      }
    ]
  })
}

# Terraformステートロック権限 (DynamoDB)
# 同時apply防止のためのロックをDynamoDBで管理する
resource "aws_iam_role_policy" "task_role_tfstate_dynamodb" {
  name = "atlantis-task-tfstate-dynamo-policy"
  role = aws_iam_role.task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
          "dynamodb:DescribeTable"
        ]
        Resource = "arn:aws:dynamodb:ap-northeast-1:${local.account_id}:table/tfstate-lock-pr-driven-iac-lab"
      }
    ]
  })
}

# sample-infra管理権限: S3バケット
# sample-infra/main.tfが管理するS3バケットのCRUDに必要
resource "aws_iam_role_policy" "task_role_sample_s3" {
  name = "atlantis-task-sample-s3-policy"
  role = aws_iam_role.task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:CreateBucket",
          "s3:DeleteBucket",
          "s3:GetBucketVersioning",
          "s3:PutBucketVersioning",
          "s3:GetBucketPublicAccessBlock",
          "s3:PutBucketPublicAccessBlock",
          "s3:GetBucketTagging",
          "s3:PutBucketTagging",
          "s3:DeleteBucketTagging",
          "s3:ListBucket",
          "s3:GetAccelerateConfiguration",
          "s3:GetBucketAcl",
          "s3:GetBucketCORS",
          "s3:GetBucketLogging",
          "s3:GetBucketObjectLockConfiguration",
          "s3:GetBucketPolicy",
          "s3:GetBucketPolicyStatus",
          "s3:GetBucketRequestPayment",
          "s3:GetBucketWebsite",
          "s3:GetEncryptionConfiguration",
          "s3:GetLifecycleConfiguration",
          "s3:GetReplicationConfiguration"
        ]
        # sample-infraのバケット名パターンに限定 (環境名は変数で制御)
        Resource = "arn:aws:s3:::sample-infra-*-${local.account_id}"
      }
    ]
  })
}

# sample-infra管理権限: IAMポリシー
# sample-infra/main.tfが管理するIAMポリシーのCRUDに必要
resource "aws_iam_role_policy" "task_role_sample_iam_policy" {
  name = "atlantis-task-sample-iam-policy-policy"
  role = aws_iam_role.task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "iam:CreatePolicy",
          "iam:DeletePolicy",
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:ListPolicyVersions",
          "iam:TagPolicy",
          "iam:UntagPolicy"
        ]
        # sample-infra-s3-reader-policy-* パターンのポリシーのみに限定
        Resource = "arn:aws:iam::${local.account_id}:policy/sample-infra-*"
      }
    ]
  })
}

# sample-infra管理権限: IAMロール
# sample-infra/main.tfが管理するIAMロールのCRUDに必要
resource "aws_iam_role_policy" "task_role_sample_iam_role" {
  name = "atlantis-task-sample-iam-role-policy"
  role = aws_iam_role.task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:ListAttachedRolePolicies",
          "iam:ListRolePolicies",
          "iam:PassRole"
        ]
        # sample-infra-s3-reader-* パターンのロールのみに限定
        Resource = "arn:aws:iam::${local.account_id}:role/sample-infra-*"
      }
    ]
  })
}
