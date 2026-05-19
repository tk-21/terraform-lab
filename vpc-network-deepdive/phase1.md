# Phase 1: Hub-Spoke VPC基盤構築

## このフェーズのゴール

Hub VPC（`10.0.0.0/16`）とSpoke-Prod（`10.1.0.0/16`）、Spoke-Dev（`10.2.0.0/16`）の
3 VPCを構築し、各VPCのサブネット・ルートテーブル・セキュリティグループを設計する。

**このフェーズ完了時点で説明できるようになること:**
- なぜCIDRを `/16` で設計するのか（拡張性の観点）
- public/privateサブネットを分ける意味
- `enable_dns_hostnames = true` がInterface Endpointに必要な理由
- マルチAZ配置の必要性（HA設計の基本）

---

## 作成するファイル一覧

```
modules/
└── vpc/
    ├── main.tf
    ├── variables.tf
    └── outputs.tf

envs/
├── hub/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars
├── spoke_prod/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars
└── spoke_dev/
    ├── main.tf
    ├── variables.tf
    ├── outputs.tf
    └── terraform.tfvars

docs/
├── architecture.md        # Phase1時点の構成図（Mermaid）
└── adr/
    └── ADR-001_cidr_design.md
```

---

## modules/vpc/main.tf

VPC・サブネット・ルートテーブルを汎用的に作成するモジュール。
Hub/Spoke共通で使いまわすため、tier（public/private）を `for_each` で制御する。

```hcl
# =============================================================
# VPC本体
# enable_dns_hostnames: Interface Endpointの名前解決に必須
# enable_dns_support: VPC内DNSリゾルバ（169.254.169.253）を有効化
# =============================================================
resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, {
    Name = "${var.prefix}-vpc"
  })
}

# =============================================================
# サブネット
# var.subnets = { "private-1a" = { cidr = "...", az = "..." }, ... }
# for_eachで複数サブネットを一括作成
# =============================================================
resource "aws_subnet" "this" {
  for_each = var.subnets

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az

  # SpokeのプライベートサブネットではパブリックIP不要
  map_public_ip_on_launch = lookup(each.value, "public", false)

  tags = merge(var.tags, {
    Name = "${var.prefix}-${each.key}-subnet"
    Tier = split("-", each.key)[0]  # "private" or "public"
  })
}

# =============================================================
# Internet Gateway
# Hubのpublicサブネット用（現フェーズでは未アタッチだが将来拡張用）
# var.create_igw = false の場合はスキップ
# =============================================================
resource "aws_internet_gateway" "this" {
  count  = var.create_igw ? 1 : 0
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.prefix}-igw"
  })
}

# =============================================================
# ルートテーブル（tierごとに1つ）
# public-rtb / private-rtb を分離することでアクセス制御を明確化
# =============================================================
resource "aws_route_table" "this" {
  for_each = toset(distinct([
    for k, v in var.subnets : split("-", k)[0]  # "private" or "public"
  ]))

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.prefix}-${each.key}-rtb"
  })
}

# ルートテーブルとサブネットのアソシエーション
resource "aws_route_table_association" "this" {
  for_each = var.subnets

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.this[split("-", each.key)[0]].id
}

# IGWへのデフォルトルート（publicルートテーブルのみ）
resource "aws_route" "igw" {
  count = var.create_igw ? 1 : 0

  route_table_id         = aws_route_table.this["public"].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id
}

# =============================================================
# デフォルトセキュリティグループ
# デフォルトSGのルールを全削除（セキュリティベストプラクティス）
# =============================================================
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  # ingressもegressも定義しない = 全通信を暗黙拒否
  tags = merge(var.tags, {
    Name = "${var.prefix}-default-sg-DO-NOT-USE"
  })
}
```

## modules/vpc/variables.tf

```hcl
variable "prefix" {
  description = "リソース名プレフィックス（例: vnd-hub）"
  type        = string
}

variable "cidr_block" {
  description = "VPCのCIDRブロック"
  type        = string
}

variable "subnets" {
  description = <<-EOT
    サブネット定義マップ。キーはサブネット識別子。
    例: { "private-1a" = { cidr = "10.0.10.0/24", az = "ap-northeast-1a" } }
  EOT
  type = map(object({
    cidr   = string
    az     = string
    public = optional(bool, false)
  }))
}

variable "create_igw" {
  description = "Internet Gatewayを作成するか（Hubのみtrue）"
  type        = bool
  default     = false
}

variable "tags" {
  description = "全リソースに付与する共通タグ"
  type        = map(string)
  default     = {}
}
```

