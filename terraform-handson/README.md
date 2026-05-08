# Terraform AWS ハンズオン

AWS の主要インフラを Terraform で段階的に構築する初級〜中級ハンズオンです。
**コードを読む → 動かす → 改造する** の3ステップで IaC の基礎を身につけます。

実行中心で進めたい場合はこの `README.md` を、構成や設計意図まで深く理解したい場合は [ARCHITECTURE.md](./ARCHITECTURE.md) を参照してください。

---

## このハンズオンで得られること

このハンズオンを最後まで進めると、次のような力が身につきます。

- AWS の基本インフラである VPC、EC2、RDS、ALB、Auto Scaling の役割とつながりを説明できる
- Terraform で `init` `plan` `apply` `output` を使いながら、インフラを段階的に構築できる
- `variables.tf` `main.tf` `outputs.tf` に分けて Terraform コードを整理する基本がわかる
- `count` `data` `locals` `for_each` `dynamic` `lifecycle` といった重要な Terraform パターンを体験できる
- Step ごとに tfstate が分かれた構成で、前段の output を後段の input に渡す考え方が理解できる
- 最後にモジュール構成まで進むことで、「動くコード」から「再利用できる設計」へ発展させる流れを学べる

特に、単にコマンドを実行して終わるのではなく、「なぜこの構成にするのか」「なぜこの書き方にするのか」を確認しながら進めることで、実務でも応用しやすい理解につながります。

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

## ハンズオン実行手順

このハンズオンは、次の順番で進めるとスムーズです。

1. `01_vpc/` でネットワークを作る
2. `02_ec2/` で Web サーバーを 1 台立てる
3. `03_rds/` でプライベート DB を作る
4. `04_alb/` で ALB + ASG を構築する
5. `05_modules/` でモジュール化された構成を体験する

Step 1〜4 は独立した tfstate を持つため、前の Step の `output` を次の Step の `-var` に渡します。
Step 5 は別系統の発展編で、モジュール化とリモートバックエンドを扱います。

「なぜこの順序なのか」「各 Step が全体構成のどこに位置するのか」を先に把握したい場合は、先に [ARCHITECTURE.md](./ARCHITECTURE.md) の `2. 全体像` と `11. Step 1〜4 の値受け渡し構造` を読むのがおすすめです。

---

## 実行前チェック

最初に、ローカル環境と AWS 認証を確認します。

```bash
cd terraform-handson

terraform version
aws --version
jq --version
aws sts get-caller-identity
```

確認ポイント:

- `terraform version` が `>= 1.5`
- `aws sts get-caller-identity` が成功する
- 東京リージョン `ap-northeast-1` を利用できる

`jq` は必須ではありませんが、Step 間の値受け渡しで使うため、入っていると進めやすいです。

---

## Claude Code を使う場合の進め方

このリポジトリは Claude Code と一緒に進めやすいように `prompts/` を用意しています。

```bash
cd terraform-handson
claude
```

各 Step のプロンプトファイルを上から順に使います。

```text
prompts/01_vpc.md
prompts/02_ec2.md
prompts/03_rds.md
prompts/04_alb.md
```

プロンプトの意味:

- `🟢 初期構築`: `init` / `plan` / `apply` と動作確認
- `🔵 理解確認`: コードを読んで仕組みを理解する
- `🟡 改造`: 設定変更や機能追加で応用する
- `🔴 トラブル`: エラー時に原因を特定する

もちろん、Claude Code を使わずに以下の手順だけで手動実行しても進められます。

---

## Step 1: VPC を構築する

この Step では、以降の全 Step の土台になるネットワークを作成します。

作成される主なリソース:

- VPC
- Public Subnet x 2
- Private Subnet x 2
- Internet Gateway
- Public / Private Route Table

### 実行コマンド

```bash
cd 01_vpc
terraform init
terraform fmt
terraform validate
terraform plan
```

`plan` で次のようなリソースが作成予定であることを確認します。

- `aws_vpc.main`
- `aws_internet_gateway.main`
- `aws_subnet.public[0]`, `aws_subnet.public[1]`
- `aws_subnet.private[0]`, `aws_subnet.private[1]`
- `aws_route_table.public`
- `aws_route_table.private`

問題なければ適用します。

```bash
terraform apply
```

### 完了後の確認

```bash
terraform output
terraform output -raw vpc_id
terraform output -json public_subnet_ids
terraform output -json private_subnet_ids
```

ここで確認したいこと:

- `vpc_id` が出力される
- パブリックサブネット ID が 2 つある
- プライベートサブネット ID が 2 つある

この出力値は Step 2〜4 で使います。

---

## Step 2: EC2 を構築する

この Step では、VPC 内のパブリックサブネットに Web サーバー EC2 を 1 台作成します。

作成される主なリソース:

