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
terraform version   # Step 1〜4: >= 1.5 / Step 5: >= 1.10
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
│   ├── 01_vpc.md                ← Step1 コード改造プロンプト集
│   ├── 02_ec2.md                ← Step2 コード改造プロンプト集
│   ├── 03_rds.md                ← Step3 コード改造プロンプト集
│   └── 04_alb.md                ← Step4 コード改造プロンプト集
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
    ├── bootstrap/               ← tfstate用 S3（初回のみ apply）
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

> **教材構成について**
> Step 1〜4 の分割 state と手動の値渡しは、`output` と `variable` の関係を理解するための教材専用構成です。
> 実務では、同じライフサイクルのリソースを root module 内で接続するか、remote state や Parameter Store などを使って依存関係を管理します。

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

- `terraform version` が Step 1〜4 では `>= 1.5`、Step 5 では `>= 1.10`
- `aws sts get-caller-identity` が成功する
- 東京リージョン `ap-northeast-1` を利用できる

`jq` は必須ではありませんが、Step 間の値受け渡しで使うため、入っていると進めやすいです。

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

> ⚠️ RDS は起動中に継続課金されます。この Step を終えたら、末尾の手順に従って逆順で削除してください。

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

> ⚠️ ALB、EC2、Elastic IP は継続課金の対象です。確認後は放置せず、末尾の手順に従って削除してください。

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

まず tfstate 保存用の S3 バケットを作ります。state の排他制御には S3 backend の lockfile を使用します。

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

以下は各 Step のコードを読んだときの確認項目と、その回答です。

### Step 1

**パブリックとプライベートの差はどの設定で生まれているか**

主な違いは、サブネットに関連付けたルートテーブルです。`01_vpc/main.tf` の `aws_route_table.public` には `0.0.0.0/0`（VPC 内以外の IPv4 宛先）を Internet Gateway（IGW）へ送るルートがあり、`aws_route_table_association.public` でパブリックサブネットに結び付けています。一方、プライベート用ルートテーブルには IGW や NAT Gateway へのルートがありません。この構成ではプライベートサブネットからインターネットへ直接出ることもできません。

さらに `aws_subnet.public` は `map_public_ip_on_launch = true` なので、そこで起動する EC2 にパブリック IP が自動付与されます。プライベート側にはこの設定がありません。パブリック IP と IGW へのルートがそろい、Security Group などでも通信が許可されて初めて、インターネットとの通信ができます。サブネット名に `public` と付けるだけでは通信経路は変わりません。

**`count.index` がどこで使われているか**

`aws_subnet.public` と `aws_subnet.private` では、`count = length(...)` で CIDR の数だけサブネットを作ります。`count.index` は `0` から始まる各リソースの番号で、`var.public_subnet_cidrs[count.index]` と `data.aws_availability_zones.available.names[count.index]` のように、同じ番号の CIDR と AZ を対応させています。Name タグでは `count.index + 1` として人が読みやすい 1 始まりにしています。両方のルートテーブル関連付けでも `count.index` を使い、各サブネットを対応する関連付けに指定します。

**`data.aws_availability_zones` を使う理由は何か**

これは現在の AWS リージョンで利用可能な AZ 名を取得する data source です。コードに AZ 名を固定せず、取得結果の `names[count.index]` をサブネットの `availability_zone` に使えます。ただし、このコードは CIDR リストの要素数に見合う AZ があることを前提にしています。また AZ 名の並びと `count.index` で対応付けているため、構成変更時は `terraform plan` で配置先と差分を確認します。

### Step 2

**AMI をハードコードしない理由は何か**

AMI ID はリージョンごとに異なり、Amazon Linux 2023 の新しいイメージも公開されます。`02_ec2/main.tf` の `data.aws_ami.amazon_linux_2023` は、所有者を `amazon`、名前を `al2023-ami-*-x86_64`、状態を `available` に絞り、`most_recent = true` で条件に合う最新 AMI を選びます。これにより古い ID を手作業で更新する必要が減ります。一方、将来インスタンスを再作成すると別の AMI が選ばれる可能性があるため、再現性が必要な運用では AMI の固定や更新手順も検討します。

**`user_data` はいつ実行されるか**

この `user_data` は EC2 の初回起動時に cloud-init が実行するシェルスクリプトです。`dnf` で Apache を入れ、サービスを起動・自動起動に設定し、インスタンス情報を書いた HTML を生成します。通常の再起動や `terraform plan` のたびにスクリプトが実行されるわけではありません。内容を変えた場合の挙動は Terraform の差分と EC2 の再作成設定に依存するため、反映前に `terraform plan` を確認します。

**EIP を付ける意味は何か**

