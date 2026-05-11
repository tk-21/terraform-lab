# =============================================================
# Karpenter モジュール
# Cell-A（AZ-a専用）・Cell-B（AZ-c専用）のNodePoolを作成する
#
# 設計判断:
# - EC2NodeClass: AWSリソース（AMI・サブネット・SG）の定義
# - NodePool: スケーリングポリシー・ラベル・Taintの定義
# - NodePoolをCell単位で分けることでAZ障害が対向Cellに波及しない
# =============================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}

# --- Karpenter コントローラー IAMロール（IRSA）---
# IRSAでNodeのIAMを借りずに直接EC2操作権限を取得する
resource "aws_iam_role" "karpenter_controller" {
  name = "${var.cluster_name}-karpenter-ctrl"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_issuer}:sub" = "system:serviceaccount:karpenter:karpenter"
          "${var.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "karpenter_controller" {
  name = "${var.cluster_name}-karpenter-policy"
  role = aws_iam_role.karpenter_controller.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateFleet",
          "ec2:CreateLaunchTemplate",
          "ec2:CreateTags",
          "ec2:DeleteLaunchTemplate",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstances",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets",
          "ec2:RunInstances",
          "ec2:TerminateInstances",
          "pricing:GetProducts",
          "ssm:GetParameter"
        ]
        Resource = "*"
      },
      # KarpenterがNodeに適用するIAMロールをPassできる権限
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = var.node_group_role_arn
      },
      # スポットインスタンスのService-Linked Role作成
      {
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = "arn:aws:iam::*:role/aws-service-role/spot.amazonaws.com/*"
        Condition = {
          StringLike = {
            "iam:AWSServiceName" = "spot.amazonaws.com"
          }
        }
      },
      # SQS割り込みキューの読み取り・削除
      {
        Effect = "Allow"
        Action = [
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          "sqs:ReceiveMessage"
        ]
        Resource = aws_sqs_queue.karpenter_interruption.arn
      },
      # EKS クラスター情報取得
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = "arn:aws:eks:${var.aws_region}:${var.aws_account_id}:cluster/${var.cluster_name}"
      }
    ]
  })
}

# --- Karpenter Helm Chart インストール ---
resource "helm_release" "karpenter" {
  name       = "karpenter"
  namespace  = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.0.0"

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
    name  = "settings.clusterEndpoint"
    value = var.cluster_endpoint
  }

  set {
    name  = "settings.interruptionQueue"
    value = aws_sqs_queue.karpenter_interruption.name
  }

  # システムノードに配置（Karpenter管理ノードには乗せない）
  set {
    name  = "nodeSelector.node\\.kubernetes\\.io/purpose"
    value = "system"
  }

  depends_on = [aws_iam_role_policy.karpenter_controller]
}

# --- SQS（EC2 Spot中断通知用）---
resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "${var.cluster_name}-karpenter-interruption"
  message_retention_seconds = 300 # 5分間保持

  tags = var.common_tags
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = ["events.amazonaws.com", "sqs.amazonaws.com"] }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.karpenter_interruption.arn
      }
    ]
  })
}

# EventBridgeルール（Spot中断・スケジュールチェンジ・再バランス推奨）
resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name = "${var.cluster_name}-spot-interruption"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })
  tags = var.common_tags
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule = aws_cloudwatch_event_rule.spot_interruption.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "instance_rebalance" {
  name = "${var.cluster_name}-instance-rebalance"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance Rebalance Recommendation"]
  })
  tags = var.common_tags
}

resource "aws_cloudwatch_event_target" "instance_rebalance" {
  rule = aws_cloudwatch_event_rule.instance_rebalance.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "scheduled_change" {
  name = "${var.cluster_name}-scheduled-change"
  event_pattern = jsonencode({
    source      = ["aws.health"]
    detail-type = ["AWS Health Event"]
  })
  tags = var.common_tags
}

resource "aws_cloudwatch_event_target" "scheduled_change" {
  rule = aws_cloudwatch_event_rule.scheduled_change.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

# --- EC2NodeClass: Cell-A（AZ-a 専用）---
resource "kubectl_manifest" "ec2nodeclass_cell_a" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: cell-a
    spec:
      # Graviton3 AL2 arm64 AMI を自動選択
      amiFamily: AL2
      amiSelectorTerms:
        - alias: al2@latest
      # AZ-a のサブネットのみ使用（Cell-A の核心設計）
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: "${var.cluster_name}"
            availability-zone: "ap-northeast-1a"
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: "${var.cluster_name}"
      role: "${var.node_group_role_name}"
      tags:
        Project: "${var.project_name}"
        Cell: "cell-a"
        chaos-target: "true"
        chaos-cell: "cell-a"
  YAML

  depends_on = [helm_release.karpenter]
}

# --- EC2NodeClass: Cell-B（AZ-c 専用）---
resource "kubectl_manifest" "ec2nodeclass_cell_b" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: cell-b
    spec:
      amiFamily: AL2
      amiSelectorTerms:
        - alias: al2@latest
      # AZ-c のサブネットのみ使用（Cell-B の核心設計）
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: "${var.cluster_name}"
            availability-zone: "ap-northeast-1c"
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: "${var.cluster_name}"
      role: "${var.node_group_role_name}"
      tags:
        Project: "${var.project_name}"
        Cell: "cell-b"
        chaos-target: "true"
        chaos-cell: "cell-b"
  YAML

  depends_on = [helm_release.karpenter]
}

# --- NodePool: Cell-A ---
resource "kubectl_manifest" "nodepool_cell_a" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: cell-a
    spec:
      template:
        metadata:
          labels:
            cell: cell-a
            topology.kubernetes.io/zone: ap-northeast-1a
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: cell-a
          requirements:
            # AZ-a に固定
            - key: topology.kubernetes.io/zone
              operator: In
              values: ["ap-northeast-1a"]
            # arm64（Graviton）優先・x86_64はフォールバック
            - key: kubernetes.io/arch
              operator: In
              values: ["arm64", "amd64"]
            # On-Demand と Spot の混在（コスト最適化）
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["on-demand", "spot"]
            - key: node.kubernetes.io/instance-type
              operator: In
              values:
                - m7g.medium
                - m7g.large
                - m6g.medium
                - m6g.large
                - t4g.medium
                - t4g.large
          taints:
            - key: cell
              value: cell-a
              effect: NoSchedule
      limits:
        cpu: 20
        memory: 80Gi
      disruption:
        consolidationPolicy: WhenUnderutilized
        consolidateAfter: 5m
  YAML

  depends_on = [kubectl_manifest.ec2nodeclass_cell_a]
}

# --- NodePool: Cell-B ---
resource "kubectl_manifest" "nodepool_cell_b" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: cell-b
    spec:
      template:
        metadata:
          labels:
            cell: cell-b
            topology.kubernetes.io/zone: ap-northeast-1c
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: cell-b
          requirements:
            - key: topology.kubernetes.io/zone
              operator: In
              values: ["ap-northeast-1c"]
            - key: kubernetes.io/arch
              operator: In
              values: ["arm64", "amd64"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["on-demand", "spot"]
            - key: node.kubernetes.io/instance-type
              operator: In
              values:
                - m7g.medium
                - m7g.large
                - m6g.medium
                - m6g.large
                - t4g.medium
                - t4g.large
          taints:
            - key: cell
              value: cell-b
              effect: NoSchedule
      limits:
        cpu: 20
        memory: 80Gi
      disruption:
        consolidationPolicy: WhenUnderutilized
        consolidateAfter: 5m
  YAML

  depends_on = [kubectl_manifest.ec2nodeclass_cell_b]
}