## modules/vpc/outputs.tf

```hcl
output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDRブロック（Peeringルート設定で使用）"
  value       = aws_vpc.this.cidr_block
}

output "subnet_ids" {
  description = "サブネットIDマップ: { 'private-1a' = 'subnet-xxx' }"
  value       = { for k, v in aws_subnet.this : k => v.id }
}

output "route_table_ids" {
  description = "ルートテーブルIDマップ: { 'private' = 'rtb-xxx' }"
  value       = { for k, v in aws_route_table.this : k => v.id }
}

output "private_subnet_ids" {
  description = "privateサブネットIDのリスト（Endpointのsubnet_ids引数で使用）"
  value = [
    for k, v in aws_subnet.this : v.id
    if startswith(k, "private")
  ]
}
```

---

## envs/hub/main.tf

```hcl
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1"

  default_tags {
    tags = local.common_tags
  }
}

locals {
  env    = "hub"
  prefix = "vnd-${local.env}"

  # 全リソースに付与する共通タグ
  common_tags = {
    Project     = "vpc-network-deepdive"
    ManagedBy   = "terraform"
    Environment = local.env
    CostTarget  = "learning"
  }
}

module "vpc" {
  source = "../../modules/vpc"

  prefix     = local.prefix
  cidr_block = "10.0.0.0/16"
  create_igw = true  # HubはIGWを持つ（Spoke向けサービス公開の将来拡張用）

  subnets = {
    # 今回は未使用だが、将来のALB/Bastion配置を想定して確保
    "public-1a" = { cidr = "10.0.0.0/24", az = "ap-northeast-1a", public = true }
    "public-1c" = { cidr = "10.0.1.0/24", az = "ap-northeast-1c", public = true }

    # Interface EndpointとNLBを配置するプライベートサブネット
    "private-1a" = { cidr = "10.0.10.0/24", az = "ap-northeast-1a" }
    "private-1c" = { cidr = "10.0.11.0/24", az = "ap-northeast-1c" }
  }

  tags = local.common_tags
}
```

## envs/hub/outputs.tf

```hcl
output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr" {
  value = module.vpc.vpc_cidr
}

output "subnet_ids" {
  value = module.vpc.subnet_ids
}

output "route_table_ids" {
  value = module.vpc.route_table_ids
}

output "private_subnet_ids" {
  value = module.vpc.private_subnet_ids
}
```

---

## envs/spoke_prod/main.tf

```hcl
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1"

  default_tags {
    tags = local.common_tags
  }
}

locals {
  env    = "prod"
  prefix = "vnd-${local.env}"

  common_tags = {
    Project     = "vpc-network-deepdive"
    ManagedBy   = "terraform"
    Environment = local.env
    CostTarget  = "learning"
  }
}

module "vpc" {
  source = "../../modules/vpc"

  prefix     = local.prefix
  cidr_block = "10.1.0.0/16"
  create_igw = false  # SpokeはIGW不要（NAT GWも不使用）

  subnets = {
    # Spokeはプライベートサブネットのみ
    # インターネットアクセスはInterface Endpoint経由（SSM等）
    "private-1a" = { cidr = "10.1.10.0/24", az = "ap-northeast-1a" }
    "private-1c" = { cidr = "10.1.11.0/24", az = "ap-northeast-1c" }
  }

  tags = local.common_tags
}
```

## envs/spoke_prod/outputs.tf

```hcl
output "vpc_id" { value = module.vpc.vpc_id }
output "vpc_cidr" { value = module.vpc.vpc_cidr }
output "subnet_ids" { value = module.vpc.subnet_ids }
output "route_table_ids" { value = module.vpc.route_table_ids }
output "private_subnet_ids" { value = module.vpc.private_subnet_ids }
```

---

## envs/spoke_dev/main.tf

spoke_prod/main.tf と同一構造。以下の差分のみ変更：

