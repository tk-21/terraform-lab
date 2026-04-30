# SageMaker PipelinesがProcessing/Training/Evaluationジョブを実行するための権限。
# ADR-002に従いAmazonSageMakerFullAccessを廃止し最小権限インラインポリシーに置き換え
resource "aws_iam_role" "pipeline" {
  name = "${var.prefix}-pipeline-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "sagemaker.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "pipeline_minimal" {
  name = "${var.prefix}-pipeline-minimal-policy"
  role = aws_iam_role.pipeline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Processing / Training / Evaluation / Model Registry ジョブ実行
      # SageMakerジョブ系は動的にARNが決まるため * を使用（タグ条件での絞り込みを推奨）
      {
        Effect = "Allow"
        Action = [
          "sagemaker:CreateProcessingJob",
          "sagemaker:DescribeProcessingJob",
          "sagemaker:StopProcessingJob",
          "sagemaker:CreateTrainingJob",
          "sagemaker:DescribeTrainingJob",
          "sagemaker:StopTrainingJob",
          "sagemaker:CreateModel",
          "sagemaker:DescribeModel",
          "sagemaker:CreateModelPackage",
          "sagemaker:DescribeModelPackage",
          "sagemaker:UpdateModelPackage",
          "sagemaker:ListModelPackages",
        ]
        Resource = "*"
      },
      # Pipeline実行（プロジェクトスコープのARNに絞り込み）
      {
        Effect = "Allow"
        Action = [
          "sagemaker:StartPipelineExecution",
          "sagemaker:DescribePipelineExecution",
          "sagemaker:ListPipelineExecutionSteps",
        ]
        Resource = "arn:aws:sagemaker:ap-northeast-1:*:pipeline/${var.prefix}-*"
      },
      # Model Monitor スケジュール作成
      {
        Effect = "Allow"
        Action = [
          "sagemaker:CreateDataQualityJobDefinition",
          "sagemaker:CreateModelQualityJobDefinition",
          "sagemaker:CreateMonitoringSchedule",
          "sagemaker:DescribeMonitoringSchedule",
        ]
        Resource = "*"
      },
      # S3: プロジェクト用バケットのみ
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::${var.prefix}-artifacts-*",
          "arn:aws:s3:::${var.prefix}-artifacts-*/*",
          "arn:aws:s3:::${var.prefix}-data-*",
          "arn:aws:s3:::${var.prefix}-data-*/*"
        ]
      },
      # ECR: GetAuthorizationTokenはアカウントレベルのため * 必須
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
        Resource = "arn:aws:ecr:ap-northeast-1:*:repository/${var.prefix}-*"
      },
      # CloudWatch Logs / Metrics
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
      }
    ]
  })
}

# 推論エンドポイントがモデルアーティファクトを読み込むための最小権限ロール
resource "aws_iam_role" "endpoint" {
  name = "${var.prefix}-endpoint-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "sagemaker.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "endpoint_inline" {
  name = "${var.prefix}-endpoint-inline-policy"
  role = aws_iam_role.endpoint.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = [
          "arn:aws:s3:::${var.prefix}-artifacts-*/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

# 全LambdaのベースロールChatwork通知に必要なSSMアクセスを付与
resource "aws_iam_role" "lambda_base" {
  name = "${var.prefix}-lambda-base-role"

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

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "lambda_base_execution" {
  role       = aws_iam_role.lambda_base.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_base_xray" {
  role       = aws_iam_role.lambda_base.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_iam_role_policy" "lambda_base_inline" {
  name = "${var.prefix}-lambda-base-inline-policy"
  role = aws_iam_role.lambda_base.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = "arn:aws:ssm:${var.region}:${var.account_id}:parameter/${var.prefix}/*"
      }
    ]
  })
}