- Security Group
- EC2 インスタンス
- Elastic IP

### Step 1 の出力値を取得する

`02_ec2/` は `01_vpc/` の output を入力に使います。

```bash
cd ../02_ec2

VPC_ID=$(cd ../01_vpc && terraform output -raw vpc_id)
SUBNET_ID=$(cd ../01_vpc && terraform output -json public_subnet_ids | jq -r '.[0]')
```

### 実行コマンド

```bash
terraform init
terraform fmt
terraform validate
terraform plan \
  -var="vpc_id=$VPC_ID" \
  -var="public_subnet_id=$SUBNET_ID"
```

問題なければ適用します。

```bash
terraform apply \
  -var="vpc_id=$VPC_ID" \
  -var="public_subnet_id=$SUBNET_ID"
```

### 完了後の確認

```bash
terraform output
terraform output -raw web_url
```

ブラウザまたは `curl` でアクセスします。

```bash
curl $(terraform output -raw web_url)
```

確認ポイント:

- Apache の HTML が返る
- Instance ID や AZ が表示される
- `public_ip` が固定 IP として出力される

表示されない場合は次を確認します。

- `01_vpc` のパブリックサブネットに IGW ルートがあるか
- EC2 の Security Group で 80 番が開いているか
- UserData が正常に動作したか

---

## Step 3: RDS を構築する

この Step では、プライベートサブネット内に MySQL RDS を作成します。

作成される主なリソース:

- DB Subnet Group
- RDS Security Group
- DB Parameter Group
- RDS Instance

### `terraform.tfvars` を作る

RDS パスワードはコマンド直書きではなく、`terraform.tfvars` を使うのが分かりやすく安全です。

```bash
cd ../03_rds
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars` を開き、`db_password` を設定します。

例:

```hcl
db_password = "Handson1234!"
```

注意:

- `terraform.tfvars` は Git に含めない
- 8 文字以上で、英数字記号を含むパスワードにする

### Step 1 / Step 2 の出力値を取得する

```bash
VPC_ID=$(cd ../01_vpc && terraform output -raw vpc_id)
PRIV_SUBNETS=$(cd ../01_vpc && terraform output -json private_subnet_ids | jq -c '.')
EC2_SG=$(cd ../02_ec2 && terraform output -raw security_group_id)
```

### 実行コマンド

```bash
terraform init
terraform fmt
terraform validate
terraform plan \
  -var="vpc_id=$VPC_ID" \
  -var="private_subnet_ids=$PRIV_SUBNETS" \
  -var="ec2_security_group_id=$EC2_SG"
```

問題なければ適用します。

```bash
terraform apply \
  -var="vpc_id=$VPC_ID" \
  -var="private_subnet_ids=$PRIV_SUBNETS" \
  -var="ec2_security_group_id=$EC2_SG"
```

補足:

- `terraform.tfvars` を置いていれば `db_password` は自動で読み込まれます
- RDS の作成は通常 5〜10 分ほどかかります

### 完了後の確認

```bash
terraform output
terraform output -raw db_endpoint
```

確認ポイント:

- `db_endpoint` が出力される
- `db_port` が `3306` である
- `db_name` と `db_username` が期待通りである

必要であれば、Step 2 の EC2 から MySQL 接続確認もできます。

```bash
# EC2 にログイン後の例
sudo dnf install -y mariadb105
mysql -h <db_endpoint> -u admin -p handsondb
```

---

## Step 4: ALB + ASG を構築する

この Step では、ALB 経由で複数 EC2 にトラフィックを振り分ける構成を作成します。

作成される主なリソース:

- ALB 用 Security Group
- ASG 用 Security Group
- ALB
- Target Group
- Listener
- Launch Template
- Auto Scaling Group
- CPU ベースのスケーリングポリシー

### Step 1 の出力値を取得する

```bash
cd ../04_alb

VPC_ID=$(cd ../01_vpc && terraform output -raw vpc_id)
PUB_SUBNETS=$(cd ../01_vpc && terraform output -json public_subnet_ids | jq -c '.')
```

### 実行コマンド

```bash
terraform init
terraform fmt
terraform validate
terraform plan \
  -var="vpc_id=$VPC_ID" \
  -var="public_subnet_ids=$PUB_SUBNETS"
```

問題なければ適用します。

```bash
terraform apply \
  -var="vpc_id=$VPC_ID" \
  -var="public_subnet_ids=$PUB_SUBNETS"
```

### 完了後の確認

```bash
terraform output
terraform output -raw web_url
```

ブラウザで ALB の URL にアクセスし、何度かリロードします。

```bash
curl $(terraform output -raw web_url)
```

確認ポイント:

- ALB の URL が表示される
- 初回アクセス直後は Target Group が `initial` で少し待つことがある
- 数回リロードすると、Instance ID が切り替わることがある

