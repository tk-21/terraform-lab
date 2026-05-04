# Step 5: Terraform モジュール設計

Step 1〜4 で書いた「フラットなリソース定義」には問題があります。
VPC を別プロジェクトでも使いたくなったとき、コードをまるごとコピーするしかありません。
**モジュール** を使うと、リソースの塊を「部品」として切り出して再利用できます。

このステップでは既存の VPC・EC2 をモジュールとして書き直しながら、
Terraform の中〜上級機能を体験します。

---

## この Step で学ぶこと

| 概念 | 一言説明 | どこで使うか |
|------|---------|-------------|
| モジュールのinput/output設計 | 「何を受け取って何を返すか」のインターフェース設計 | modules/vpc, modules/ec2 |
| `for_each` (map版) | マップのキー/値を使ってリソースを繰り返し作る | VPCモジュール: サブネット |
| `dynamic` ブロック | 変数の中身に応じてブロック自体を動的生成する | EC2モジュール: SGルール |
| `lifecycle` ルール | リソースの作成・更新・削除の挙動を制御する | EC2モジュール |
| モジュール間の値の受け渡し | モジュールのoutputを別モジュールのinputに渡す | environments/dev/main.tf |
| リモートバックエンド | tfstate を S3 に保存し、DynamoDB でロックする | bootstrap/ |

---

## Step 1〜4 との違い

### Step 1〜4 の問題点

```
01_vpc/main.tf   ← VPCのコードが直書き
02_ec2/main.tf   ← EC2のコードが直書き
```

- 別プロジェクトで同じ VPC 構成を使いたいとき → コピーするしかない
- サブネットを3AZに増やしたいとき → subnet ブロックを手書きで追加するしかない
- SGルールを追加したいとき → モジュール本体を直接編集するしかない
- Step 間の値渡し → シェル変数という壊れやすい方法を使っている

### Step 5 の解決方法

```
modules/vpc/   ← 「VPC部品」として独立。変数で設定を受け取る
modules/ec2/   ← 「EC2部品」として独立。SGルールも変数で可変
environments/dev/main.tf  ← 部品を組み合わせるだけ。値渡しはTerraformが解決
```

---

## 全体構成図

```
05_modules/
│
├── bootstrap/                    ← 【最初に1回だけ実行】
│   │                               tfstate を保存するS3とDynamoDBを作る
│   ├── main.tf
│   ├── outputs.tf
│   └── versions.tf
│
├── modules/                      ← 再利用可能な「部品」置き場
│   │
│   ├── vpc/                      ← VPC部品
│   │   ├── main.tf               ← for_each でサブネットを動的生成
│   │   ├── variables.tf          ← 受け取る値の定義
│   │   ├── outputs.tf            ← 返す値の定義
│   │   ├── locals.tf             ← 命名規則などの内部計算
│   │   └── versions.tf
│   │
│   └── ec2/                      ← EC2部品
│       ├── main.tf               ← dynamic ブロック / lifecycle ルール
│       ├── variables.tf
│       ├── outputs.tf
│       ├── locals.tf
│       └── versions.tf
│
└── environments/
    └── dev/                      ← 【環境定義】部品を組み合わせる場所
        ├── main.tf               ← module ブロックで部品を呼び出す
        ├── variables.tf
        ├── outputs.tf
        ├── backend.tf            ← S3にstateを保存する設定
        └── terraform.tfvars.example
```

---

## 実行手順

### Step 5a: リモートバックエンドのセットアップ（初回のみ）

> **なぜ必要か**
> Step 1〜4 は tfstate がローカルに保存されていました。
> チーム開発や複数環境では「stateはS3、同時編集はDynamoDBでロック」が標準です。

```bash
cd 05_modules/bootstrap

terraform init
terraform plan    # 作られるリソースを確認する
terraform apply

# S3バケット名を控えておく（次のステップで使う）
terraform output s3_bucket_name
# 例: handson-tfstate-123456789012
```

作成されるリソース:
- **S3バケット**: tfstate を暗号化・バージョニング付きで保存
- **DynamoDBテーブル**: apply の同時実行を防ぐロック用

---

### Step 5b: backend.tf を書き換える

`environments/dev/backend.tf` を開いて `<YOUR_ACCOUNT_ID>` を書き換えます。

```bash
# AWSアカウントIDを確認する方法
aws sts get-caller-identity --query Account --output text

# または bootstrap の output から確認
cd 05_modules/bootstrap
terraform output s3_bucket_name
```

`environments/dev/backend.tf` の該当箇所:
```hcl
bucket = "handson-tfstate-<YOUR_ACCOUNT_ID>"
#                          ↑ ここを実際のアカウントIDに書き換える
```

---

### Step 5c: 環境をデプロイする

```bash
cd 05_modules/environments/dev

# tfvars を作成する
cp terraform.tfvars.example terraform.tfvars

# SSH接続を許可するIPを自分のIPに書き換える（セキュリティのため）
curl ifconfig.me   # 自分のIPを確認
# terraform.tfvars の allowed_ssh_cidrs = ["YOUR_IP/32"] を書き換える

# 初期化（S3バックエンドへの接続確認も行われる）
terraform init

# 作成されるリソースを確認する
terraform plan

# デプロイ
terraform apply
```

デプロイされるリソース:
- VPC + サブネット（2AZ分）+ IGW + ルートテーブル（VPCモジュール経由）
- EC2 + セキュリティグループ + Elastic IP（EC2モジュール経由）

---

### 動作確認

```bash
# WebサーバーのURLを表示
terraform output web_url

# ブラウザまたはcurlでアクセスする
curl $(terraform output -raw web_url)
# → <h1>Hello from handson-dev</h1> が返れば成功
```

---

### クリーンアップ（作業後は必ず実行）

