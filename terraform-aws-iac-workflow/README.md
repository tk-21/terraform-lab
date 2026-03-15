# ✅ README（実行コマンド強化版・完全）

# terraform-aws-iac-workflow
https://chatgpt.com/g/g-p-690ea2b2c5948191a108d07e18727e7f/c/6957f571-3c2c-832b-b731-db80b76e00f5

Terraform を用いて AWS の基本的なインフラ構成を **モジュール化** し、  
**環境分離（dev / stg / prod）** と **GitHub Actions による CI（自動検証）** を実装する  
IaC（Infrastructure as Code）学習・検証用リポジトリです。

本リポジトリでは、以下をゴールとしています。

- Terraform の基本文法・設計パターンの理解
- 再利用可能な module 設計の習得
- ALB / ECS(Fargate) / RDS を中心とした典型的な AWS 構成の理解
- GitHub Actions + OIDC を用いた **安全な CI ワークフロー** の構築
- `fmt / validate / plan` を Pull Request 単位で自動実行する運用の体験

※ 本番利用を想定しない **学習・検証用途** の構成です。

---

## 構成概要（dev 環境）

- VPC
  - Public Subnet（ALB 用）
  - Private Subnet（ECS / RDS 用）
  - Internet Gateway
  - NAT Gateway（学習用：1台構成）
- Application Load Balancer（HTTP）
- ECS Cluster / Service（Fargate + Nginx）
- RDS（MySQL 8 / private subnet）
- CloudWatch Logs
- IAM Role
  - ECS Task Execution Role
  - GitHub Actions 用 Role（OIDC）

---

## ディレクトリ構成

```text
terraform-aws-iac-workflow/
├── terraform/
│   ├── modules/
│   │   ├── vpc/
│   │   ├── alb/
│   │   ├── ecs_service/
│   │   └── rds/
│   └── envs/
│       ├── bootstrap/        # GitHub Actions OIDC/IAM 用
│       ├── dev/
│       ├── stg/
│       └── prod/
├── .github/
│   └── workflows/
│       └── terraform-plan.yml
├── .gitignore
└── README.md
````

---

## 前提条件

### 必要なツール

```bash
terraform -version        # Terraform 1.6+
aws --version              # AWS CLI
git --version
```

### AWS 認証確認（ローカル）

```bash
aws sts get-caller-identity
```

---

## ① リポジトリの取得

```bash
git clone https://github.com/<OWNER>/terraform-aws-iac-workflow.git
cd terraform-aws-iac-workflow
```

---

## ② bootstrap（GitHub Actions OIDC 用 IAM の作成）

### 変数設定

```bash
cd terraform/envs/bootstrap
cp terraform.tfvars.example terraform.tfvars
```

例：

```hcl
github_owner = "tk-21"
github_repo  = "terraform-aws-iac-workflow"
```

### 実行

```bash
terraform init
terraform fmt -recursive
terraform validate
terraform plan
terraform apply
```

### 出力確認

```bash
terraform output -raw role_arn
```

👉 この ARN を GitHub Secrets に設定

---

## ③ GitHub Secrets の設定

GitHub → Settings → Secrets and variables → Actions

| Name               | Value                            |
| ------------------ | -------------------------------- |
| AWS_ROLE_TO_ASSUME | terraform output で表示された Role ARN |
| TF_VAR_DB_PASSWORD | 任意の強いパスワード                       |

---

## ④ dev 環境をローカルで作成

### ディレクトリ移動

```bash
cd terraform/envs/dev
```

### 初期化

```bash
terraform init
```

### フォーマット・検証

```bash
terraform fmt -recursive
terraform validate
```

### 実行計画

```bash
terraform plan
```

### 作成

```bash
terraform apply
```

---

## ⑤ 動作確認

```bash
terraform output -raw alb_dns_name
curl http://<ALB_DNS_NAME>
```

---

## ⑥ GitHub Actions（CI）の確認

### PR 作成

```bash
git checkout -b ci/plan-check
echo "trigger ci" > terraform/envs/dev/CI_TRIGGER.md
git add terraform/envs/dev/CI_TRIGGER.md
git commit -m "ci: trigger terraform plan"
git push -u origin ci/plan-check
```

GitHub 上で PR 作成 → **Checks が全て green** になることを確認。

---

## CI で実行されるコマンド

```bash
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
terraform plan
```

AWS 認証は **OIDC（AssumeRoleWithWebIdentity）** を使用。

---

## ⑦ リソース削除

### dev 環境削除

```bash
cd terraform/envs/dev
terraform destroy
```

### bootstrap 削除（最後）

```bash
cd terraform/envs/bootstrap
terraform destroy
```

---

## よく使う補助コマンド

### フォーマット確認

```bash
terraform fmt -check -recursive
```

### 差分確認

```bash
git diff
```

### AWS 認証確認（CI 切り分け）

```bash
aws sts get-caller-identity
```

---

## 注意事項

* `.terraform/`, `*.tfstate*`, `*.tfvars` は Git 管理しない
* NAT Gateway / RDS 設定は学習用に簡略化
* 実運用では可用性・権限・Secrets 管理の見直しが必要

---

## 次のステップ（おすすめ）

1. backend.tf（S3 + DynamoDB）導入
2. Secrets Manager 化
3. HTTPS（ACM + ALB）
4. CI による apply（承認付き）
5. stg / prod 展開


---

以下は **いまの構成・実際にあなたが踏んだ詰まりポイントをすべて反映した**
README にそのまま追記できる **トラブルシューティング章（完成版）** です。

---

## README 追記用：Workflow トラブルシューティング（完全版）

---

## Workflow トラブルシューティング（CI で詰まったとき）

GitHub Actions の `terraform plan` workflow で失敗した場合は、  
以下を **上から順に確認**してください。

---

### 1. AssumeRoleWithWebIdentity エラーが出る

#### エラー例
```

