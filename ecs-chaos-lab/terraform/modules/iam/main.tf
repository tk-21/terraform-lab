locals {
  name_prefix = "${var.prefix}-${var.env}"
  # FIS ロール名: IAM 64文字制限に注意（prefix=ecl, env=dev → "ecl-fis-exec-role" = 16文字）
  fis_role_name = "${var.prefix}-fis-exec-role"
}

# ─────────────────────────────────────────────
# ECS Task 実行ロール
# ECS がコンテナ起動時に使用するロール（ECR pull / CW Logs 書き込み）
# ─────────────────────────────────────────────
resource "aws_iam_role" "task_execution" {
  name = "${var.prefix}-ecs-task-exec-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, {
    Name = "${var.prefix}-ecs-task-exec-role"
  })
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ─────────────────────────────────────────────
# ECS Task ロール
# コンテナアプリ自体が使用するロール（最小権限）
# ─────────────────────────────────────────────
resource "aws_iam_role" "task" {
  name = "${var.prefix}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, {
    Name = "${var.prefix}-ecs-task-role"
  })
}

resource "aws_iam_role_policy" "task_logs" {
  name = "${var.prefix}-ecs-task-logs"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/ecs/${local.name_prefix}:*"
    }]
  })
}

# ECS Exec（SSM セッションマネージャー経由のコンテナアクセス）を許可
# enable_execute_command = true で使用するデバッグ用権限
resource "aws_iam_role_policy" "task_exec_ssm" {
  name = "${var.prefix}-ecs-task-ssm"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel"
      ]
      Resource = "*"
    }]
  })
}

# ─────────────────────────────────────────────
# FIS 実行ロール
# 3シナリオ（Task Kill / Network Disruption / Desired Count 変更）を網羅する最小権限
# ─────────────────────────────────────────────
resource "aws_iam_role" "fis_execution" {
  name = local.fis_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "fis.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, {
    Name = local.fis_role_name
  })
}

resource "aws_iam_role_policy" "fis_execution" {
  name = "${var.prefix}-fis-exec-policy"
  role = aws_iam_role.fis_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # シナリオ1: Task 強制停止
        Sid    = "ECSTaskKill"
        Effect = "Allow"
        Action = [
          "ecs:StopTask",
          "ecs:DescribeTasks",
          "ecs:ListTasks"
        ]
        Resource = "*"
      },
      {
        # シナリオ2: ネットワーク遮断（Fargate は aws:ecs:task-network-blackhole-port を使用）
        # ENI レベルの NACL 操作が FIS 内部で行われる
        Sid    = "NetworkDisruption"
        Effect = "Allow"
        Action = [
          "ec2:DescribeNetworkInterfaces",
          "ec2:CreateNetworkAclEntry",
          "ec2:DeleteNetworkAclEntry",
          "ec2:DescribeNetworkAcls",
          "ec2:ReplaceNetworkAclEntry"
        ]
        Resource = "*"
      },
      {
        # シナリオ3: Lambda 経由で DesiredCount 変更
        # FIS ネイティブで ECS DesiredCount 変更は非対応のため Lambda を中継
        Sid      = "LambdaInvoke"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = "arn:aws:lambda:${var.aws_region}:${var.account_id}:function:${var.prefix}-*"
      },
      {
        # 停止条件の監視（CW アラーム / ALB ヘルスチェック）
        Sid    = "StopConditionMonitoring"
        Effect = "Allow"
        Action = [
          "cloudwatch:DescribeAlarms",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DescribeTargetGroups"
        ]
        Resource = "*"
      },
      {
        # FIS 実験ログの書き込み
        Sid    = "FISLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/aws/fis/*"
      }
    ]
  })
}
