# ✅Phase1: Terraform Remote Backend + VPC基盤構築

## このPhaseの目的
Terraformのremote backend (S3 + DynamoDB) をセットアップし、
3-tier VPC（Public / Private / DB subnet × 2AZ）を構築する。

## 前提確認（実行前にチェック）
- [ ] AWS CLIが設定済み (`aws sts get-caller-identity` で確認)
- [ ] Terraform >= 1.6.0 がインストール済み
- [ ] 作業ディレクトリが `terraform-ansible-aws-platform/` であること

---

## CLAUDE.mdの参照

CLAUDE.mdを必ず読み込み、以下を遵守すること:
- 命名規則（project略称: tap）
- タグ戦略（Project / Environment / ManagedBy / Role）
- VPC CIDR設計
- セキュリティ設計方針
- 禁止パターン

---

## Task 1: Remote Backend用リソース作成

### 1-1. backend用S3バケット + DynamoDBをbootstrap用Terraformで作成

`terraform/bootstrap/` ディレクトリを作成し、以下のリソースをコーディングせよ:

**S3バケット** (`tap-terraform-state-<AWSアカウントID>`):
- バージョニング: 有効
- サーバーサイド暗号化: SSE-S3
- パブリックアクセスブロック: 全項目true
- force_destroy: false（誤削除防止）

**DynamoDBテーブル** (`tap-terraform-lock`):
- パーティションキー: `LockID` (String)
- billing_mode: PAY_PER_REQUEST
- deletion_protection_enabled: true

**注意**: bootstrapディレクトリはlocalバックエンドで動かす（循環依存を避けるため）

### 1-2. backend.tf の作成

`terraform/backend.tf` に S3バックエンド設定を記述:
- bucket: 1-1で作成したバケット名
- key: `dev/terraform.tfstate`
- region: ap-northeast-1
- dynamodb_table: `tap-terraform-lock`
- encrypt: true

---

## Task 2: VPCモジュール作成

`terraform/modules/vpc/` に以下のリソースを実装せよ。

### 必須リソース

**VPC**:
- CIDR: `10.0.0.0/16`
- enable_dns_support: true
- enable_dns_hostnames: true

**Subnets** (CLAUDE.mdのCIDR設計に従う):
- Public × 2AZ: `10.0.0.0/24`, `10.0.1.0/24`
- Private × 2AZ: `10.0.10.0/24`, `10.0.11.0/24`
- DB × 2AZ: `10.0.20.0/24`, `10.0.21.0/24`（今回はEC2未配置だがSubnetは作成）

**Internet Gateway**: Public Subnetにアタッチ

**NAT Gateway**:
- ap-northeast-1a のPublic Subnetに1つ作成（コスト削減のため1AZのみ）
- Elastic IP を新規作成してアタッチ

**Route Tables**:
- Public RT: IGWへのデフォルトルート
- Private RT: NAT GWへのデフォルトルート
- DB RT: ローカルルートのみ（インターネット接続なし）

### variables.tf に定義すべき変数

```hcl
variable "project"     { type = string }
variable "environment" { type = string }
variable "vpc_cidr"    { type = string, default = "10.0.0.0/16" }
variable "azs"         { type = list(string) }
```

### outputs.tf に出力すべき値

- vpc_id
- public_subnet_ids (list)
- private_subnet_ids (list)
- db_subnet_ids (list)

---

## Task 3: environments/dev の作成

`terraform/environments/dev/` に以下を作成:

### main.tf
- terraform required_version: >= 1.6.0
- required_providers: aws ~> 5.0
- moduleブロックでvpcモジュールを呼び出す
- providerブロック: region = "ap-northeast-1", default_tagsでProject/Environment/ManagedByを設定

### variables.tf
- project: string
- environment: string

### terraform.tfvars
```hcl
project     = "terraform-ansible-platform"
environment = "dev"
```

### outputs.tf
- vpc_id
- public_subnet_ids
- private_subnet_ids

---

## Task 4: 動作確認コマンド

以下の順でコマンドを実行し、エラーがないことを確認せよ:

```bash
# Bootstrap実行（初回のみ）
cd terraform/bootstrap
terraform init
terraform apply

# VPC構築
cd ../environments/dev
terraform init
terraform validate
terraform fmt -recursive
terraform plan -out=tfplan
terraform apply tfplan
```

---

## 完了基準

- [ ] `terraform apply` が正常完了
- [ ] AWSコンソールでVPCと6つのSubnetが確認できる
- [ ] S3にtfstateが保存されている
- [ ] `terraform show` でNAT GWのElastic IPが表示される
- [ ] 全リソースにCLAUDE.md記載のタグが付与されている

---

## 日本語インラインコメント要件

全Terraformファイルの主要リソースブロックに日本語コメントを付与せよ:

```hcl
# Privateサブネット用NATゲートウェイ（コスト最適化のため1AZのみ作成）
resource "aws_nat_gateway" "main" {
  ...
}
```