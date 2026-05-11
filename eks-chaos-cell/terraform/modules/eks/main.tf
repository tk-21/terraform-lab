# =============================================================
# EKS クラスターモジュール
# Managed Node Group で最小起動（Karpenterは Phase 2）
# IRSA有効・CloudWatch Container Insights有効
# =============================================================

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
  }
}

# --- EKS クラスター IAMロール ---
resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

# --- EKS クラスター ---
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true # ローカル開発のためpublic許可（本番では要検討）
    public_access_cidrs     = var.public_access_cidrs
  }

  # クラスターログ（監査・API・コントローラーマネージャー）
  enabled_cluster_log_types = ["audit", "api", "controllerManager"]

  tags = merge(var.common_tags, {
    Name = var.cluster_name
    # FIS実験がEKSリソースを特定するためのタグ
    "chaos-target" = "true"
  })

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}

# --- OIDC Provider（IRSA用）---
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  tags            = var.common_tags
}

# --- Node Group IAMロール ---
resource "aws_iam_role" "node_group" {
  name = "${var.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    # CloudWatch Container Insights
    "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  ])
  policy_arn = each.key
  role       = aws_iam_role.node_group.name
}

# --- Managed Node Group（システム用 / Karpenter用ではない）---
# Karpenterコントローラー自体を動かすためのノード
# arm64（Graviton）を使用してコスト最適化
resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-system"
  node_role_arn   = aws_iam_role.node_group.arn

  # システムノードはAZ-aにのみ配置（最小コスト）
  subnet_ids = [var.private_subnet_ids_by_az["az-a"]]

  instance_types = ["t4g.medium"] # Graviton2 arm64

  ami_type = "AL2_ARM_64" # arm64用AMI

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 4
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    role = "system"
    # Karpenterがシステムノードを避けるためのラベル
    "node.kubernetes.io/purpose" = "system"
  }

  # FIS実験のターゲットにならないようタグで除外
  tags = merge(var.common_tags, {
    Name           = "${var.cluster_name}-system-node"
    "chaos-target" = "false"
  })

  depends_on = [aws_iam_role_policy_attachment.node_worker]
}

# --- セキュリティグループ: ノード間通信 ---
resource "aws_security_group" "nodes" {
  name        = "${var.cluster_name}-nodes-sg"
  description = "EKS nodes communication"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
    description = "ノード間全通信許可"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "全アウトバウンド許可"
  }

  tags = merge(var.common_tags, {
    Name = "${var.cluster_name}-nodes-sg"
    # Karpenterがセキュリティグループを検出するためのタグ
    "karpenter.sh/discovery" = var.cluster_name
  })
}
