# --- ECSタスク実行ロール ---
# ECSエージェントがタスクを起動するために使用 (ECRプル・CWLogs・SSM取得)
resource "aws_iam_role" "ecs_exec" {
  # IAMロール名は64文字以内のAWSハード制限に注意
  name = "${var.project}-ecs-exec-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_exec_managed" {
  role       = aws_iam_role.ecs_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "ecs_exec_ssm" {
  name = "ssm-parameter-read"
  role = aws_iam_role.ecs_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["ssm:GetParameters", "ssm:GetParameter", "ssm:GetParametersByPath"]
      # /deepdive/ パス配下のパラメータのみ許可 (最小権限)
      Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/deepdive/*"
    }]
  })
}

# --- ECSタスクロール ---
# タスク内のアプリケーションコードが使用 (SQS操作・ECS Exec)
resource "aws_iam_role" "ecs_task" {
  name = "${var.project}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ecs_task_sqs" {
  name = "sqs-job-queue"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:SendMessage",
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl",
      ]
      # job-queueのARNのみに限定 (DLQへの直接アクセスは不要)
      Resource = aws_sqs_queue.job.arn
    }]
  })
}

resource "aws_iam_role_policy" "ecs_task_exec_ssm" {
  name = "ecs-exec-ssm-session"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        # ECS Exec (SSM Session Manager経由のシェルアクセス) に必要な最小権限
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
      ]
      Resource = "*"
    }]
  })
}

# --- EKSノードロール ---
# Karpenterが起動するノードのインスタンスプロファイルとして使用
resource "aws_iam_role" "eks_node" {
  name = "${var.project}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_node_worker" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_node_ecr" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "eks_node_cni" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# KarpenterがEC2インスタンスにロールを付与するためのインスタンスプロファイル
resource "aws_iam_instance_profile" "eks_node" {
  name = "${var.project}-eks-node-profile"
  role = aws_iam_role.eks_node.name
}

output "ecs_exec_role_arn" {
  value = aws_iam_role.ecs_exec.arn
}

output "ecs_task_role_arn" {
  value = aws_iam_role.ecs_task.arn
}

output "eks_node_role_arn" {
  value = aws_iam_role.eks_node.arn
}

output "eks_node_instance_profile_arn" {
  value = aws_iam_instance_profile.eks_node.arn
}

output "eks_node_instance_profile_name" {
  value = aws_iam_instance_profile.eks_node.name
}
