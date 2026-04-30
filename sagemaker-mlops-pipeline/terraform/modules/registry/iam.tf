# 通知専用のため書き込み系SageMaker権限は一切付与しない
resource "aws_iam_role" "approval_notifier" {
  name = "${local.prefix}-approval-notifier-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "approval_notifier_execution" {
  role       = aws_iam_role.approval_notifier.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "approval_notifier_xray" {
  role       = aws_iam_role.approval_notifier.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_iam_role_policy" "approval_notifier_inline" {
  name = "${local.prefix}-approval-notifier-inline-policy"
  role = aws_iam_role.approval_notifier.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # SSMからChatwork認証情報を取得（読み取り専用）
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = "arn:aws:ssm:${local.region}:${local.account_id}:parameter/${local.prefix}/*"
      },
      {
        # 承認待ちモデルの情報参照（読み取り専用）
        Effect = "Allow"
        Action = [
          "sagemaker:DescribeModelPackage",
          "sagemaker:ListModelPackages"
        ]
        Resource = "*"
      }
    ]
  })
}
