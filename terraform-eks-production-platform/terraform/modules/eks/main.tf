################################################################################
# EKSモジュール - クラスター・Node Group定義
################################################################################

################################################################################
# KMSキー（EKS Secrets暗号化用）
#
# EKSのSecretsをKMSで暗号化する理由：
# Kubernetes Secretsはデフォルトでetcdにbase64エンコードで保存される（暗号化なし）。
# KMS暗号化を有効にすることでetcdの物理的なアクセス・スナップショット漏洩時に
# Secretsの内容を保護できる。
################################################################################

resource "aws_kms_key" "eks" {
  description             = "${var.project_name}-${var.environment} EKS Secrets暗号化用KMSキー"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-kms-eks"
  })
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.project_name}-${var.environment}-eks"
  target_key_id = aws_kms_key.eks.key_id
}

################################################################################
# EKSクラスター用IAMロール
#
# EKSコントロールプレーンがAWSサービス（EC2, ELB等）を操作するために必要。
# AmazonEKSClusterPolicy: EKSコントロールプレーンの基本動作に必要なポリシー
################################################################################

resource "aws_iam_role" "cluster" {
  name = "${var.project_name}-${var.environment}-role-eks-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

################################################################################
# EKSクラスター用セキュリティグループ
#
# EKSはデフォルトでクラスターSGを作成するが、追加のSGで細かく制御する。
# コントロールプレーン（APIサーバー）へのアクセスをノードSGからのみ許可する。
################################################################################

resource "aws_security_group" "cluster" {
  name        = "${var.project_name}-${var.environment}-sg-eks-cluster"
  description = "EKSクラスターコントロールプレーン用セキュリティグループ"
  vpc_id      = var.vpc_id

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-sg-eks-cluster"
  })
}

resource "aws_security_group" "node" {
  name        = "${var.project_name}-${var.environment}-sg-eks-node"
  description = "EKSノードグループ用セキュリティグループ"
  vpc_id      = var.vpc_id

  # ノード間の全通信を許可する理由：
  # Kubernetes のPod間通信、kubelet、kube-proxyなど様々なプロトコルと
  # ポートを使用するため、ノード間は全許可が実用的。
  ingress {
    description = "ノード間の全通信を許可（Pod間通信・kubelet等）"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  # APIサーバー（コントロールプレーン）からノードへのアクセスを許可
  ingress {
    description     = "EKSコントロールプレーンからノードへのアクセス"
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.cluster.id]
  }

  egress {
    description = "アウトバウンドは全許可（NAT経由でAWSサービスにアクセス）"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-sg-eks-node"
    # Karpenterがノード用セキュリティグループを検索するためのタグ
    "karpenter.sh/discovery" = "${var.project_name}-${var.environment}-cluster"
  })
}

# クラスターSGからノードSGへのインバウンドルール
resource "aws_security_group_rule" "cluster_to_node" {
  type                     = "ingress"
  description              = "ノードからEKS APIサーバーへの接続（kubelet, kubectl等）"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.cluster.id
  source_security_group_id = aws_security_group.node.id
}

################################################################################
# EKSクラスター
################################################################################

resource "aws_eks_cluster" "this" {
  name     = "${var.project_name}-${var.environment}-cluster"
  role_arn = aws_iam_role.cluster.arn
  version  = var.cluster_version

  vpc_config {
    # Private サブネットにノードを配置し、APIサーバーへのアクセスはVPN/Bastionを推奨。
    # public_access=true を残す理由：GitOps・CI/CDツールからのkubectl接続に必要。
    # public_access_cidrs で IP制限することで安全性を確保。
    endpoint_public_access  = true
    endpoint_private_access = true
    public_access_cidrs     = var.public_access_cidrs
    subnet_ids              = var.private_subnet_ids
    security_group_ids      = [aws_security_group.cluster.id]
  }

  # コントロールプレーンのCloudWatchログを全種類有効にする理由：
  # - api: APIサーバーの全リクエストログ。セキュリティ監査・トラブルシュートに不可欠
  # - audit: Kubernetesの監査ログ。誰が何をしたかを追跡できる
  # - authenticator: aws-iam-authenticatorのログ。認証失敗の調査に使用
  # - controllerManager: デプロイメント・レプリカセット管理のログ
  # - scheduler: Podスケジューリングのログ
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  encryption_config {
    # KMSキーでKubernetes Secretsを暗号化する
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.eks.arn
    }
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-cluster"
  })

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy,
  ]
}

################################################################################
# Node Group用IAMロール
#
# EC2インスタンス（EKSノード）がAWSサービスにアクセスするために必要。
# 3つのポリシーがMinimum Required：
# - AmazonEKSWorkerNodePolicy: EKSクラスターへの参加
# - AmazonEKS_CNI_Policy: VPC CNI（PodへのIPアドレス割り当て）
# - AmazonEC2ContainerRegistryReadOnly: ECRからのイメージPull
################################################################################

