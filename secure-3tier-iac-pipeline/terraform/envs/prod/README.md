# prod 環境 — 操作手順

## 前提条件

- AWS CLI v2 設定済み (`aws configure` または IAM Identity Center)
- Terraform >= 1.7
- 権限: VPC/EC2/RDS/IAM/S3/DynamoDB/CloudWatch の作成権限

---

## 1. bootstrap.sh — tfstate バックエンド初期化

```bash
cd /path/to/secure-3tier-iac-pipeline
bash scripts/bootstrap.sh
```

出力されたバケット名 (`s3t-prod-tfstate-{AWSアカウントID}`) を
`terraform/envs/prod/backend.tf` の `bucket` フィールドに設定する。

```hcl
# backend.tf
terraform {
  backend "s3" {
    bucket         = "s3t-prod-tfstate-123456789012"   # ← 実際のIDに変更
    key            = "prod/terraform.tfstate"
    region         = "ap-northeast-1"
    encrypt        = true
    dynamodb_table = "s3t-prod-tfstate-lock"
  }
}
```

また `terraform.tfvars` の `aws_account_id` も実際の値に更新する。

---

## 2. terraform init → plan → apply

```bash
cd terraform/envs/prod

# バックエンド初期化
terraform init

# 差分確認 (変更なし = 正常)
terraform plan -var-file=terraform.tfvars

# インフラ構築
terraform apply -var-file=terraform.tfvars
```

> **NAT Gateway の料金に注意**
> 3 AZ 構成では NAT Gateway が 3 台作成されます。
> 固定費 約 $130/台/月 + データ転送料 $0.062/GB が発生します。
> 検証後は速やかに `terraform destroy` してください。

---

## 3. VPC Flow Logs 確認

### CloudWatch Logs コンソール

ロググループ: `/aws/vpc/flowlogs/s3t-prod`

### Logs Insights クエリ例

**拒否されたトラフィックを確認する**
```
fields @timestamp, srcAddr, dstAddr, srcPort, dstPort, protocol, action
| filter action = "REJECT"
| sort @timestamp desc
| limit 50
```

**特定IPからのアクセスを追跡する**
```
fields @timestamp, srcAddr, dstAddr, dstPort, action
| filter srcAddr = "203.0.113.0"
| sort @timestamp desc
```

**高頻度接続元ランキング**
```
fields srcAddr
| stats count(*) as connections by srcAddr
| sort connections desc
| limit 20
```

---

## 4. よくあるエラーと対処法

### `Error: creating VPC: InvalidVpc.Range`
- VPC CIDR が既存 VPC と重複している。`172.16.0.0/16` が使用中の場合は `variables.tf` を変更する。

### `Error: Backend initialization required, please run "terraform init"`
- `backend.tf` を変更した後は `terraform init -reconfigure` を実行する。

### `Error: NoCredentialProviders`
- `aws sts get-caller-identity` で認証確認。SSO の場合は `aws sso login` を実行。

### `Error: error creating Flow Log: InvalidParameter`
- IAM Role のポリシーが CloudWatch Logs グループ ARN と一致しているか確認する。
- Terraform apply を再実行すると依存関係が解決されることがある。

### NAT Gateway の削除が遅い
- `terraform destroy` で NAT Gateway 削除には数分かかる。
- EIP は自動解放されるが、ポータルで未解放の EIP が残る場合は手動削除する。