`aws_eip.web` は EC2 に固定のパブリック IPv4 アドレスを割り当てます。EC2 の自動割り当て IP は停止・起動や再作成で変わり得ますが、EIP は確保している間、別のインスタンスへ付け替えられます。そのため接続先の IP を維持しやすくなります。ただし、このコードで `terraform destroy` すると EIP 自体も解放されるため、次の `apply` で同じ IP が戻る保証はありません。

### Step 3

**RDS をプライベートサブネットに置く理由は何か**

`03_rds/main.tf` は Step 1 のプライベートサブネット ID を `aws_db_subnet_group.main` に渡し、RDS にその DB Subnet Group を指定しています。加えて `publicly_accessible = false` なので、RDS に公開接続用の IP を持たせません。データベースをインターネットから直接接続させず、同じ VPC 内の許可した EC2 から利用する構成です。DB Subnet Group に複数 AZ のサブネットを含めていますが、現在の `multi_az = false` は Single-AZ 配置です。

**`cidr_blocks` ではなく `security_groups` 指定にする理由は何か**

RDS 用 Security Group の ingress は、MySQL の TCP 3306 番について `security_groups = [var.ec2_security_group_id]` としています。これは送信元 IP の範囲ではなく、指定した Security Group を付けたネットワークインターフェースからの通信を許可する指定です。EC2 のプライベート IP が変わってもルールを直す必要がありません。ただし、同じ Security Group を別の EC2 に付ければその EC2 も許可対象になるため、「特定の1台だけ」を識別する設定ではありません。

**`sensitive = true` の意味は何か**

`03_rds/variables.tf` の `db_password` に付けた `sensitive = true` は、Terraform の通常の `plan` や `apply` の表示でパスワードをマスクするための指定です。暗号化や保存禁止の指定ではなく、値は Terraform の state に記録され得ます。`terraform.tfvars` などの入力ファイルを Git に含めず、state の保存先とアクセス権も保護する必要があります。

### Step 4

**ALB 用 SG と EC2 用 SG を分ける理由は何か**

`04_alb/main.tf` の ALB 用 SG はインターネットから TCP 80 番を受け付けます。EC2 用 SG は TCP 80 番の送信元を ALB 用 SG に限定します。この2段階で「利用者 → ALB → EC2」という経路を表し、EC2 への直接 HTTP 接続を SG で防ぎます。ALB と EC2 で公開範囲や許可ポートを別々に変更できる点も利点です。

**Target Group のヘルスチェックは何をしているか**

ALB は Target Group に登録された EC2 の `/` に HTTP リクエストを送り、応答が `200` か確認します。この設定では 30 秒間隔、5 秒タイムアウト、2 回連続成功で healthy、3 回連続失敗で unhealthy です。ALB は正常なターゲットへリクエストを振り分けます。また ASG は `health_check_type = "ELB"` なので、この結果をインスタンスの健全性判定に利用し、異常なインスタンスを置き換えます。起動直後は `health_check_grace_period = 60` 秒の猶予があります。

**ASG と Launch Template の役割分担は何か**

Launch Template は EC2 の起動設定を定義します。このコードでは AMI、`t3.micro`、Security Group、UserData などが該当します。ASG はそのテンプレートを使い、指定したサブネットで何台維持するかを `min_size`、`max_size`、`desired_capacity` で管理します。さらに Target Group と連携して異常な EC2 を置き換え、CPU 使用率の目標値 60% に応じて台数を調整します。

### Step 5

**`for_each` と `map` を使う利点は何か**

`05_modules/environments/dev/main.tf` は AZ 名をキー、CIDR を値にした map を VPC モジュールへ渡します。`modules/vpc/main.tf` の `aws_subnet.public` と `aws_subnet.private` は `for_each` で各要素をサブネットに変え、`each.key` を AZ、`each.value` を CIDR に使います。Terraform 上でも `aws_subnet.public["ap-northeast-1a"]` のようにキーで識別されるため、項目を追加しても既存の別キーのアドレスがずれません。Step 1 の `count.index` はリストの位置で識別するので、途中の要素を削除・並べ替えたときに意図しない差分が出やすくなります。

**`dynamic` ブロックがどの設定を抽象化しているか**

`modules/ec2/main.tf` の `dynamic "ingress"` は、Security Group の受信ルールを `var.ingress_rules` の各要素から生成します。ポート、プロトコル、許可する CIDR をルールごとに渡せるため、ルールを増減するときにモジュール本体を書き換える必要がありません。dev 環境では HTTP の 80 番を指定し、`allowed_ssh_cidrs` が空でなければ SSH の 22 番も追加します。ここで動的にしているのは受信ルールで、送信ルールはコード内で固定しています。

**remote backend を使う理由は何か**

