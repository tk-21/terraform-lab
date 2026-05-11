# ✅Phase 1: VPC・EKSクラスター・Terraform Backend・OIDC基盤

## このフェーズの目的

Cell-Based EKSの土台となるネットワーク・クラスターを構築する。
KarpenterはPhase 2で導入するため、ここではManaged Node Groupで最小構成を起動する。

**完了後の状態**: `kubectl get nodes` でノードが確認できる

---

## 作成対象ファイル

### 1. terraform/backend/main.tf

```hcl
# =============================================================
# Terraform Backend リソース
# S3（tfstate）+ DynamoDB（ロック）+ GitHub Actions OIDC
# 一度だけ手動applyする
# =============================================================

terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" { region = var.aws_region }

# --- S3バケット ---
resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.project_name}-tfstate-${var.aws_account_id}"
  lifecycle { prevent_destroy = true }
  tags = local.common_tags
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- DynamoDB ロックテーブル ---
resource "aws_dynamodb_table" "tfstate_lock" {
  name         = "${var.project_name}-tfstate-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }
  tags = local.common_tags
}

# --- GitHub Actions OIDC Provider ---
resource "aws_iam_openid_connect_provider" "github" {
  count           = var.create_oidc_provider ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
  tags            = local.common_tags
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? (
    aws_iam_openid_connect_provider.github[0].arn
  ) : "arn:aws:iam::${var.aws_account_id}:oidc-provider/token.actions.githubusercontent.com"

  common_tags = {
    Project     = var.project_name
    Environment = "mgmt"
    ManagedBy   = "terraform"
    Owner       = var.owner
  }
}

# --- GitHub Actions IAMロール ---
# 命名: ecc-gha-role（eks-chaos-cell-github-actions-role を短縮）
resource "aws_iam_role" "github_actions" {
  name = "ecc-gha-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          "token.actions.githubusercontent.com:sub" : "repo:${var.github_org}/${var.github_repo}:*"
        }
        StringEquals = {
          "token.actions.githubusercontent.com:aud" : "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "github_actions" {
  name = "ecc-gha-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # tfstate 読み書き
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.tfstate.arn,
          "${aws_s3_bucket.tfstate.arn}/*"
        ]
      },
      # DynamoDB ロック
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
        Resource = aws_dynamodb_table.tfstate_lock.arn
      },
      # terraform plan に必要な読み取り権限
      {
        Effect = "Allow"
        Action = [
          "eks:Describe*", "eks:List*",
          "ec2:Describe*",
          "iam:Get*", "iam:List*",
          "kms:Describe*", "kms:List*"
        ]
        Resource = "*"
      }
    ]
  })
}
```

### 2. terraform/backend/variables.tf

```hcl
variable "aws_region" { type = string; default = "ap-northeast-1" }
variable "aws_account_id" { type = string }
variable "project_name" { type = string; default = "eks-chaos-cell" }
variable "owner" { type = string }
variable "github_org" { type = string }
variable "github_repo" { type = string; default = "eks-chaos-cell" }
variable "create_oidc_provider" { type = bool; default = true }
```

### 3. terraform/backend/outputs.tf

```hcl
output "tfstate_bucket_name" { value = aws_s3_bucket.tfstate.bucket }
output "tfstate_dynamodb_table" { value = aws_dynamodb_table.tfstate_lock.name }
output "github_actions_role_arn" { value = aws_iam_role.github_actions.arn }
```

---

### 4. terraform/modules/vpc/main.tf

```hcl
# =============================================================
# VPC モジュール
# Cell構成に合わせてAZ-a・AZ-c の2AZで構成する
# パブリック: ALB配置用 / プライベート: EKSノード配置用
# NAT GW は1台のみ（コスト最適化。本番では各AZに1台推奨）
# =============================================================

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

# --- VPC ---
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.common_tags, {
    Name                                        = "${var.project_name}-vpc"
    # EKSがVPCを認識するための必須タグ
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

# --- インターネットゲートウェイ ---
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(var.common_tags, { Name = "${var.project_name}-igw" })
}

# --- パブリックサブネット（ALB用）---
resource "aws_subnet" "public" {
  for_each = var.public_subnets

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-public-${each.key}"
    # ALB自動検出に必要なタグ
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

# --- プライベートサブネット（EKSノード用）---
resource "aws_subnet" "private" {
  for_each = var.private_subnets

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-private-${each.key}"
    # 内部ELB自動検出に必要なタグ
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    # Karpenterがサブネットを検出するためのタグ（Phase 2で使用）
    "karpenter.sh/discovery"                    = var.cluster_name
  })
}

# --- Elastic IP（NAT GW用）---
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(var.common_tags, { Name = "${var.project_name}-nat-eip" })
}

# --- NAT ゲートウェイ（AZ-a に1台）---
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public["az-a"].id

  tags = merge(var.common_tags, { Name = "${var.project_name}-nat" })
  depends_on = [aws_internet_gateway.main]
}

# --- ルートテーブル: パブリック ---
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = merge(var.common_tags, { Name = "${var.project_name}-rt-public" })
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# --- ルートテーブル: プライベート ---
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = merge(var.common_tags, { Name = "${var.project_name}-rt-private" })
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}
```