もし繋がらない場合は次を確認します。

- Target Group のヘルスチェックが `healthy` になっているか
- ALB 用 SG が 80 番を許可しているか
- EC2 用 SG が ALB の SG からの 80 番を許可しているか
- UserData により Apache が正常起動しているか

---

## Step 5: モジュール構成を体験する

Step 5 は Step 1〜4 をそのまま置き換えるものではなく、Terraform モジュール設計の発展編です。
`05_modules/README.md` とあわせて進めるのがおすすめです。
設計意図まで含めて理解したい場合は、[ARCHITECTURE.md](./ARCHITECTURE.md) の `12. Step 5: 05_modules の位置づけ` 以降も参照してください。

### 5a. backend 用インフラを作る

まず tfstate 保存用の S3 バケットとロック用 DynamoDB テーブルを作ります。

```bash
cd ../05_modules/bootstrap
terraform init
terraform fmt
terraform validate
terraform plan
terraform apply
```

完了後、バケット名を確認します。

```bash
terraform output s3_bucket_name
terraform output dynamodb_table_name
```

### 5b. `backend.tf` を設定する

`05_modules/environments/dev/backend.tf` の以下を書き換えます。

```hcl
bucket = "handson-tfstate-<YOUR_ACCOUNT_ID>"
```

AWS アカウント ID は次で確認できます。

```bash
aws sts get-caller-identity --query Account --output text
```

### 5c. `dev` 環境を作る

```bash
cd ../environments/dev
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars` を開き、必要に応じて `allowed_ssh_cidrs` を自分の IP に変更します。

例:

```hcl
prefix = "handson"
env    = "dev"
allowed_ssh_cidrs = ["YOUR_IP/32"]
```

自分の IP は次で確認できます。

```bash
curl ifconfig.me
```

実行します。

```bash
terraform init
terraform fmt
terraform validate
terraform plan
terraform apply
```

### 完了後の確認

```bash
terraform output
terraform output -raw web_url
curl $(terraform output -raw web_url)
```

確認ポイント:

- `module.vpc` と `module.ec2` が問題なく連携している
- `web_url` にアクセスできる
- Step 1〜4 のような手動の値受け渡しなしで構築できる

---

## Step 間の値受け渡し早見表

Step 1〜4 でよく使うコマンドをまとめておきます。

```bash
VPC_ID=$(cd ../01_vpc && terraform output -raw vpc_id)
PUB_SUBNET=$(cd ../01_vpc && terraform output -json public_subnet_ids | jq -r '.[0]')
PUB_SUBNETS=$(cd ../01_vpc && terraform output -json public_subnet_ids | jq -c '.')
PRIV_SUBNETS=$(cd ../01_vpc && terraform output -json private_subnet_ids | jq -c '.')
EC2_SG=$(cd ../02_ec2 && terraform output -raw security_group_id)
```

用途:

- `VPC_ID`: `02_ec2`, `03_rds`, `04_alb` で使用
- `PUB_SUBNET`: `02_ec2` で使用
- `PUB_SUBNETS`: `04_alb` で使用
- `PRIV_SUBNETS`: `03_rds` で使用
- `EC2_SG`: `03_rds` で使用

---

## 各 Step で見るべきポイント

ただ apply するだけでなく、次の観点を確認すると理解が深まります。

### Step 1

- パブリックとプライベートの差はどの設定で生まれているか
- `count.index` がどこで使われているか
- `data.aws_availability_zones` を使う理由は何か

### Step 2

- AMI をハードコードしない理由は何か
- `user_data` はいつ実行されるか
- EIP を付ける意味は何か

### Step 3

- RDS をプライベートサブネットに置く理由は何か
- `cidr_blocks` ではなく `security_groups` 指定にする理由は何か
- `sensitive = true` の意味は何か

### Step 4

- ALB 用 SG と EC2 用 SG を分ける理由は何か
- Target Group のヘルスチェックは何をしているか
- ASG と Launch Template の役割分担は何か

### Step 5

- `for_each` と `map` を使う利点は何か
- `dynamic` ブロックがどの設定を抽象化しているか
- remote backend を使う理由は何か

より詳しい解説:

- 全体構成の理解: [ARCHITECTURE.md](./ARCHITECTURE.md)
- Step 5 のモジュール化の背景: [ARCHITECTURE.md](./ARCHITECTURE.md#12-step-5-05_modules-の位置づけ)

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

Step 5 も試した場合は、追加でこちらも削除します。

```bash
cd ../05_modules/environments/dev
terraform destroy
```

`05_modules/bootstrap` は `prevent_destroy = true` が入っているため、通常の `terraform destroy` では削除されません。
これは tfstate 保管先を誤って消さないための安全策です。

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
