# 再学習パイプラインの起動権限のみ。Endpoint操作権限は付与しない（デプロイは承認フロー経由）
resource "aws_iam_role" "drift_handler" {
  name = "${local.prefix}-drift-handler-role"

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

resource "aws_iam_role_policy_attachment" "drift_handler_execution" {
  role       = aws_iam_role.drift_handler.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "drift_handler_xray" {
  role       = aws_iam_role.drift_handler.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_iam_role_policy" "drift_handler_inline" {
  name = "${local.prefix}-drift-handler-inline-policy"
  role = aws_iam_role.drift_handler.id

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
        # 再学習パイプラインの起動のみ許可。デプロイ権限は付与しない
        Effect = "Allow"
        Action = [
          "sagemaker:StartPipelineExecution",
          "sagemaker:DescribePipelineExecution"
        ]
        Resource = "arn:aws:sagemaker:${local.region}:${local.account_id}:pipeline/smp-training-pipeline"
      }
    ]
  })
}
