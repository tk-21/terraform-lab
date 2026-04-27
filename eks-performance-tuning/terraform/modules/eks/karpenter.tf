# ---------------------------------------------------------------
# Karpenter - locals
# ---------------------------------------------------------------
locals {
  karpenter_node_role_name = "karpenter-node-${var.cluster_name}"
  karpenter_queue_name     = "karpenter-interruption-${var.cluster_name}"
}

# ---------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------
data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

data "aws_iam_openid_connect_provider" "eks" {
  url = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------
# Node IAM role (for Karpenter-provisioned nodes)
# ---------------------------------------------------------------
resource "aws_iam_role" "karpenter_node" {
  name = local.karpenter_node_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "karpenter_node_worker" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_cni" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ecr" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ssm" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "karpenter_node" {
  name = local.karpenter_node_role_name
  role = aws_iam_role.karpenter_node.name
}

# ---------------------------------------------------------------
# EKS access for node role
# ---------------------------------------------------------------
resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.karpenter_node.arn
  type          = "EC2_LINUX"
}

resource "aws_eks_access_policy_association" "karpenter_node" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.karpenter_node.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSWorkerNodePolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.karpenter_node]
}

# ---------------------------------------------------------------
# Karpenter controller IRSA
# ---------------------------------------------------------------
resource "aws_iam_role" "karpenter_controller" {
  name = "karpenter-controller-${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = data.aws_iam_openid_connect_provider.eks.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(data.aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
            "${replace(data.aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:karpenter:karpenter"
          }
        }
      }
    ]
  })

  tags = var.common_tags
}

resource "aws_iam_policy" "karpenter_controller" {
  name = "karpenter-controller-${var.cluster_name}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "KarpenterEC2"
        Effect = "Allow"
        Action = [
          "ec2:CreateLaunchTemplate",
          "ec2:CreateFleet",
          "ec2:RunInstances",
          "ec2:CreateTags",
          "ec2:TerminateInstances",
          "ec2:DeleteLaunchTemplate",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeVpcs",
        ]
        Resource = "*"
      },
      {
        Sid    = "KarpenterIAMPassRole"
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = aws_iam_role.karpenter_node.arn
      },
      {
        Sid    = "KarpenterSQS"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
        ]
        Resource = aws_sqs_queue.karpenter.arn
      },
      {
        Sid      = "KarpenterEKS"
        Effect   = "Allow"
        Action   = "eks:DescribeCluster"
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_controller" {
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = aws_iam_policy.karpenter_controller.arn
}

# ---------------------------------------------------------------
# SQS queue for spot interruption handling
# ---------------------------------------------------------------
resource "aws_sqs_queue" "karpenter" {
  name                      = local.karpenter_queue_name
  message_retention_seconds = 300

  tags = var.common_tags
}

resource "aws_sqs_queue_policy" "karpenter" {
  queue_url = aws_sqs_queue.karpenter.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEventBridge"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.karpenter.arn
      }
    ]
  })
}

# ---------------------------------------------------------------
# EventBridge rules -> SQS
# ---------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "karpenter_spot_interruption" {
  name        = "karpenter-spot-interruption-${var.cluster_name}"
  description = "Karpenter spot interruption warning"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })

  tags = var.common_tags
}

resource "aws_cloudwatch_event_target" "karpenter_spot_interruption" {
  rule = aws_cloudwatch_event_rule.karpenter_spot_interruption.name
  arn  = aws_sqs_queue.karpenter.arn
}

resource "aws_cloudwatch_event_rule" "karpenter_instance_state_change" {
  name        = "karpenter-instance-state-${var.cluster_name}"
  description = "Karpenter instance state change notification"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
  })

  tags = var.common_tags
}

resource "aws_cloudwatch_event_target" "karpenter_instance_state_change" {
  rule = aws_cloudwatch_event_rule.karpenter_instance_state_change.name
  arn  = aws_sqs_queue.karpenter.arn
}

# ---------------------------------------------------------------
# Helm release
# ---------------------------------------------------------------
resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.karpenter_version
  namespace        = "karpenter"
  create_namespace = true

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.karpenter_controller.arn
  }

  set {
    name  = "settings.clusterName"
    value = var.cluster_name
  }

  set {
    name  = "settings.interruptionQueue"
    value = local.karpenter_queue_name
  }

  set {
    name  = "controller.nodeSelector.kubernetes\\.io/os"
    value = "linux"
  }

  depends_on = [
    aws_iam_role.karpenter_node,
    aws_iam_role_policy_attachment.karpenter_controller,
    aws_sqs_queue.karpenter,
  ]
}