resource "aws_iam_role" "node_group" {
  name = "${var.project_name}-${var.environment}-role-eks-node-group"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# SSMセッションマネージャー経由でのノードアクセスを可能にする。
# SSHキーペアを使わずにノードにアクセスできるセキュアな方法。
resource "aws_iam_role_policy_attachment" "node_ssm" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

################################################################################
# EKS Managed Node Group
#
# Karpenterと併用する設計のため、初期ノード数は最小限にする。
# Managed Node Group はシステム系Pod（kube-system）とKarpenter自身を動かすための
# 常駐ノード。アプリケーションノードはKarpenterが管理する。
################################################################################

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.project_name}-${var.environment}-ng-system"
  node_role_arn   = aws_iam_role.node_group.arn

  # プライベートサブネットのみに配置する理由：
  # EKSノードはインターネットから直接アクセスされるべきではない。
  # ALBからのトラフィックはノードポート経由で届くためパブリックIPは不要。
  subnet_ids = var.private_subnet_ids

  # インスタンスタイプを複数指定する理由：
  # スポットインスタンス使用時に特定のタイプが枯渇した場合の代替として機能する。
  # t3.medium: 2vCPU/4GB - 通常ワークロード用
  # t3.large:  2vCPU/8GB - メモリを多く使うシステムPod用
  instance_types = var.node_group_instance_types

  scaling_config {
    desired_size = var.node_group_desired_size
    min_size     = var.node_group_min_size
    max_size     = var.node_group_max_size
  }

  update_config {
    # アップデート時に一度に利用不可にする最大ノード数。
    # 1つずつ更新することでサービス停止を防ぐ。
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.node_group.id
    version = aws_launch_template.node_group.latest_version
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-ng-system"
  })

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]

  lifecycle {
    # desired_sizeはCluster Autoscalerやkubectlから変更される可能性があるため
    # Terraformの管理外にする（変更を無視）
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# Launch Template
# Node Groupの詳細設定（ディスク、メタデータ設定等）はLaunch Templateで管理する。
# Node GroupリソースのdiskSizeパラメーターはLaunch Template使用時は指定できないため
# Launch Template側で設定する。
resource "aws_launch_template" "node_group" {
  name_prefix = "${var.project_name}-${var.environment}-lt-eks-node-"

  # IMDSv2を強制する理由：
  # IMDSv1はSSRF攻撃でPodからノードのIAM認証情報を取得できる脆弱性がある。
  # IMDSv2ではセッショントークンが必要になるためSSRF攻撃を防げる。
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2を強制
    http_put_response_hop_limit = 2          # Podからのアクセスに必要（hop_limit=1だとPodから届かない）
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.node_group_disk_size
      volume_type           = "gp3" # gp3はgp2より性能が高くコストも安い
      delete_on_termination = true
      # ノードのルートボリュームを暗号化する理由：
      # コンテナのファイルシステムやログがディスクに残るため暗号化で保護する。
      encrypted = true
    }
  }

  # ノードのセキュリティグループを明示的に指定
  vpc_security_group_ids = [aws_security_group.node.id]

  tags = var.common_tags

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.common_tags, {
      Name = "${var.project_name}-${var.environment}-eks-node"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(var.common_tags, {
      Name = "${var.project_name}-${var.environment}-eks-node-volume"
    })
  }
}

################################################################################
# OIDC Provider
#
# IRSAの基盤となるOIDC Providerを作成する。
# EKSはOIDCエンドポイントを持つためPodのServiceAccountトークンを
# AWS STSで検証してIAMロールに変換できる（IRSA）。
################################################################################

data "tls_certificate" "eks" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer

  client_id_list = ["sts.amazonaws.com"]

  # OIDCプロバイダーのサムプリントはTLSエンドポイントから自動取得する。
  # ハードコードすると証明書更新時に手動変更が必要になるため自動化する。
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.environment}-oidc-provider"
  })
}

################################################################################
# aws-auth ConfigMap
#
# Terraformで管理する理由：
# 手動でkubectl editすると複数人の開発環境で整合性が取れなくなる。
# Terraformで管理することでコードレビューと変更追跡ができる。
################################################################################

resource "kubernetes_config_map_v1_data" "aws_auth" {
  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }

  force = true

  data = {
    mapRoles = yamlencode([
      # Managed Node Group用ロール
      # EKSノードがクラスターに参加するために必要
      {
        rolearn  = aws_iam_role.node_group.arn
        username = "system:node:{{EC2PrivateDNSName}}"
        groups   = ["system:bootstrappers", "system:nodes"]
      },
      # Karpenterが起動するノード用のIAMロール
      # Karpenterは独自のノードIAMロールを使用してノードを起動する
      {
        rolearn  = aws_iam_role.karpenter_node.arn
        username = "system:node:{{EC2PrivateDNSName}}"
        groups   = ["system:bootstrappers", "system:nodes"]
      },
    ])
  }

  depends_on = [aws_eks_cluster.this, aws_eks_node_group.this]
}

################################################################################
# Karpenterノード用IAMロール
#
# Karpenterが起動するノードのIAMロール。
# Managed Node Groupのロールとは分離する理由：
# Karpenterノード固有の権限（Spot Interruption処理等）を最小権限で付与できる。
################################################################################

resource "aws_iam_role" "karpenter_node" {
  name = "${var.project_name}-${var.environment}-role-karpenter-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
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
  name = "${var.project_name}-${var.environment}-profile-karpenter-node"
  role = aws_iam_role.karpenter_node.name

  tags = var.common_tags
}

################################################################################
# EKS Add-ons
#
# マネージドアドオンを使用する理由：
# Terraformでバージョン管理でき、EKSバージョンアップ時の互換性を自動確認できる。
################################################################################

# VPC CNI: PodにVPCのIPアドレスを割り当てる
resource "aws_eks_addon" "vpc_cni" {
  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.common_tags
}

# kube-proxy: ネットワークルール管理
resource "aws_eks_addon" "kube_proxy" {
  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.common_tags
}

# CoreDNS: クラスター内DNS解決
resource "aws_eks_addon" "coredns" {
  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.common_tags

  depends_on = [aws_eks_node_group.this]
}
