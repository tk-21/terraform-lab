# Phase 1: VPCモジュール + ベースネットワーク構築

## このフェーズの目的
4つのVPC（Hub / Spoke-A / Spoke-B / Inspection）と、
Transit Gatewayアタッチメント用のサブネットを作成する。
後続フェーズで使い回せる汎用VPCモジュールを設計することが重要。

## 前提条件
- AWS CLI設定済み（ap-northeast-1）
- Terraform v1.7以上インストール済み
- `terraform -chdir=envs/ap-northeast-1 init` が通ること

---

## タスク一覧

### 1. ディレクトリ骨格の作成

以下の構造でファイルを作成すること:

```
tgw-multi-vpc-lab/
├── modules/
│   └── vpc/
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
└── envs/
    └── ap-northeast-1/
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        └── terraform.tfvars
```

### 2. `modules/vpc` の実装

**variables.tf** で受け付ける変数:
```hcl
variable "vpc_name"         # VPC識別名（例: "hub", "spoke-a"）
variable "vpc_cidr"         # VPC CIDRブロック
variable "az_count"         # 使用するAZ数（デフォルト2）
variable "private_subnet_cidrs"   # プライベートサブネットCIDRのリスト
variable "tgw_subnet_cidrs"       # TGWアタッチメント専用サブネットCIDRのリスト
variable "enable_dns_hostnames"   # デフォルト true
variable "tags"                   # 追加タグ（map(string)）
```

**main.tf** で作成するリソース:
- `aws_vpc` × 1
- `aws_subnet` (private): `for_each` で `private_subnet_cidrs` をイテレート
- `aws_subnet` (tgw): `for_each` で `tgw_subnet_cidrs` をイテレート
  - TGW専用サブネットはCIDR /28で十分（ENI配置のみ）
- `aws_route_table` × 2（private用 / tgw用）
- `aws_route_table_association`（各サブネットと紐付け）
- `aws_vpc_endpoint` for SSM系 3点セット（NATGWなしでSSM接続するため）:
  - `com.amazonaws.ap-northeast-1.ssm`
  - `com.amazonaws.ap-northeast-1.ssmmessages`
  - `com.amazonaws.ap-northeast-1.ec2messages`

**コメント要件**: なぜTGW専用サブネットを分けるか、日本語でコメントを入れること

**outputs.tf** で必ずexportするもの:
```hcl
output "vpc_id"
output "private_subnet_ids"   # map(string): key=CIDR, value=subnet_id
output "tgw_subnet_ids"       # map(string): key=CIDR, value=subnet_id
output "private_route_table_ids"  # list(string)
output "tgw_route_table_id"
```

### 3. `envs/ap-northeast-1/main.tf` でモジュールを4回呼び出す

```hcl
module "hub_vpc" {
  source    = "../../modules/vpc"
  vpc_name  = "hub"
  vpc_cidr  = "10.0.0.0/16"
  private_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24"]
  tgw_subnet_cidrs     = ["10.0.11.0/28", "10.0.11.16/28"]
  # ...
}

module "spoke_a_vpc" {
  source    = "../../modules/vpc"
  vpc_name  = "spoke-a"
  vpc_cidr  = "10.1.0.0/16"
  private_subnet_cidrs = ["10.1.1.0/24", "10.1.2.0/24"]
  tgw_subnet_cidrs     = ["10.1.11.0/28", "10.1.11.16/28"]
  # ...
}

module "spoke_b_vpc" {
  source    = "../../modules/vpc"
  vpc_name  = "spoke-b"
  vpc_cidr  = "10.2.0.0/16"
  private_subnet_cidrs = ["10.2.1.0/24", "10.2.2.0/24"]
  tgw_subnet_cidrs     = ["10.2.11.0/28", "10.2.11.16/28"]
  # ...
}

module "inspection_vpc" {
  source    = "../../modules/vpc"
  vpc_name  = "inspection"
  vpc_cidr  = "10.3.0.0/16"
  private_subnet_cidrs = ["10.3.1.0/24", "10.3.2.0/24"]
  tgw_subnet_cidrs     = ["10.3.11.0/28", "10.3.11.16/28"]
  # ...
}
```

### 4. 共通タグの設定

`terraform.tfvars` で定義:
```hcl
project     = "tgw-multi-vpc-lab"
environment = "lab"
```

すべてのリソースに以下タグを付与:
```hcl
tags = {
  Project    = var.project
  Environment = var.environment
  ManagedBy  = "terraform"
}
```

### 5. `terraform apply` の実行

```bash
terraform -chdir=envs/ap-northeast-1 init
terraform -chdir=envs/ap-northeast-1 plan
terraform -chdir=envs/ap-northeast-1 apply
```

エラーがなくすべてのVPCが作成されること。

---

## 完了確認

### CLIで確認
```bash
# 4つのVPCが存在すること
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=tgw-multi-vpc-lab" \
  --query 'Vpcs[*].{ID:VpcId,CIDR:CidrBlock,Name:Tags[?Key==`Name`].Value|[0]}' \
  --output table

# TGW専用サブネットが各VPCに2つずつ（計8つ）あること
aws ec2 describe-subnets \
  --filters "Name=tag:Type,Values=tgw" \
  --query 'Subnets[*].{ID:SubnetId,CIDR:CidrBlock,VPC:VpcId}' \
  --output table
```

---

## 口頭説明チェック（15分目安）

このフェーズ完了後、以下を見ずに説明できるか確認すること:

1. **TGW専用サブネットを分ける理由は何か？**
   （ヒント: ルートテーブルの分離、トラフィック制御の粒度）

2. **`for_each` を `count` より優先する理由は何か？**
   （ヒント: リソースの削除・追加時の挙動の違い）

3. **VPCエンドポイントをどのサブネットに配置するか、なぜか？**

4. **このモジュール設計で、将来Spoke-Cを追加するとき何行変更が必要か？**

---

## 次のフェーズ
Phase 2: Transit Gateway本体 + アタッチメントの作成