### 5. terraform/modules/vpc/variables.tf

```hcl
variable "project_name" { type = string }
variable "cluster_name" { type = string }
variable "vpc_cidr" { type = string; default = "10.0.0.0/16" }
variable "common_tags" { type = map(string); default = {} }

variable "public_subnets" {
  type = map(object({
    cidr = string
    az   = string
  }))
  default = {
    "az-a" = { cidr = "10.0.0.0/24", az = "ap-northeast-1a" }
    "az-c" = { cidr = "10.0.1.0/24", az = "ap-northeast-1c" }
  }
}

variable "private_subnets" {
  type = map(object({
    cidr = string
    az   = string
  }))
  default = {
    "az-a" = { cidr = "10.0.10.0/24", az = "ap-northeast-1a" }
    "az-c" = { cidr = "10.0.11.0/24", az = "ap-northeast-1c" }
  }
}
```

### 6. terraform/modules/vpc/outputs.tf

```hcl
output "vpc_id" { value = aws_vpc.main.id }
output "public_subnet_ids" { value = [for s in aws_subnet.public : s.id] }
output "private_subnet_ids" { value = [for s in aws_subnet.private : s.id] }
output "private_subnet_ids_by_az" {
  value = { for k, s in aws_subnet.private : k => s.id }
}
```

---

### 7. terraform/modules/eks/main.tf

```hcl
# =============================================================
# EKS クラスターモジュール
# Managed Node Group で最小起動（Karpenterは Phase 2）
# IRSA有効・CloudWatch Container Insights有効
# =============================================================

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
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
  name    = var.cluster_name
  version = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true   # ローカル開発のためpublic許可（本番では要検討）
    public_access_cidrs     = var.public_access_cidrs
  }

  # クラスターログ（監査・API・コントローラーマネージャー）
  enabled_cluster_log_types = ["audit", "api", "controllerManager"]

  # IRSA（Pod単位IAM）のためOIDCを有効化
  # Karpenterもこれを使う

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

  instance_types = ["t4g.medium"]  # Graviton2 arm64

  ami_type = "AL2_ARM_64"  # arm64用AMI

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
    Name         = "${var.cluster_name}-system-node"
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
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
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
```

### 8. terraform/modules/eks/variables.tf

```hcl
variable "cluster_name" { type = string }
variable "kubernetes_version" { type = string; default = "1.31" }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "private_subnet_ids_by_az" { type = map(string) }
variable "public_access_cidrs" { type = list(string); default = ["0.0.0.0/0"] }
variable "common_tags" { type = map(string); default = {} }
```

### 9. terraform/modules/eks/outputs.tf

```hcl
output "cluster_name" { value = aws_eks_cluster.main.name }
output "cluster_endpoint" { value = aws_eks_cluster.main.endpoint }
output "cluster_ca" { value = aws_eks_cluster.main.certificate_authority[0].data }
output "cluster_oidc_issuer" { value = aws_eks_cluster.main.identity[0].oidc[0].issuer }
output "oidc_provider_arn" { value = aws_iam_openid_connect_provider.eks.arn }
output "node_group_role_arn" { value = aws_iam_role.node_group.arn }
output "nodes_security_group_id" { value = aws_security_group.nodes.id }
```

---

### 10. terraform/main.tf

```hcl
# =============================================================
# eks-chaos-cell メインTerraform
# Phase 1: VPC + EKS のみ。Karpenter・FIS・観測は後フェーズ
# =============================================================

terraform {
  required_version = ">= 1.9"

  backend "s3" {
    bucket         = "eks-chaos-cell-tfstate-ACCOUNT_ID"  # backend apply後に実際の値に変更
    key            = "eks-chaos-cell/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "eks-chaos-cell-tfstate-lock"
    encrypt        = true
  }

  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = var.owner
    }
  }
}

locals {
  cluster_name = "${var.project_name}-${var.environment}"
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = var.owner
  }
}

module "vpc" {
  source       = "./modules/vpc"
  project_name = var.project_name
  cluster_name = local.cluster_name
  vpc_cidr     = var.vpc_cidr
  common_tags  = local.common_tags
}

module "eks" {
  source                   = "./modules/eks"
  cluster_name             = local.cluster_name
  vpc_id                   = module.vpc.vpc_id
  private_subnet_ids       = module.vpc.private_subnet_ids
  private_subnet_ids_by_az = module.vpc.private_subnet_ids_by_az
  common_tags              = local.common_tags
}
```

### 11. terraform/variables.tf