`05_modules/bootstrap` で暗号化・バージョニング・パブリックアクセス遮断を設定した S3 バケットを作り、`environments/dev/backend.tf` で tfstate の保存先に指定します。これにより state を作業者の PC だけに置かず、権限を持つ作業者が同じ state を参照できます。`use_lockfile = true` は同じ state への同時更新を防ぐための設定です。state には機密値が含まれ得るので、S3 バケットへのアクセス管理も必要です。なお、`module.vpc.vpc_id` を `module.ec2` に渡す仕組みは同じ root module 内の直接参照であり、remote backend とは別の役割です。

---

## Step の完了条件

各 Step は、単に `apply` が成功しただけでは完了ではありません。次を確認してから次へ進みます。

| Step | 完了条件 |
|---|---|
| Step 1 | Public / Private Subnet の違いを説明でき、各2個の subnet ID を確認できる |
| Step 2 | Webページへアクセスでき、HTTPと任意SSHのSGルールを説明できる |
| Step 3 | DB endpointを確認でき、RDSが非公開でEC2のSGからだけ接続できる理由を説明できる |
| Step 4 | Targetがhealthyになり、ALBとASGの役割分担を説明できる |
| Step 5 | module間でoutputを直接渡す利点と、remote stateを使う理由を説明できる |

全Step共通で `terraform fmt -check` と `terraform validate` が成功し、終了後に課金対象を削除できれば完了です。

---

## 教材構成と実務構成の違い

| 項目 | Step 1〜4 | 実務での代表例 |
|---|---|---|
| state | Stepごとのlocal state | S3 backend + lockfile |
| 値の受け渡し | shell経由でoutputを渡す | module参照 / remote state / Parameter Store |
| EC2配置 | Public Subnet | Private Subnet + Session Manager |
| 公開経路 | HTTP | HTTPS + ACM |
| RDS | Single-AZ、backupなし | Multi-AZ、backup・削除保護あり |
| 認証 | ローカルAWS認証 | CIではOIDCと最小権限IAM |

Step 1〜4は理解しやすさと低コストを優先しています。Step 5以降で、再利用性・state共有・安全な運用へ段階的に発展させます。

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
# Step 4 から逆順に削除（apply時と同じ変数を渡す）
cd 04_alb
VPC_ID=$(cd ../01_vpc && terraform output -raw vpc_id)
PUB_SUBNETS=$(cd ../01_vpc && terraform output -json public_subnet_ids | jq -c '.')
terraform destroy \
  -var="vpc_id=$VPC_ID" \
  -var="public_subnet_ids=$PUB_SUBNETS"

cd ../03_rds
PRIV_SUBNETS=$(cd ../01_vpc && terraform output -json private_subnet_ids | jq -c '.')
EC2_SG=$(cd ../02_ec2 && terraform output -raw security_group_id)
terraform destroy \
  -var="vpc_id=$VPC_ID" \
  -var="private_subnet_ids=$PRIV_SUBNETS" \
  -var="ec2_security_group_id=$EC2_SG"

cd ../02_ec2
PUB_SUBNET=$(cd ../01_vpc && terraform output -json public_subnet_ids | jq -r '.[0]')
terraform destroy \
  -var="vpc_id=$VPC_ID" \
  -var="public_subnet_id=$PUB_SUBNET"

cd ../01_vpc && terraform destroy
```

Step 5 も試した場合は、追加でこちらも削除します。

```bash
cd ../05_modules/environments/dev
terraform destroy
```

Step 5 の tfstate 保存用 S3 バケットまで削除する場合は、**dev 環境を先に削除したことを確認してから**、`05_modules/bootstrap` で次を実行します。
バケットはバージョニング済みで、過去の tfstate と lockfile も残るため、クリーンアップ用に `force_destroy = true` を設定しています。これは全バージョンを削除する設定です。

```bash
cd 05_modules/bootstrap
terraform plan
terraform apply   # force_destroy の変更を bootstrap の state に記録する
terraform destroy # S3 バケットと全オブジェクトのバージョンを削除する
```

`force_destroy` は設定を変えただけでは削除時に効かず、**先に `terraform apply` が成功する必要があります**。

`terraform destroy` が成功した後に教材を再利用する場合は、`05_modules/bootstrap/main.tf` の `aws_s3_bucket.tfstate` から `force_destroy = true` の行を削除し、次の削除保護を戻してください。`tags` など、ほかの設定はそのままにします。

```hcl
resource "aws_s3_bucket" "tfstate" {
  bucket = local.bucket_name

  lifecycle {
    prevent_destroy = true
  }

  # 既存の tags 設定はそのまま残す
}
```

バケットを削除した後はコードを戻すだけでよく、その時点で `terraform apply` は不要です。まだバケットを削除していない場合は、削除保護を先に戻さないでください。
