# Terraform AWS ハンズオン

AWS の主要インフラを Terraform で段階的に構築する初級〜中級ハンズオンです。
**コードを読む → 動かす → 改造する** の3ステップで IaC の基礎を身につけます。

---

## 全体構成図

```
Internet
    │
    ▼
┌─────────────────────────────────────────────┐
│ VPC (10.0.0.0/16)                           │
│                                             │
│  ┌──────────────┐  ┌──────────────┐        │
│  │ Public       │  │ Public       │        │
│  │ Subnet AZ-a  │  │ Subnet AZ-c  │        │
│  │ 10.0.1.0/24  │  │ 10.0.2.0/24  │        │
│  │              │  │              │        │
│  │  [Step2 EC2] │  │  [Step4 ASG] │        │
│  │  [Step4 ALB] │  │  [Step4 ALB] │        │
│  └──────────────┘  └──────────────┘        │
│                                             │
│  ┌──────────────┐  ┌──────────────┐        │
│  │ Private      │  │ Private      │        │
│  │ Subnet AZ-a  │  │ Subnet AZ-c  │        │
│  │ 10.0.11.0/24 │  │ 10.0.12.0/24 │        │
│  │              │  │              │        │
│  │  [Step3 RDS] │  │  [Step3 RDS] │        │
│  └──────────────┘  └──────────────┘        │
└─────────────────────────────────────────────┘
```

---

## ハンズオン進行マップ

| Step | 内容 | 主な学習ポイント | 目安時間 |
|------|------|----------------|---------|
| Step 1 | VPC | count / data / locals / ルートテーブル | 30分 |
| Step 2 | EC2 | Security Group / AMI / UserData / EIP | 45分 |
| Step 3 | RDS | DB Subnet Group / sensitive変数 / パラメータグループ | 45分 |
| Step 4 | ALB+ASG | Target Group / Launch Template / スケーリング | 60分 |
| Step 5 | モジュール設計 | for_each(map) / dynamic / lifecycle / リモートバックエンド | 90分 |

---

## 前提条件

```bash
# バージョン確認
terraform version   # >= 1.5
aws --version       # >= 2.0
jq --version        # 任意（Step間の値受け渡しに使用）

# AWS 認証確認
aws sts get-caller-identity
```

---

## ディレクトリ構成

```
terraform-handson/
├── CLAUDE.md                    ← Claude Code の指示書（規約・ルール）
├── README.md                    ← このファイル
├── .gitignore                   ← state・tfvars を除外
├── prompts/
│   ├── 01_vpc.md                ← Step1 プロンプト集（理解確認・改造・トラブル対応）
│   ├── 02_ec2.md                ← Step2 プロンプト集
│   ├── 03_rds.md                ← Step3 プロンプト集
│   └── 04_alb.md                ← Step4 プロンプト集
├── 01_vpc/
│   ├── main.tf                  ← VPC / Subnet / IGW / RouteTable
│   ├── variables.tf
│   └── outputs.tf
├── 02_ec2/
│   ├── main.tf                  ← Security Group / EC2 / EIP
│   ├── variables.tf
│   └── outputs.tf
├── 03_rds/
│   ├── main.tf                  ← DB Subnet Group / RDS / Parameter Group
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example ← パスワードの設定例
├── 04_alb/
│   ├── main.tf                  ← ALB / Target Group / Launch Template / ASG
│   ├── variables.tf
│   └── outputs.tf
└── 05_modules/                  ← Step5: モジュール設計（中〜上級）
    ├── README.md                ← Step5 の詳細な解説
    ├── bootstrap/               ← tfstate用 S3 + DynamoDB（初回のみ apply）
    ├── modules/
    │   ├── vpc/                 ← 再利用可能なVPCモジュール
    │   └── ec2/                 ← 再利用可能なEC2モジュール
    └── environments/dev/        ← モジュールを組み合わせた環境定義
```

---

## 使い方

### 1. Claude Code を起動する

```bash
cd terraform-handson
claude  # このディレクトリで起動すると CLAUDE.md を自動認識する
```

### 2. prompts/ のプロンプトを使って進める

各 Step のプロンプトファイルを開き、上から順番に Claude Code に貼り付けるだけ。

```
🟢 初期構築  → まずここから。init / plan / apply を実行
🔵 理解確認  → コードを読んで動作原理を理解する
🟡 改造      → 機能追加・設定変更で応用力を養う
🔴 トラブル  → エラーが出たときに使う
```

### 3. Step 間の値の受け渡し

各 Step は独立した tfstate を持つため、前 Step の output を次 Step に渡します。
prompts/ 内に具体的なコマンドが記載されています。

---

## コスト目安

| リソース | 料金（東京リージョン） |
|---------|----------------------|
| EC2 t3.micro | Free Tier 対象（750時間/月） |
| RDS db.t3.micro | Free Tier 対象（750時間/月） |
| ALB | 約 $0.025/時間 ≒ 約 $0.6/日 |
| EIP（EC2 に未アタッチの場合） | $0.005/時間 |

> ⚠️ **作業終了後は必ず `terraform destroy` を実行してください**
> 特に ALB は放置するとコストが発生します。

---

## 終了時のクリーンアップ

依存関係があるため **逆順で destroy** します。

```bash
# Step 4 から逆順に削除
cd 04_alb && terraform destroy -auto-approve

cd ../03_rds
VPC_ID=$(cd ../01_vpc && terraform output -raw vpc_id)
terraform destroy \
  -var="vpc_id=$VPC_ID" \
  -var='private_subnet_ids=["dummy"]' \
  -var="ec2_security_group_id=dummy" \
  -var="db_password=dummy" \
  -auto-approve

cd ../02_ec2
terraform destroy \
  -var="vpc_id=$VPC_ID" \
  -var="public_subnet_id=dummy" \
  -auto-approve

cd ../01_vpc && terraform destroy -auto-approve
```

---

## よくある質問

**Q. terraform init が失敗する**
A. AWS 認証が設定されているか確認してください: `aws sts get-caller-identity`

**Q. RDS の apply に 10 分以上かかる**
A. RDS の作成は通常 5〜10 分かかります。正常です。待機中に 🔵 の理解確認を進めてください。

**Q. ALB の URL にアクセスしてもエラーになる**
A. ALB の作成後、EC2 のヘルスチェックが `healthy` になるまで 1〜2 分かかります。しばらく待ってから再アクセスしてください。

**Q. terraform.tfstate を誤って削除してしまった**
A. `terraform import` コマンドで AWS 上のリソースを再インポートできます。Claude Code に「terraform.tfstate を復元したい」と伝えてください。