```hcl
variable "aws_region" { type = string; default = "ap-northeast-1" }
variable "aws_account_id" { type = string }
variable "project_name" { type = string; default = "eks-chaos-cell" }
variable "environment" { type = string; default = "prod" }
variable "owner" { type = string }
variable "vpc_cidr" { type = string; default = "10.0.0.0/16" }
```

### 12. terraform/outputs.tf

```hcl
output "cluster_name" { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "vpc_id" { value = module.vpc.vpc_id }
output "update_kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ap-northeast-1 --name ${module.eks.cluster_name}"
}
```

### 13. terraform/terraform.tfvars.example

```hcl
aws_account_id = "123456789012"
owner          = "your-name"
```

---

### 14. .github/workflows/terraform-plan.yml

```yaml
name: "Terraform Plan"

on:
  pull_request:
    branches: [main]
    paths: ["terraform/**"]

permissions:
  id-token: write
  contents: read
  pull-requests: write

jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/ecc-gha-role
          aws-region: ap-northeast-1

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.9.0"

      - name: Terraform Init
        working-directory: terraform
        run: |
          terraform init \
            -backend-config="bucket=eks-chaos-cell-tfstate-${{ secrets.AWS_ACCOUNT_ID }}" \
            -backend-config="key=eks-chaos-cell/terraform.tfstate" \
            -backend-config="region=ap-northeast-1" \
            -backend-config="dynamodb_table=eks-chaos-cell-tfstate-lock"

      - name: Terraform Plan
        working-directory: terraform
        run: |
          terraform plan \
            -var="aws_account_id=${{ secrets.AWS_ACCOUNT_ID }}" \
            -var="owner=github-actions" \
            -out=tfplan 2>&1 | tee plan_output.txt

      - name: Comment plan result
        uses: actions/github-script@v7
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          script: |
            const fs = require('fs');
            const plan = fs.readFileSync('terraform/plan_output.txt', 'utf8');
            await github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: `## Terraform Plan\n\`\`\`\n${plan.slice(-3000)}\n\`\`\``
            });
```

---

### 15. scripts/bootstrap.sh

```bash
#!/usr/bin/env bash
# =============================================================
# EKS セットアップ一括スクリプト
# terraform apply 後に実行してkubeconfigを設定する
# =============================================================
set -euo pipefail

CLUSTER_NAME="${1:-eks-chaos-cell-prod}"
REGION="ap-northeast-1"

echo "🚀 EKS セットアップ開始: ${CLUSTER_NAME}"

# kubeconfig 更新
aws eks update-kubeconfig \
  --region "${REGION}" \
  --name "${CLUSTER_NAME}"

# 接続確認
echo "📋 ノード確認..."
kubectl get nodes -o wide

# AWS Load Balancer Controller のインストール（helm）
echo "📦 AWS Load Balancer Controller インストール..."
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# CoreDNS / kube-proxy / VPC CNI のアドオン確認
echo "📋 EKSアドオン確認..."
aws eks list-addons --cluster-name "${CLUSTER_NAME}" --region "${REGION}"

echo "✅ セットアップ完了"
echo ""
echo "次のステップ:"
echo "  claude < phase2.md  # Karpenter導入"
```

---

## 実行手順

```bash
# 1. backend bootstrap
cd terraform/backend
cp terraform.tfvars.example terraform.tfvars  # 値を編集
terraform init
terraform apply

# 2. main.tf の backend バケット名を実際の値に更新
# "eks-chaos-cell-tfstate-ACCOUNT_ID" → 実際のアカウントID

# 3. EKS クラスター作成（約15分）
cd ../
terraform init
terraform apply -var="aws_account_id=YOUR_ACCOUNT_ID" -var="owner=YOUR_NAME"

# 4. kubeconfig 設定
chmod +x ../scripts/bootstrap.sh
../scripts/bootstrap.sh eks-chaos-cell-prod
```

---

## 完了確認チェックリスト

- [ ] `terraform/backend/` が apply 済み（S3・DynamoDB・OIDC IAMロール作成）
- [ ] `terraform/` が apply 済み（VPC・EKS作成、約15分）
- [ ] `kubectl get nodes` でノードが `Ready` 状態
- [ ] `aws eks describe-cluster --name eks-chaos-cell-prod` が成功
- [ ] VPCのプライベートサブネットに `karpenter.sh/discovery` タグが付いている

---

## 次フェーズへの引き継ぎ情報

Phase 2（Karpenter）では以下が前提となる。

- EKSクラスター名: `eks-chaos-cell-prod`
- OIDCプロバイダーARN: `module.eks.oidc_provider_arn`
- プライベートサブネット（AZ-a）ID: `module.vpc.private_subnet_ids_by_az["az-a"]`
- プライベートサブネット（AZ-c）ID: `module.vpc.private_subnet_ids_by_az["az-c"]`
- ノードセキュリティグループID: `module.eks.nodes_security_group_id`
- システムノードのラベル: `node.kubernetes.io/purpose=system`