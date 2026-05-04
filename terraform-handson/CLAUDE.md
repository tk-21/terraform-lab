# Terraform AWS ハンズオン — CLAUDE.md

## プロジェクト概要

AWS インフラを Terraform で段階的に構築する初級〜中級ハンズオンです。
VPC → EC2 → RDS → ALB+ASG の順に進めます。

---

## ディレクトリ構成

```
terraform-handson/
├── CLAUDE.md
├── .gitignore
├── prompts/
│   ├── 01_vpc.md
│   ├── 02_ec2.md
│   ├── 03_rds.md
│   └── 04_alb.md
├── 01_vpc/
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
├── 02_ec2/
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
├── 03_rds/
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
└── 04_alb/
    ├── main.tf
    ├── variables.tf
    └── outputs.tf
```

---

## コーディング規約（必ず守ること）

| 項目 | ルール |
|------|--------|
| Terraform バージョン | `>= 1.5` |
| AWS プロバイダー | `>= 5.0` |
| リソース名プレフィックス | `handson-` |
| インデント | スペース 2つ |
| 変数 | 全て `variables.tf` に集約、`description` 必須、ハードコード禁止 |
| 出力値 | 全て `outputs.tf` に集約、`description` 必須 |
| 必須タグ | 全リソースに `Environment = "handson"`, `ManagedBy = "terraform"` |
| locals | 共通タグは `local.common_tags` で定義し `merge()` で使う |

---

## コスト管理ルール（重要）

- EC2 は **t3.micro** のみ（Free Tier 対象）
- RDS は **db.t3.micro**、Single-AZ のみ
- NAT Gateway は **作成しない**
- 作業終了後は **必ず `terraform destroy`** を実行すること

---

## 基本操作

```bash
terraform init          # 初期化（初回のみ）
terraform fmt           # コード整形
terraform validate      # 構文チェック
terraform plan          # 差分確認（apply 前に必ず実行）
terraform apply         # 適用
terraform destroy       # 削除（作業後は必ず実行）
terraform output        # 出力値一覧
terraform output -raw vpc_id   # 特定の出力値を取得
```

---

## Step 間の値の受け渡し

各 Step は独立した tfstate を持つため、前 Step の output を変数に渡す。

```bash
VPC_ID=$(cd ../01_vpc && terraform output -raw vpc_id)
PUB_SUBNET=$(cd ../01_vpc && terraform output -json public_subnet_ids | jq -r '.[0]')
PUB_SUBNETS=$(cd ../01_vpc && terraform output -json public_subnet_ids | jq -c '.')
PRIV_SUBNETS=$(cd ../01_vpc && terraform output -json private_subnet_ids | jq -c '.')
EC2_SG=$(cd ../02_ec2 && terraform output -raw security_group_id)

# 02_ec2 の apply 例
cd ../02_ec2
terraform apply \
  -var="vpc_id=$VPC_ID" \
  -var="public_subnet_id=$PUB_SUBNET"
```

---

## Claude Code への作業依頼ルール

1. ファイルを作成・編集する前に対象ファイルと変更内容を確認すること
2. `terraform plan` の結果を必ずユーザーに提示してから `apply` すること
3. エラー発生時は原因を日本語で説明してから修正案を提示すること
4. 変数を追加した場合は `variables.tf` への反映も同時に行うこと
5. リソースを追加した場合は `outputs.tf` への追加も検討すること
