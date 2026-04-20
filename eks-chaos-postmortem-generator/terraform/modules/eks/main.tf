# =============================================================================
# EKSモジュール - EKS Chaos Postmortem Generator
# EKSクラスター、ノードグループ、IRSA設定を管理
# =============================================================================

# ============================================================
# EKSクラスター用IAMロール
# ============================================================

# EKSコントロールプレーンが使用するIAMロール
resource "aws_iam_role" "eks_cluster" {
  name = "${var.project}-cluster-role-${var.environment}"

  # EKSサービスがこのロールを引き受けられるようにする信頼ポリシー
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(var.tags, {
    Name        = "${var.project}-cluster-role-${var.environment}"
    Environment = var.environment
  })
}

# EKSクラスターの基本操作に必要なAWSマネージドポリシー
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

# ============================================================
# EKSクラスター本体
# ============================================================

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = "1.30"  # Kubernetesバージョン（定期的に更新が必要）
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids = var.private_subnet_ids

    # パブリックエンドポイントを有効化（dev環境のみ許可）
    # 本番環境では必ずfalseに設定し、VPN/踏み台経由でのみアクセスすること
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  # CloudWatch Logsへのコントロールプレーンログ出力
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # IAMロールのポリシーアタッチメント完了後にクラスターを作成
  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
  ]

  tags = merge(var.tags, {
    Name        = var.cluster_name
    Environment = var.environment
  })
}

# ============================================================
# ノードグループ用IAMロール
# ============================================================

# ワーカーノードが使用するIAMロール
resource "aws_iam_role" "eks_nodes" {
  name = "${var.project}-nodes-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(var.tags, {
    Name        = "${var.project}-nodes-role-${var.environment}"
    Environment = var.environment
  })
}

# ノードがEKSに登録し、Podを実行するために必要なポリシー
resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_nodes.name
}

# VPC CNIプラグイン（Pod間通信）に必要なポリシー
resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_nodes.name
}

# ECRからコンテナイメージをプルするために必要なポリシー（ReadOnly）
resource "aws_iam_role_policy_attachment" "eks_ecr_read_only" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_nodes.name
}

# ============================================================
# マネージドノードグループ: baseline（通常ワークロード用）
# ============================================================

resource "aws_eks_node_group" "baseline" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project}-baseline-${var.environment}"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = var.private_subnet_ids

  # インスタンスタイプ（コスト最適化のためt3.medium）
  instance_types = ["t3.medium"]
  ami_type       = "AL2_x86_64"

  scaling_config {
    desired_size = 2
    min_size     = 1
    max_size     = 4
  }

  update_config {
    max_unavailable = 1  # ローリングアップデート時の最大停止ノード数
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_read_only,
  ]

  tags = merge(var.tags, {
    Name        = "${var.project}-baseline-${var.environment}"
    Environment = var.environment
    # FIS実験の誤適用防止: baselineノードはChaos実験の対象外
    ChaosTarget = "false"
  })
}

# ============================================================
# マネージドノードグループ: chaos（FIS実験対象ノード）
# ============================================================

resource "aws_eks_node_group" "chaos" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project}-chaos-${var.environment}"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = var.private_subnet_ids

  instance_types = ["t3.medium"]
  ami_type       = "AL2_x86_64"

  scaling_config {
    desired_size = 2
    min_size     = 1
    max_size     = 4
  }

  update_config {
    max_unavailable = 1
  }

  # Kubernetes Labelsを付与してFIS実験のターゲット選択に使用
  labels = {
    role = "chaos-target"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_read_only,
  ]

  tags = merge(var.tags, {
    Name        = "${var.project}-chaos-${var.environment}"
    Environment = var.environment
    # ChaosTarget=trueのノードのみFIS実験の対象とする（安全設計）
    ChaosTarget = "true"
  })
}

# ============================================================
# EKSアドオン
# ============================================================

# VPC CNI: Pod間のネットワーク通信を管理
resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"

  tags = merge(var.tags, {
    Environment = var.environment
  })

  depends_on = [aws_eks_node_group.baseline]
}

# CoreDNS: クラスター内のDNS名前解決
resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"

  tags = merge(var.tags, {
    Environment = var.environment
  })

  depends_on = [aws_eks_node_group.baseline]
}

# kube-proxy: ノード上でネットワークルールを管理
resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"

  tags = merge(var.tags, {
    Environment = var.environment
  })

  depends_on = [aws_eks_node_group.baseline]
}

# EBS CSI Driver: PersistentVolumeとしてEBSを使用するために必要
# IRSA（IAM Roles for Service Accounts）を使用してアクセスキー不要でEBSを操作
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi.arn  # IRSAロールを使用

  tags = merge(var.tags, {
    Environment = var.environment
  })

  depends_on = [
    aws_eks_node_group.baseline,
    aws_iam_role_policy_attachment.ebs_csi_policy,
  ]
}

# ============================================================
# OIDCプロバイダー（IRSA設定の基盤）
# ============================================================

# EKSクラスターのOIDCエンドポイント証明書を取得
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# OIDCプロバイダーを作成（ServiceAccountにIAMロールを紐付けるために必要）
resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = merge(var.tags, {
    Name        = "${var.cluster_name}-oidc-provider"
    Environment = var.environment
  })
}

# ============================================================
# EBS CSI Driver用 IRSAロール
# ServiceAccount: kube-system/ebs-csi-controller-sa にバインド
# ============================================================

resource "aws_iam_role" "ebs_csi" {
  name = "${var.project}-ebs-csi-role-${var.environment}"

  # OIDCプロバイダーを通じてEBS CSI Driver ServiceAccountのみがこのロールを引き受け可能
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRoleWithWebIdentity"
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.eks.arn
        }
        Condition = {
          StringEquals = {
            # 特定のServiceAccountのみに権限を絞る（最小権限の原則）
            "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
            "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = merge(var.tags, {
    Name        = "${var.project}-ebs-csi-role-${var.environment}"
    Environment = var.environment
  })
}

# EBS CSI DriverがEBSを操作するために必要なAWSマネージドポリシー
resource "aws_iam_role_policy_attachment" "ebs_csi_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi.name
}
