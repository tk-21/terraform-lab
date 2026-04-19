# ✅Phase 4: Terraform モジュール実装（VPC / EKS）

## 前フェーズの要約

Phase 1: ディレクトリ骨格・ベース設定ファイルを生成
Phase 2: Ansible 3ロール実装（cis-benchmark / docker-runtime / eks-node-prep）
Phase 3: Packer Golden AMI テンプレート + GitHub Actions パイプライン

## このフェーズの目的

Terraform モジュールで VPC と EKS クラスターを実装する。
- VPC: 3層構成（public / private / intra）、NAT Gateway、VPC Flow Logs
- EKS: Control Plane のみ（Managed Node Groupなし）、IRSA、Karpenter用IAMロール

Karpenter NodeClass での Golden AMI 参照は Phase 5 で実装する。

---

## タスク一覧

### 1. VPC モジュール

**ファイル: `terraform/modules/vpc/variables.tf`**

```hcl
variable "project" {
  description = "プロジェクト名"
  type        = string
}

variable "environment" {
  description = "環境名 (dev/stg/prod)"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC の CIDR ブロック"
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "使用するアベイラビリティゾーン"
  type        = list(string)
  default     = ["ap-northeast-1a", "ap-northeast-1c", "ap-northeast-1d"]
}

variable "tags" {
  description = "共通タグ"
  type        = map(string)
  default     = {}
}
```

**ファイル: `terraform/modules/vpc/main.tf`**

```hcl
# VPC モジュール
# EKS 用 3層 VPC（public / private / intra）を構築する
# Karpenter ノードは private サブネットに配置する

locals {
  name = "${var.project}-${var.environment}"

  # サブネット CIDR を VPC CIDR から自動計算
  # 10.0.0.0/16 の場合:
  #   public:  10.0.0.0/24, 10.0.1.0/24, 10.0.2.0/24
  #   private: 10.0.10.0/24, 10.0.11.0/24, 10.0.12.0/24
  #   intra:   10.0.20.0/24, 10.0.21.0/24, 10.0.22.0/24
  public_subnets  = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnets = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, i + 10)]
  intra_subnets   = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, i + 20)]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  name = "${local.name}-vpc"
  cidr = var.vpc_cidr

  azs             = var.azs
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets
  intra_subnets   = local.intra_subnets

  # NAT Gateway（dev環境はコスト削減のため1台）
  enable_nat_gateway     = true
  single_nat_gateway     = true   # devのみ。本番は false にする
  one_nat_gateway_per_az = false

  # DNS 設定（EKS に必要）
  enable_dns_hostnames = true
  enable_dns_support   = true

  # VPC Flow Logs（セキュリティ監査用）
  enable_flow_log                      = true
  create_flow_log_cloudwatch_log_group = true
  create_flow_log_cloudwatch_iam_role  = true
  flow_log_max_aggregation_interval    = 60

  # EKS 用サブネットタグ（ALB / Karpenter が参照）
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"  # Internet-facing ALB 用
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"  # Internal ALB 用
    "karpenter.sh/discovery"          = "${local.name}"  # Karpenter がサブネット検索に使用
  }

  tags = var.tags
}
```

**ファイル: `terraform/modules/vpc/outputs.tf`**

```hcl
output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "プライベートサブネット ID リスト（EKS ノード配置用）"
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "パブリックサブネット ID リスト（ALB 配置用）"
  value       = module.vpc.public_subnets
}

output "intra_subnet_ids" {
  description = "イントラサブネット ID リスト（EKS Control Plane ENI 配置用）"
  value       = module.vpc.intra_subnets
}
```

---

### 2. EKS モジュール

**ファイル: `terraform/modules/eks/variables.tf`**

```hcl
variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "cluster_name" {
  description = "EKS クラスター名"
  type        = string
}

variable "cluster_version" {
  description = "EKS バージョン"
  type        = string
  default     = "1.30"
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  description = "EKS ノード配置サブネット"
  type        = list(string)
}

variable "intra_subnet_ids" {
  description = "EKS Control Plane ENI 配置サブネット"
  type        = list(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}
```

**ファイル: `terraform/modules/eks/main.tf`**

```hcl
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
  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = true
  cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]  # 本番では絞る

  # EKS Add-ons（必要最低限）
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent    = true
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
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",  # SSM Session Manager用
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
```

**ファイル: `terraform/modules/eks/outputs.tf`**

```hcl
output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "karpenter_irsa_arn" {
  description = "Karpenter Controller の IRSA ARN"
  value       = module.karpenter_irsa.iam_role_arn
}

output "karpenter_node_instance_profile_name" {
  description = "Karpenter が EC2 起動時に使用する Instance Profile 名"
  value       = aws_iam_instance_profile.karpenter_node.name
}

output "karpenter_node_role_arn" {
  description = "Karpenter ノードの IAM Role ARN"
  value       = aws_iam_role.karpenter_node.arn
}
```

---

### 3. dev 環境エントリーポイント

**ファイル: `terraform/environments/dev/main.tf`**

```hcl
# dev 環境 Terraform エントリーポイント
# モジュールを呼び出して EKS + VPC を構築する

locals {
  project     = var.project
  environment = var.environment
  cluster_name = "${var.project}-${var.environment}"

  # 共通タグ（CLAUDE.md のタグ戦略に従う）
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "infrastructure-team"
    CostCenter  = "platform"
  }
}

# VPC モジュール
module "vpc" {
  source = "../../modules/vpc"

  project     = local.project
  environment = local.environment
  vpc_cidr    = var.vpc_cidr
  tags        = local.common_tags
}

# EKS モジュール
module "eks" {
  source = "../../modules/eks"

  project            = local.project
  environment        = local.environment
  cluster_name       = local.cluster_name
  cluster_version    = var.eks_version
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  intra_subnet_ids   = module.vpc.intra_subnet_ids
  tags               = local.common_tags
}
```

**ファイル: `terraform/environments/dev/variables.tf`**

```hcl
variable "project" {
  type    = string
  default = "eks-golden-node-pipeline"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "aws_region" {
  type    = string
  default = "ap-northeast-1"
}

variable "eks_version" {
  type    = string
  default = "1.30"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}
```

**ファイル: `terraform/environments/dev/outputs.tf`**

```hcl
output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value     = module.eks.cluster_endpoint
  sensitive = true
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "karpenter_irsa_arn" {
  value = module.eks.karpenter_irsa_arn
}

output "karpenter_node_instance_profile_name" {
  value = module.eks.karpenter_node_instance_profile_name
}
```

---

## 完了条件

- [ ] `terraform/modules/vpc/main.tf` が存在する
- [ ] `terraform/modules/vpc/variables.tf` が存在する
- [ ] `terraform/modules/vpc/outputs.tf` が存在する
- [ ] `terraform/modules/eks/main.tf` が存在する
- [ ] `terraform/modules/eks/variables.tf` が存在する
- [ ] `terraform/modules/eks/outputs.tf` が存在する
- [ ] `terraform/environments/dev/main.tf` が存在する
- [ ] `terraform/environments/dev/variables.tf` が存在する
- [ ] `terraform/environments/dev/outputs.tf` が存在する
- [ ] `terraform validate` がエラーなく通過する

## 次フェーズへの引き継ぎ

Phase 5 では Karpenter モジュールを実装し、
Golden AMI の AMI ID を EC2NodeClass に組み込む。
Phase 4 で出力した `karpenter_irsa_arn` と `karpenter_node_instance_profile_name` を使用する。