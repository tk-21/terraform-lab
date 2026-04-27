locals {
  prefix = "ept-${var.environment}"
  tags   = merge(var.common_tags, { ManagedBy = "terraform" })
}

# ---------------------------------------------------------------------------
# Cluster IAM role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "cluster" {
  name = "${local.prefix}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.tags, { Name = "${local.prefix}-eks-cluster-role" })
}

resource "aws_iam_role_policy_attachment" "cluster_eks_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ---------------------------------------------------------------------------
# EKS cluster
# ---------------------------------------------------------------------------

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.cluster_version

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  tags = merge(local.tags, { Name = var.cluster_name })

  depends_on = [aws_iam_role_policy_attachment.cluster_eks_policy]
}

# ---------------------------------------------------------------------------
# Node group IAM role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "node_group" {
  name = "${local.prefix}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.tags, { Name = "${local.prefix}-eks-node-role" })
}

resource "aws_iam_role_policy_attachment" "node_worker_policy" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni_policy" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr_policy" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# ---------------------------------------------------------------------------
# Managed node group (system / Karpenter nodes — ON_DEMAND, fixed size)
# ---------------------------------------------------------------------------

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${local.prefix}-system"
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = var.subnet_ids
  instance_types  = ["t3.medium"]
  capacity_type   = "ON_DEMAND"

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 2
  }

  update_config {
    max_unavailable = 1
  }

  tags = merge(local.tags, { Name = "${local.prefix}-system" })

  depends_on = [
    aws_iam_role_policy_attachment.node_worker_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_ecr_policy,
  ]
}

# ---------------------------------------------------------------------------
# EKS addons
# ---------------------------------------------------------------------------

resource "aws_eks_addon" "vpc_cni" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "vpc-cni"
  most_recent   = true
  tags          = merge(local.tags, { Name = "${var.cluster_name}-vpc-cni" })
  depends_on    = [aws_eks_node_group.system]
}

resource "aws_eks_addon" "coredns" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "coredns"
  most_recent   = true
  tags          = merge(local.tags, { Name = "${var.cluster_name}-coredns" })
  depends_on    = [aws_eks_node_group.system]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "kube-proxy"
  most_recent   = true
  tags          = merge(local.tags, { Name = "${var.cluster_name}-kube-proxy" })
  depends_on    = [aws_eks_node_group.system]
}

resource "aws_eks_addon" "aws_ebs_csi_driver" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "aws-ebs-csi-driver"
  most_recent   = true
  tags          = merge(local.tags, { Name = "${var.cluster_name}-aws-ebs-csi-driver" })
  depends_on    = [aws_eks_node_group.system]
}

# ---------------------------------------------------------------------------
# IRSA — OIDC provider
# ---------------------------------------------------------------------------

data "tls_certificate" "cluster" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster.certificates[0].sha1_fingerprint]

  tags = merge(local.tags, { Name = "${var.cluster_name}-oidc" })
}