```hcl
# spoke_prodとの差分のみ記載
locals {
  env        = "dev"
  prefix     = "vnd-${local.env}"
}

module "vpc" {
  # ...
  cidr_block = "10.2.0.0/16"  # devは10.2.x.x

  subnets = {
    "private-1a" = { cidr = "10.2.10.0/24", az = "ap-northeast-1a" }
    "private-1c" = { cidr = "10.2.11.0/24", az = "ap-northeast-1c" }
  }
}
```

---

## docs/adr/ADR-001_cidr_design.md

```markdown
# ADR-001: CIDR設計の判断根拠

## ステータス
採用

## コンテキスト
Hub-Spoke構成で3つのVPCを設計する。
将来のサブネット追加やVPC増設に耐えられる設計が必要。

## 決定

| VPC | CIDR |
|---|---|
| Hub | 10.0.0.0/16 |
| Spoke-Prod | 10.1.0.0/16 |
| Spoke-Dev | 10.2.0.0/16 |

## 理由

1. **/16を選択した理由**
   - /16は65,534のIPアドレスを提供
   - サブネットを /24（256IP）で切ると254サブネット作成可能
   - 将来のAZ追加・tier追加に余裕がある

2. **第2オクテットでVPCを分離した理由**
   - VPC間でCIDRが重複するとPeeringが設定不可
   - 10.0.x.x = Hub, 10.1.x.x = Prod, 10.2.x.x = Dev と直感的に識別可能
   - Transit GatewayへのマイグレーションやRoute Summarizationが容易

3. **サブネットを /24 にした理由**
   - AWSは各サブネットで5IPを予約（最初の4つ + 最後の1つ）
   - /24 = 251使用可能IP = EC2・ENI配置に十分
   - /28（11IP）はInterface Endpoint専用サブネットで使われる手法だが
     今回は学習シンプルさを優先して /24 に統一

## 却下した選択肢

- **10.0.0.0/8 を3分割**: オーバースペック、運用複雑
- **172.16.0.0/12 系**: AWSデフォルトVPCと重複リスク
```

---

## docs/architecture.md（Phase1時点）

```markdown
# アーキテクチャ図 — Phase 1

## VPC構成

\`\`\`mermaid
graph TB
  subgraph Hub["Hub VPC (10.0.0.0/16)"]
    h_pub1["public-1a\n10.0.0.0/24"]
    h_pub2["public-1c\n10.0.1.0/24"]
    h_prv1["private-1a\n10.0.10.0/24"]
    h_prv2["private-1c\n10.0.11.0/24"]
    IGW["Internet Gateway"]
  end

  subgraph Prod["Spoke-Prod VPC (10.1.0.0/16)"]
    p_prv1["private-1a\n10.1.10.0/24"]
    p_prv2["private-1c\n10.1.11.0/24"]
  end

  subgraph Dev["Spoke-Dev VPC (10.2.0.0/16)"]
    d_prv1["private-1a\n10.2.10.0/24"]
    d_prv2["private-1c\n10.2.11.0/24"]
  end

  IGW --- Hub
\`\`\`

Phase 2でVPC Peeringを追加予定。
```

---

## 実行手順

```bash
# 1. Hubから順番に apply
cd envs/hub
terraform init
terraform plan
terraform apply

cd ../spoke_prod
terraform init
terraform plan
terraform apply

cd ../spoke_dev
terraform init
terraform plan
terraform apply
```

## 検証ポイント

```bash
# VPC一覧確認
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=vpc-network-deepdive" \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output table

# サブネット一覧確認
aws ec2 describe-subnets \
  --filters "Name=tag:Project,Values=vpc-network-deepdive" \
  --query 'Subnets[].{ID:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output table
```

## Phase 1 完了チェックリスト

- [ ] Hub VPCが `10.0.0.0/16` で作成されている
- [ ] Spoke-Prod VPCが `10.1.0.0/16` で作成されている
- [ ] Spoke-Dev VPCが `10.2.0.0/16` で作成されている
- [ ] 各VPCに private サブネットが1a・1cの2AZで作成されている
- [ ] デフォルトSGのルールが全削除されている
- [ ] 口頭説明: 「なぜHub-Spoke構成にするのか」を3分で説明できる