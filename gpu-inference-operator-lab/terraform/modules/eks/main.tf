data "aws_caller_identity" "current" {}

# EKSクラスタ本体
resource "aws_eks_cluster" "main" {
  name    = local.cluster_name
  version = var.cluster_version
  # クラスタコントロールプレーンのIAMロール
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    # APIエンドポイントをプライベートのみにする
    # NAT Gatewayなし設計のため、パブリックエンドポイントは不要
    endpoint_private_access = true
    endpoint_public_access  = false
    security_group_ids      = [aws_security_group.cluster.id]
  }

  # CloudWatch Logs へのクラスタログ送信
  # VPC Endpoint (logs) 経由でインターネットを使わずに送信できる
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]

  tags = merge(local.common_tags, {
    Name = local.cluster_name
  })
}

# OIDC プロバイダー: IRSAで各PodがAWSサービスに最小権限でアクセスするために必要
resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# EKSクラスタ用セキュリティグループ
resource "aws_security_group" "cluster" {
  name        = "${local.cluster_name}-sg-cluster"
  description = "EKSクラスタコントロールプレーン用。ノードグループからのAPIサーバーアクセスのみ許可"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-sg-cluster"
  })
}

# システムコンポーネント用マネージドノードグループ
# CoreDNS / kube-proxy / Karpenter自体 / Operator Podが動作する
# GPUワークロードはKarpenterが動的に起動するGPUノードで動く(このノードグループではない)
resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.cluster_name}-ng-system"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids

  # Graviton2(arm64)で統一する
  # x86_64インスタンスに比べてコスト約20%削減かつ電力効率が高い
  instance_types = var.system_node_instance_types
  ami_type       = "AL2_ARM_64"
  capacity_type  = "ON_DEMAND"

  scaling_config {
    desired_size = var.system_node_desired
    min_size     = var.system_node_min
    max_size     = var.system_node_max
  }

  update_config {
    # ローリングアップデート時に同時に更新できるノードの最大数
    max_unavailable = 1
  }

  labels = {
    # systemコンポーネントのみをスケジュールするためのラベル
    "node-role" = "system"
  }

  # KarpenterがこのノードグループのノードをEKS Auto Mode候補から除外するために必要
  taint {
    key    = "node-role"
    value  = "system"
    effect = "NO_SCHEDULE"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_ecr_policy,
  ]

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-ng-system"
  })
}

# Karpenter が新しいノードを検出するためのタグ
# EKSクラスタとKarpenterを紐付ける
resource "aws_ec2_tag" "cluster_for_karpenter" {
  resource_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = local.cluster_name
}