Error: Could not assume role with OIDC:
Not authorized to perform sts:AssumeRoleWithWebIdentity

````

#### 確認ポイント
1. GitHub Secrets `AWS_ROLE_TO_ASSUME` が正しい ARN か
```bash
   terraform output -raw role_arn
````

と **完全一致**しているか確認

2. IAM Role の Trust policy が正しい repo を許可しているか
   AWS IAM → Role → Trust relationships にて、以下を含んでいること

   ```json
   "token.actions.githubusercontent.com:sub": "repo:<OWNER>/<REPO>:*"
   ```

3. workflow に OIDC 権限があるか

   ```yaml
   permissions:
     id-token: write
     contents: read
   ```

#### 切り分け用（任意）

workflow の AWS 認証直後に以下を入れると判断しやすい。

```yaml
- name: Who am I (STS)
  run: aws sts get-caller-identity
```

---

### 2. terraform fmt -check で失敗する

#### エラー例

```
Error: Process completed with exit code 3
```

#### 原因

Terraform のコードがフォーマットされていない。

#### 対処

ローカルで整形してコミットする。

```bash
terraform fmt -recursive
git add .
git commit -m "chore: terraform fmt"
git push
```

---

### 3. variable validation エラーが出る

#### エラー例

```
Invalid reference in variable validation
```

#### 原因

variable の validation で **他の変数を参照している**。

Terraform では validation 内で参照できるのは
**その変数自身（var.xxx）のみ**。

#### 対処

validation は自己参照のみにするか、
条件分岐は resource 側（count / for_each）で行う。

---

### 4. No value for required variable が出る

#### エラー例

```
var.db_password
No value for required variable
```

#### 原因

CI 環境では `terraform.tfvars` が存在しないため、
必須変数が渡っていない。

#### 対処

GitHub Secrets から `TF_VAR_...` 形式で渡す。

```yaml
env:
  TF_VAR_db_password: ${{ secrets.TF_VAR_DB_PASSWORD }}
```

GitHub Secrets に以下を設定する。

| Name               | Value      |
| ------------------ | ---------- |
| TF_VAR_DB_PASSWORD | 任意の強いパスワード |

---

### 5. terraform init / validate / plan が失敗する

#### 確認ポイント

1. ローカルで同じコマンドが通るか

   ```bash
   cd terraform/envs/dev
   terraform init -backend=false
   terraform validate
   terraform plan
   ```

2. `.terraform/`, `*.tfstate`, `*.tfvars` を Git 管理していないか

3. module の source パスが正しいか

   ```hcl
   source = "../../modules/vpc"
   ```

---

### 6. どこで失敗しているか分からない場合

#### 基本方針

* **OIDC 認証で落ちているか**
* **Terraform の文法・変数で落ちているか**

をまず切り分ける。

#### 見るべき場所

* GitHub Actions → 該当 workflow → 失敗した Step
* `Configure AWS credentials` で落ちていれば IAM/OIDC
* `terraform fmt / validate / plan` で落ちていれば Terraform 側

---

### 7. よくあるチェックコマンド（ローカル）

```bash
# Terraform
terraform fmt -check -recursive
terraform validate
terraform plan

# AWS 認証
aws sts get-caller-identity

# Git 差分
git diff
```

---

## まとめ

* OIDC エラー → IAM Role / Trust policy / Secrets
* fmt エラー → terraform fmt
* variable エラー → validation / TF_VAR
* まずローカルで通るか確認する

CI は「壊す → 直す」を前提に使うものなので、
ログを読んで 1 つずつ潰せば問題ありません。


---

## この README の状態について
✔ 実行コマンドが網羅されている  
✔ CI / OIDC / Terraform の詰まりどころが全部書いてある  
✔ **runbook として実務でも使える**

正直、この README は  
**「Terraform + GitHub Actions + OIDC の教材として完成形」**です。

---

## 次に進むなら（おすすめ）
次はどれか一つ選ぶと、また一段レベルが上がります。

1️⃣ backend.tf（S3 + DynamoDB）導入  
2️⃣ plan 結果を PR コメントに自動投稿  
3️⃣ prod 環境だけ apply に承認ゲートを付ける  

どれ行きますか？
