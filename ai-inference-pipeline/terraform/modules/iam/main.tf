# ============================================================
# ECSタスク実行ロール
# ECRからイメージをPullし、CloudWatch Logsに書き込むために必要
# ============================================================
resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.name_prefix}-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ============================================================
# ECSタスクロール
# 前処理コンテナがS3の入力データを読み、結果をS3に書くために必要
# ============================================================
resource "aws_iam_role" "ecs_task" {
  name = "${var.name_prefix}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ecs_task_s3" {
  name = "s3-access"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # 入力ファイルの読み取り専用
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${var.input_bucket_arn}/*"
      },
      {
        # 前処理後データの書き込み
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${var.output_bucket_arn}/*"
      }
    ]
  })
}

# ============================================================
# Lambda実行ロール（Bedrock推論）
# Bedrockモデルの呼び出しとDynamoDB書き込みのみ許可
# ============================================================
resource "aws_iam_role" "lambda_bedrock" {
  name = "${var.name_prefix}-lambda-bedrock-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_bedrock_basic" {
  role       = aws_iam_role.lambda_bedrock.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda_bedrock_permissions" {
  name = "bedrock-dynamodb-s3"
  role = aws_iam_role.lambda_bedrock.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["bedrock:InvokeModel"]
        # haiku固定でコスト暴走を防止
        Resource = "arn:aws:bedrock:${var.region}::foundation-model/anthropic.claude-3-haiku-20240307-v1:0"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:GetItem"]
        Resource = var.dynamodb_table_arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${var.output_bucket_arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${var.region}:${var.account_id}:parameter/aip/*"
      }
    ]
  })
}

# ============================================================
# Lambda実行ロール（Chatwork通知）
# SSMからトークン取得のみ。Bedrockは触れない
# ============================================================
resource "aws_iam_role" "lambda_notify" {
  name = "${var.name_prefix}-lambda-notify-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_notify_basic" {
  role       = aws_iam_role.lambda_notify.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda_notify_ssm" {
  name = "ssm-chatwork-token"
  role = aws_iam_role.lambda_notify.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = "arn:aws:ssm:${var.region}:${var.account_id}:parameter/aip/*/chatwork/*"
    }]
  })
}

# ============================================================
# Step Functions実行ロール
# ECSタスク起動とLambda呼び出しのみに絞る
# ============================================================
resource "aws_iam_role" "sfn" {
  name = "${var.name_prefix}-sfn-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "sfn_permissions" {
  name = "sfn-ecs-lambda"
  role = aws_iam_role.sfn.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # RunTaskはタスク定義ARNで制限可能
        Effect   = "Allow"
        Action   = ["ecs:RunTask"]
        Resource = "arn:aws:ecs:${var.region}:${var.account_id}:task-definition/${var.name_prefix}-*"
      },
      {
        # StopTask/DescribeTasksはタスクARNで制限（動的に生成されるためクラスター配下に限定）
        Effect = "Allow"
        Action = [
          "ecs:StopTask",
          "ecs:DescribeTasks",
        ]
        Resource = "arn:aws:ecs:${var.region}:${var.account_id}:task/${var.name_prefix}-cluster/*"
      },
      {
        # ECSタスクにIAMロールを渡すための権限
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [
          aws_iam_role.ecs_task_execution.arn,
          aws_iam_role.ecs_task.arn,
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = var.lambda_arns
      },
      {
        # ECSタスクの完了をイベント駆動で待機するために必要
        Effect   = "Allow"
        Action   = ["events:PutTargets", "events:PutRule", "events:DescribeRule"]
        Resource = "arn:aws:events:${var.region}:${var.account_id}:rule/StepFunctionsGetEventsForECSTaskRule"
      },
      {
        # CloudWatch Logs Delivery操作はAWSの仕様上 Resource = "*" が必須
        # （ログ配信APIはリソースレベルの権限をサポートしていないため）
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:GetLogDelivery",
          "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries",
        ]
        Resource = "*"
      },
      {
        # ロググループ操作はプロジェクト固有のロググループに限定
        Effect = "Allow"
        Action = [
          "logs:PutLogEvents",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups",
        ]
        Resource = [
          "arn:aws:logs:${var.region}:${var.account_id}:log-group:/aip/*",
          "arn:aws:logs:${var.region}:${var.account_id}:log-group:/aip/*:*",
        ]
      }
    ]
  })
}

# ============================================================
# EventBridge実行ロール
# S3イベントを受け取りStep Functionsを起動するための最小権限
# ============================================================
resource "aws_iam_role" "eventbridge" {
  name = "${var.name_prefix}-eventbridge-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# sfn_arnはphase4でStep Functionsモジュール作成後に設定する
# 循環依存（IAM→SFN→IAM）を避けるためphase5で有効化
resource "aws_iam_role_policy" "eventbridge_sfn" {
  count = var.sfn_arn != "" ? 1 : 0
  name  = "start-sfn"
  role  = aws_iam_role.eventbridge.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["states:StartExecution"]
      Resource = var.sfn_arn
    }]
  })
}
