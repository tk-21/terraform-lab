# ✅Phase 1: Terraform実装

> **このフェーズの問い**:
> 「自分がTerraformを"当たり前"に使うとき、何を考えずに選んでいるか？」
> 実装しながら、その「当たり前」を言語化すること。

## 前提確認

- CLAUDE.mdを読み、命名規則・禁止パターンを把握していること
- infra-spec.mdの「共通インフラ仕様」を正解定義として使用すること
- AWSリージョン: ap-northeast-1
- Terraformバージョン: >= 1.6.0

---

## タスク

`terraform/` ディレクトリに以下のファイル構造でTerraformコードを生成すること。

```
terraform/
├── main.tf           # provider設定
├── variables.tf      # 変数定義
├── locals.tf         # ローカル値（タグ等）
├── vpc.tf            # VPC / Subnet / IGW / Route Table
├── security_group.tf # Security Group
├── ec2.tf            # EC2 / IAM Role / Instance Profile
├── s3.tf             # S3バケット
├── monitoring.tf     # AWS Budgets / CloudWatch Alarm / SNS
├── outputs.tf        # 出力値
├── terraform.tfvars  # 変数値（account_idは変数化）
└── backend.tf        # S3バックエンド設定（バケット名はコメントで案内）
```

---

## 実装要件

### provider / backend

```hcl
# backend.tf
# S3バックエンド（バケットは事前に手動作成が必要）
# バケット名: itl-tfstate-{AWSアカウントID}
# DynamoDBテーブル名: itl-tfstate-lock
```

### 変数設計

以下の変数を `variables.tf` に定義すること:

```hcl
variable "aws_account_id" {
  description = "AWSアカウントID（S3バケット名のサフィックスに使用）"
  type        = string
}

variable "notification_email" {
  description = "Budgets・CloudWatchアラート通知先メールアドレス"
  type        = string
}
```

### locals設計

```hcl
locals {
  # プロジェクト共通タグ（全リソースに付与）
  common_tags = {
    Project   = "iac-trilogy-lab"
    Env       = "dev"
    ManagedBy = "terraform"
    CostOwner = "takuya"
  }

  # 命名プレフィックス
  prefix = "itl-dev"
}
```

### VPC要件

- `aws_vpc`: enable_dns_hostnames = true, enable_dns_support = true
- `aws_subnet`: map_public_ip_on_launch = true（EC2がパブリックIPを持てるよう）
- `aws_internet_gateway`: VPCにアタッチ
- `aws_route_table` + `aws_route_table_association`: 0.0.0.0/0 → IGW

### EC2要件

- AMI: `data "aws_ami"` でAmazon Linux 2023 arm64を動的取得すること
- `metadata_options`: `http_tokens = "required"`（IMDSv2強制）
- `iam_instance_profile`: SSMポリシー付きロールをアタッチ
- user_data: SSMエージェント起動確認用のスクリプト（任意）

```hcl
# AMI動的取得の例（arm64 / Amazon Linux 2023）
data "aws_ami" "al2023_arm64" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-arm64"]
  }
}
```

### IAM要件

```hcl
# EC2用IAMロール（最小権限）
# AmazonSSMManagedInstanceCore のみアタッチ
# S3バケットへの読み書き権限をインラインポリシーで追加
```

### S3要件

- `aws_s3_bucket_versioning`: enabled
- `aws_s3_bucket_public_access_block`: 全ブロック
- `aws_s3_bucket_server_side_encryption_configuration`: AES256

### 監視要件

```hcl
# SNSトピック → メール購読（notification_email変数を使用）
# AWS Budgets: COST タイプ、MONTHLY、$10アラート
# CloudWatch Alarm: AWS/EC2 CPUUtilization > 80, period=300, 2連続
```

---

## コーディング規則

1. **全リソースに `tags = local.common_tags` を付与**
2. **全リソースに日本語インラインコメントで「なぜこの設定か」を記述**
3. **`count` は使用禁止**（`for_each` を使うこと）
4. **ハードコード禁止**（CIDR以外は変数またはlocalsで管理）

---

## 実装後の自己確認チェック（Claude Codeが実施）

```bash
# 構文チェック
terraform fmt -check
terraform validate

# planを出力してファイルに保存
terraform plan -out=tfplan.binary
terraform show -json tfplan.binary > tfplan.json

# planにSSH(22)が含まれていないことを確認
grep -i "port.*22\|22.*port\|ingress.*22" tfplan.json && echo "❌ SSH検出" || echo "✅ SSHなし"
```

---

## 完了後にやること（手動）

1. `terraform apply` を実行
2. EC2にSSM接続できることを確認
3. infra-spec.mdの「検証完了条件」をチェック
4. **「このTerraformコードをなぜこう書いたか」を15分間口頭で説明できるか確認**
5. Phase 2に進む前に `terraform destroy` は**しない**（CDK実装と比較するため並行稼働）

---

## Phase 1 完了の定義

- [ ] `terraform apply` が成功する
- [ ] SSM接続確認済み
- [ ] コスト監視設定済み
- [ ] 禁止パターン（SSH/アクセスキー/NAT/IMDSv1）が含まれていない
- [ ] 全リソースに日本語コメントがある
- [ ] `adr/adr-001-terraform-baseline.md` に「Terraformを選ぶとき自分が考えていること」を自分の言葉で書いた