```bash
# 環境を削除
cd environments/dev
terraform destroy

# バックエンド（S3・DynamoDB）は prevent_destroy で守られているため手動削除
# AWSコンソール → S3 → handson-tfstate-xxxxx → バケットを空にして削除
# AWSコンソール → DynamoDB → handson-tfstate-lock → テーブルを削除
```

---

## 重要な設計ポイント（なぜそう書くのか）

### 1. モジュールの「インターフェース」設計

モジュールは `variables.tf`（入力）と `outputs.tf`（出力）だけが外から見えます。
内部の実装（リソース名・ループ処理など）は隠蔽されます。

```
呼び出し側 (environments/dev/main.tf)
    │
    │  input:  vpc_cidr, public_subnets, private_subnets, ...
    ▼
┌─────────────────────┐
│   modules/vpc/      │  ← 内部実装は呼び出し側が知らなくてよい
│   (実装は隠蔽)      │
└─────────────────────┘
    │
    │  output: vpc_id, public_subnet_ids, private_subnet_ids, ...
    ▼
呼び出し側が output を受け取って次のモジュールに渡す
```

設計の原則: **入力は「何を渡すか」、出力は「何を後続が必要とするか」だけを考える**

---

### 2. `for_each` に list ではなく map を使う理由

```hcl
# ❌ list を使った場合（危険）
public_subnets = ["10.0.1.0/24", "10.0.2.0/24"]

# Terraform は内部でインデックスで管理する
# → aws_subnet.public[0], aws_subnet.public[1]
# → 先頭の要素を削除すると [0] が別のリソースを指してしまい、意図しない削除が起きる
```

```hcl
# ✅ map を使った場合（安全）
public_subnets = {
  "ap-northeast-1a" = "10.0.1.0/24"
  "ap-northeast-1c" = "10.0.2.0/24"
}

# Terraform はキー名で管理する
# → aws_subnet.public["ap-northeast-1a"], aws_subnet.public["ap-northeast-1c"]
# → "ap-northeast-1a" を削除しても "ap-northeast-1c" は影響を受けない
```

**実務での影響**: list で誤った削除が起きると本番サブネットが削除→再作成され、
その上で動いているEC2が全滅するリスクがあります。

---

### 3. `dynamic` ブロックで何が変わるか

`dynamic` ブロックを使うと、ブロック自体をリストから自動生成できます。

```hcl
# ❌ dynamic を使わない場合: SGルールを追加するたびにモジュール本体を編集する
resource "aws_security_group" "this" {
  ingress { from_port = 80, to_port = 80, ... }
  ingress { from_port = 22, to_port = 22, ... }
  # HTTPSも許可したい → ここに ingress ブロックを追加しにくる
}

# ✅ dynamic を使う場合: 呼び出し側の変数を変えるだけでよい
# modules/ec2/main.tf（モジュール本体）
dynamic "ingress" {
  for_each = var.ingress_rules  # このリストを展開してブロックを生成する
  content {
    from_port   = ingress.value.from_port
    to_port     = ingress.value.to_port
    ...
  }
}

# environments/dev/main.tf（呼び出し側）
module "ec2" {
  ingress_rules = [
    { description = "HTTP",  from_port = 80,  ... },
    { description = "SSH",   from_port = 22,  ... },
    { description = "HTTPS", from_port = 443, ... },  # ← ここに追加するだけ
  ]
}
```

---

### 4. `lifecycle` ルールの使い分け

```hcl
lifecycle {
  # ignore_changes: 特定のフィールドが変わっても再作成しない
  # 使いどき: コード管理外で意図的に変更されるフィールド
  ignore_changes = [ami]
  # AMIは毎月新バージョンが出るが、それだけで本番EC2を再起動したくない
  # 意図したタイミングで手動更新する運用にするため ignore する

  # create_before_destroy: 削除前に新リソースを先に作る
  # 使いどき: 置き換え時にダウンタイムを発生させたくない場合
  create_before_destroy = true
  # デフォルトは「古いリソースを消してから新しいのを作る」→ その間サービス停止
  # true にすると「新しいのを作ってから古いのを消す」→ ダウンタイムなし
}
```

---

### 5. モジュール間の値の受け渡し（Step 1〜4 との比較）

Step 1〜4 ではシェルスクリプトで値を受け渡していました。

```bash
# Step 1〜4 のやり方（壊れやすい）
VPC_ID=$(cd ../01_vpc && terraform output -raw vpc_id)
terraform apply -var="vpc_id=$VPC_ID"
# 問題: シェル変数なので型チェックなし、コマンド忘れたらエラー
```

Step 5 では同じ `main.tf` 内でモジュールを呼ぶため、直接参照できます。

```hcl
# Step 5 のやり方（Terraform が依存関係を自動解決）
module "ec2" {
  vpc_id    = module.vpc.vpc_id              # VPCモジュールの出力を直接参照
  subnet_id = module.vpc.public_subnet_ids[0]
}
# Terraform は自動的に「まず vpc を作ってから ec2 を作る」順序を解決する
```

---

## 理解確認チェックリスト

コードを読みながら以下を確認してみてください。

- [ ] `modules/vpc/variables.tf` の `public_subnets` は何型か
- [ ] `modules/vpc/main.tf` の `aws_subnet.public` はなぜ `for_each` を使っているか
- [ ] `modules/ec2/main.tf` の `dynamic "ingress"` はどのブロックを生成しているか
- [ ] `modules/ec2/main.tf` の `lifecycle.ignore_changes = [ami]` がない場合に何が起きるか
- [ ] `environments/dev/main.tf` で `module.vpc.vpc_id` が使えるのはなぜか
- [ ] `bootstrap/main.tf` の `lifecycle { prevent_destroy = true }` を外すとどうなるか
