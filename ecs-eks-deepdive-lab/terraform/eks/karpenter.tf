# --- Karpenter Spot 割り込み通知用 SQS キュー ---
# Spot 割り込み通知を受け取り、Karpenter がノードを安全に退避させる
resource "aws_sqs_queue" "karpenter_interrupt" {
  name                      = "deepdive-karpenter-interrupt"
  message_retention_seconds = 300

  tags = { Name = "deepdive-karpenter-interrupt" }
}

# キューポリシー: EventBridge からのメッセージ送信を許可
resource "aws_sqs_queue_policy" "karpenter_interrupt" {
  queue_url = aws_sqs_queue.karpenter_interrupt.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.karpenter_interrupt.arn
    }]
  })
}

# --- EventBridge ルール: EC2 Spot 割り込み通知 → SQS ---
resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "deepdive-karpenter-spot-interruption"
  description = "EC2 Spot Instance 割り込み警告を Karpenter の SQS キューに転送"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule = aws_cloudwatch_event_rule.spot_interruption.name
  arn  = aws_sqs_queue.karpenter_interrupt.arn
}

# ノード終了通知も転送（インスタンス状態変化）
resource "aws_cloudwatch_event_rule" "instance_state" {
  name        = "deepdive-karpenter-instance-state"
  description = "EC2 インスタンス状態変化を Karpenter に通知"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
  })
}

resource "aws_cloudwatch_event_target" "instance_state" {
  rule = aws_cloudwatch_event_rule.instance_state.name
  arn  = aws_sqs_queue.karpenter_interrupt.arn
}

# --- Karpenter Controller IAM Role ---
resource "aws_iam_role" "karpenter_controller" {
  # IAMロール名は64文字以内のAWSハード制限: "deepdive-karpenter-ctrl" = 23文字
  name = "deepdive-karpenter-ctrl"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      # Pod Identity は OIDC IRSA と異なり OIDC Provider 設定が不要
      # EKS Pod Identity Agent アドオンが認証を仲介する新方式（2023 年〜）
      Action = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "karpenter_controller" {
  name = "karpenter-controller-policy"
  role = aws_iam_role.karpenter_controller.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2制御"
        Effect = "Allow"
        Action = [
          "ec2:CreateFleet",
          "ec2:CreateLaunchTemplate",
          "ec2:DeleteLaunchTemplate",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets",
          "ec2:RunInstances",
          "ec2:TerminateInstances",
          "ec2:CreateTags",
        ]
        Resource = "*"
      },
      {
        Sid    = "Spot割り込みキュー"
        Effect = "Allow"
        Action = [
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:ReceiveMessage",
        ]
        Resource = aws_sqs_queue.karpenter_interrupt.arn
      },
      {
        Sid    = "ノードInstanceProfile"
        Effect = "Allow"
        # Karpenter がノードに IAM ロールを付与するために必要
        Action   = ["iam:PassRole"]
        Resource = local.eks_node_role_arn
      },
      {
        Sid      = "EKSクラスター情報"
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = aws_eks_cluster.main.arn
      },
    ]
  })
}

# --- Karpenter Pod Identity Association ---
# karpenter namespace の karpenter ServiceAccount の Pod が
# karpenter_controller IAM Role を自動的に取得できる
# OIDC IRSA と違い ServiceAccount の annotation は不要
resource "aws_eks_pod_identity_association" "karpenter" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "karpenter"
  service_account = "karpenter"
  role_arn        = aws_iam_role.karpenter_controller.arn
}

# --- Outputs ---
output "karpenter_role_arn" {
  value = aws_iam_role.karpenter_controller.arn
}

output "interruption_queue_url" {
  value = aws_sqs_queue.karpenter_interrupt.url
}

output "interruption_queue_name" {
  value = aws_sqs_queue.karpenter_interrupt.name
}
