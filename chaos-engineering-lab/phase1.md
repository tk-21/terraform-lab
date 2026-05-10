# ✅Phase 1 — Terraform バックエンド + VPC + セキュリティグループ

## このフェーズのゴール

以下のファイルを生成する:
1. S3/DynamoDB バックエンド設定
2. VPC モジュール（サブネット・IGW・NAT・ルートテーブル）
3. SG モジュール（ALB 用・EC2 用）
4. dev 環境の main.tf（モジュール呼び出し骨格）

---

## 前提確認

- CLAUDE.md を参照し、命名規則・タグ・リージョンを遵守すること
- `cel` プレフィックスを全リソースに付与
- コメントは日本語で設計意図を記述

---

## 生成指示

### 1. `terraform/environments/dev/terraform.tfvars`

```hcl
# プロジェクト基本設定
project     = "chaos-engineering-lab"
prefix      = "cel"
env         = "dev"
aws_region  = "ap-northeast-1"
account_id  = ""  # terraform.tfvars.local で上書き（git 管理外）

# VPC CIDR
vpc_cidr            = "10.0.0.0/16"
public_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24"]
private_subnet_cidrs = ["10.0.11.0/24", "10.0.12.0/24"]
availability_zones  = ["ap-northeast-1a", "ap-northeast-1c"]
```

### 2. `terraform/environments/dev/versions.tf`

- terraform required_version >= "1.9.0"
- aws プロバイダー ~> 5.0
- backend "s3":
  - bucket: `cel-tfstate-${var.account_id}` ※ 変数は使えないため `cel-tfstate-REPLACE_ME` と記載しコメントで説明
  - key: `chaos-engineering-lab/dev/terraform.tfstate`
  - region: `ap-northeast-1`
  - dynamodb_table: `cel-tfstate-lock`
  - encrypt: true

### 3. `terraform/modules/vpc/main.tf`

以下のリソースを生成:

```
aws_vpc                      # cel-{env}-vpc、DNS ホスト名有効化
aws_internet_gateway         # cel-{env}-igw
aws_subnet (public × 2)     # cel-{env}-public-{az}
aws_subnet (private × 2)    # cel-{env}-private-{az}
aws_eip (× 1)               # NAT GW 用（コスト削減のため 1 AZ のみ）
aws_nat_gateway (× 1)       # cel-{env}-ngw、1a サブネットに配置
aws_route_table (public)    # IGW へのデフォルトルート
aws_route_table (private)   # NAT GW へのデフォルトルート
aws_route_table_association (× 4) # 各サブネットへの関連付け
```

`terraform/modules/vpc/variables.tf`: vpc_cidr, public_subnet_cidrs, private_subnet_cidrs, availability_zones, prefix, env, tags

`terraform/modules/vpc/outputs.tf`: vpc_id, public_subnet_ids, private_subnet_ids

### 4. `terraform/modules/sg/main.tf`

**ALB 用 SG (`cel-{env}-alb-sg`)**:
- Ingress: TCP 80, 0.0.0.0/0（HTTP）
- Egress: 全許可

**EC2 用 SG (`cel-{env}-ec2-sg`)**:
- Ingress: TCP 80, source = ALB SG のみ（直接アクセス禁止）
- Ingress: TCP 443, source = ALB SG のみ（将来用）
- Egress: 全許可（SSM エンドポイント・yum リポジトリアクセスに必要）

> コメント: EC2 への SSH 開放は不要。SSM Session Manager を使用。

`terraform/modules/sg/variables.tf`: vpc_id, alb_sg_name, ec2_sg_name, prefix, env, tags
`terraform/modules/sg/outputs.tf`: alb_sg_id, ec2_sg_id

### 5. `terraform/environments/dev/main.tf`（フェーズ 1 骨格）

```hcl
# Phase 1 で有効化するモジュール
module "vpc" { ... }
module "sg"  { ... }

# Phase 2 以降はコメントアウト状態で記述しておく
# module "alb" { ... }
# module "asg" { ... }
# module "iam" { ... }
# module "fis" { ... }
```

`terraform/environments/dev/variables.tf`: 全変数定義（型・説明・デフォルト値）
`terraform/environments/dev/outputs.tf`: vpc_id, public_subnet_ids, private_subnet_ids, alb_sg_id, ec2_sg_id

---

## 完了条件

- [ ] `terraform fmt` が通るコードであること
- [ ] `terraform validate` が通る構文であること（プロバイダー接続不要）
- [ ] 全ファイルに日本語コメントあり
- [ ] `cel` プレフィックス・タグが全リソースに付与されている
- [ ] NAT GW を 1 つに絞る設計意図がコメントに記載されている

---

## 次フェーズへの引き継ぎ情報

Phase 2 開始時に必要な出力値:
- `module.vpc.vpc_id`
- `module.vpc.public_subnet_ids`
- `module.vpc.private_subnet_ids`
- `module.sg.alb_sg_id`
- `module.sg.ec2_sg_id`