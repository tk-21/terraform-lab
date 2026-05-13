locals {
  cluster_name = "${var.project_name}-${var.env}"
}

# EKS APIエンドポイントはパブリック+プライベートのデュアル構成
# パブリックエンドポイントはCIDRホワイトリストで保護し、
# kubectlからのアクセスを許可しつつ不正アクセスを防ぐ
resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  version  = var.eks_cluster_version
  role_arn = var.cluster_role_arn

  vpc_config {
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.allowed_cidr_blocks
  }

  # セキュリティ監査のためAPIサーバーとauditログを有効化
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  tags = {
    Name = local.cluster_name
  }
}

# Spotインスタンスでコストを最大70%削減
# ハンズオン環境のため中断リスク（通常月1〜2回程度）は許容する
# Spotが中断された場合はASGが自動で別のインスタンスを起動する
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.cluster_name}-workers"
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.private_subnet_ids

  instance_types = [var.node_instance_type]
  capacity_type  = "SPOT"

  # Amazon Linux 2023（AL2のサポート終了に備えた最新AMI）
  ami_type = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  labels = {
    role = "worker"
    env  = var.env
  }

  tags = {
    Name = "${local.cluster_name}-workers"
  }

  depends_on = [aws_eks_cluster.main]
}

# VPC CNI, CoreDNS, kube-proxy はEKSマネージドアドオンで管理
# バージョン更新をAWSに委譲しセキュリティパッチを自動適用する
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}
