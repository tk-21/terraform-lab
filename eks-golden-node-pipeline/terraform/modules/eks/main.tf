# EKS モジュール
# Managed Node Group は作成しない（Karpenter で管理するため）
# Karpenter が参照する IAM Role と Instance Profile を作成する

locals {
  name = "${var.project}-${var.environment}"
}

# EKS クラスター本体
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  # Control Plane のエンドポイントアクセス設定
  # プライベートアクセスを有効にし、パブリックはCIDRで制限
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"] # 本番では絞る

  # EKS Add-ons（必要最低限）
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
      # VPC CNI に IRSA を設定（IPv4 prefix delegation に必要）
      service_account_role_arn = module.vpc_cni_irsa.iam_role_arn
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  # Control Plane の ENI を intra サブネットに配置
  control_plane_subnet_ids = var.intra_subnet_ids

  # Managed Node Group は作成しない（Karpenter が管理）
  eks_managed_node_groups = {}

  # Karpenter が IAM Instance Profile を作成できるように
  # node_security_group にタグを付与
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  # アクセスエントリ（Kubernetes RBAC の AWS IAM 統合）
  enable_cluster_creator_admin_permissions = true

  tags = merge(var.tags, {
    # Karpenter が EKS クラスターを検索するためのタグ
    "karpenter.sh/discovery" = var.cluster_name
  })
}

# VPC CNI 用 IRSA
module "vpc_cni_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "${var.cluster_name}-vpc-cni-irsa"
  attach_vpc_cni_policy = true
  vpc_cni_enable_ipv4   = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-node"]
    }
  }

  tags = var.tags
}

# EBS CSI Driver 用 IRSA
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "${var.cluster_name}-ebs-csi-irsa"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = var.tags
}

# Karpenter 用 IRSA（Karpenter Controller の ServiceAccount が使用）
module "karpenter_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                          = "${var.cluster_name}-karpenter-irsa"
  attach_karpenter_controller_policy = true

  karpenter_controller_cluster_name       = module.eks.cluster_name
  karpenter_controller_node_iam_role_arns = [aws_iam_role.karpenter_node.arn]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["karpenter:karpenter"]
    }
  }

  tags = var.tags
}

# Karpenter が起動する EC2 ノード用 IAM ロール
resource "aws_iam_role" "karpenter_node" {
  name = "${var.cluster_name}-karpenter-node-role"

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

  tags = var.tags
}

# Karpenter ノードに必要な AWS マネージドポリシーをアタッチ
resource "aws_iam_role_policy_attachment" "karpenter_node_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore", # SSM Session Manager用
  ])

  role       = aws_iam_role.karpenter_node.name
  policy_arn = each.value
}

# Instance Profile（Karpenter がノード起動時に割り当てる）
resource "aws_iam_instance_profile" "karpenter_node" {
  name = "${var.cluster_name}-karpenter-node-profile"
  role = aws_iam_role.karpenter_node.name
  tags = var.tags
}
