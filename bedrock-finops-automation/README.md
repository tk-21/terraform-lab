# bedrock-finops-automation

AWS Cost Explorer と Amazon Bedrock を使って、月次コストレポートを自動生成し、Email に通知する FinOps 自動化基盤です。

> **注記（モノレポ構成）**: このディレクトリはモノレポ `terraform-lab` の一プロジェクトです。GitHub リポジトリは `terraform-lab` であり、`bedrock-finops-automation` という単独リポジトリは存在しません。GitHub Actions の workflow ファイルもリポジトリルート（`terraform-lab/.github/workflows/`）に配置されています（GitHub Actions はリポジトリルートの `.github/workflows/` しか認識しないため）。

## このハンズオンで得られること

このハンズオンを完了すると、次のことを一通り体験できます。

1. Terraform で AWS のサーバーレス構成をモジュール分割して組み立てる流れ
2. GitHub Actions と OIDC を使って、アクセスキーなしで AWS にデプロイする方法
3. Step Functions を中心に、Lambda を連携させたバッチワークフローの作り方
4. Cost Explorer のデータを収集し、異常検知や月次レポート生成につなげる考え方
5. Amazon Bedrock を使って、コスト分析コメントや改善提案を自動生成する実装パターン
6. S3、DynamoDB、Secrets Manager、SSM Parameter Store を組み合わせた実運用寄りの設計
7. 手動テストから定期実行の有効化まで、自動化基盤を段階的に立ち上げる進め方

毎月 1 日 09:00 JST に Step Functions が起動し、次の処理を順番に実行します。

1. Cost Explorer から当月・前月のコストを収集
2. 前月比増加やサービス集中などの異常を検知
3. Bedrock で所見と改善提案を生成
4. HTML レポートを S3 に保存
5. SNS 経由で要約とレポート URL を Email 通知

## アーキテクチャ概要

```text
EventBridge (毎月1日 09:00 JST)
  -> Step Functions
       -> collector
       -> anomaly-detector
       -> ai-reporter
       -> html-formatter
       -> sns-notifier
```

補足:

- AWS リソースのデプロイ先リージョンは `ap-northeast-1`
- Cost Explorer API は `us-east-1` 固定
- 開発環境では scheduler は `enabled = false` で無効化済み
- 通知は SNS Email サブスクリプション（機密情報の管理は不要）

## ディレクトリ構成

```text
bedrock-finops-automation/
├── bootstrap/              GitHub Actions OIDC 用 IAM ロール作成
├── environments/dev/       dev 環境の Terraform エントリポイント
├── modules/storage/        S3 + DynamoDB
├── modules/collector/      Cost Explorer 収集 Lambda
├── modules/anomaly-detector/ 異常検知 Lambda
├── modules/ai-reporter/    Bedrock 分析 Lambda
├── modules/html-formatter/ HTML レポート生成 Lambda
├── modules/sns-notifier/   SNS Email 通知 Lambda
├── modules/workflow/       Step Functions
├── modules/scheduler/      EventBridge スケジューラ
├── ARCHITECTURE.md         詳細設計
└── README.md               このファイル

# モノレポルート（terraform-lab/）側
terraform-lab/.github/workflows/
├── bedrock-finops-terraform.yml        # plan/apply（paths は bedrock-finops-automation/ プレフィックス付き）
└── bedrock-finops-integration-test.yml # 手動実行の E2E テスト
```

## この README の読み方

ハンズオンは次の順番で進めると迷いません。

1. ローカル準備
2. GitHub Actions 用 OIDC ロール作成
3. Terraform バックエンド作成
4. 通知先メールアドレスの設定
5. Terraform の plan / apply
6. SNS Email サブスクリプションの確認
7. Step Functions の手動実行
8. 毎月実行の有効化

## 事前準備

### 前提ツール

- Terraform `>= 1.5.0`
- AWS CLI
- Git
- GitHub リポジトリ
- `python3` と `venv`

### AWS 側で必要なもの

- このプロジェクトをデプロイする AWS アカウント
- IAM / S3 / DynamoDB / Lambda / Step Functions / EventBridge / SNS を操作できる権限
- Amazon Bedrock で対象モデルを利用できる状態
- 通知を受け取りたいメールアドレス

### GitHub 側で必要なもの

- このリポジトリを GitHub に push できること
- GitHub Actions を有効化していること

## ハンズオン手順

### 1. リポジトリを開き、Python 仮想環境を作る

このリポジトリでは Python を使う作業を `.venv` 前提で行います。

```bash
cd /home/takuya/terraform-lab/bedrock-finops-automation
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install --upgrade pip
python3 -m pip install pytest pytest-cov boto3
```

確認:

```bash
pwd
ls .venv
which python3
```

`which python3` の結果が `.venv/bin/python3` を指していれば OK です。

### 2. GitHub Actions 用 OIDC ロールを作成する

このプロジェクトの CI/CD はアクセスキーではなく OIDC を使います。
まず `bootstrap/` で GitHub Actions 用 IAM ロールを作成します。

> **モノレポ注意**: GitHub Actions の OIDC Provider（`https://token.actions.githubusercontent.com`）は AWS アカウントに1つしか登録できません。`terraform-lab` 内の他プロジェクトが既に作成済みの場合があるため、`bootstrap/main.tf` では OIDC Provider を新規作成せず `data` source で既存のものを参照する構成にしています。もし `EntityAlreadyExists` エラーが出た場合は、`aws_iam_openid_connect_provider` が `resource` のままになっていないか確認してください。

```bash
cd bootstrap
terraform init
terraform plan -var="github_owner=YOUR_GITHUB_NAME"
```

内容を確認したうえで、実際の適用は自分で実行します。

```bash
terraform apply -var="github_owner=YOUR_GITHUB_NAME"
```

`YOUR_GITHUB_NAME` には `git remote -v` で確認できる GitHub オーナー名（ユーザー名 or Organization 名）を指定します。`https://github.com/{OWNER}/{REPO}.git` の `{OWNER}` 部分です。

作成後、出力値を確認します。

```bash
terraform output github_actions_role_arn
```

この値を GitHub リポジトリの `Settings > Secrets and variables > Actions` に登録します。
**このリポジトリはモノレポ（`terraform-lab`）のサブディレクトリなので、Secrets はモノレポのルートリポジトリ（`terraform-lab`）側に登録してください**（`bedrock-finops-automation` という別リポジトリではありません）。

- Secret 名: `AWS_ROLE_ARN`
- 値: `terraform output github_actions_role_arn` の結果

補足:

- `github_repo` はデフォルトで `terraform-lab`（モノレポ自体のリポジトリ名。`bedrock-finops-automation` はその中のディレクトリ名にすぎない）
- 別リポジトリで使う場合は `-var="github_repo=..."` を追加
- trust policy の `sub` 条件は `repo:{owner}/{repo}:*` でリポジトリ単位のスコープになる。モノレポ全体が対象になるため、他プロジェクトの GitHub Actions からも同じ IAM ロール（`AdministratorAccess` 付き）を Assume できる点に注意

### 3. Terraform バックエンド用の S3 / DynamoDB を作成する

`environments/dev/backend.tf` では次の固定値を使っています。

- S3 バケット: `tfstate-bedrock-finops-automation`
- DynamoDB テーブル: `tfstate-lock-bedrock-finops`

先にこの 2 つを作成してください。

```bash
aws s3 mb s3://tfstate-bedrock-finops-automation --region ap-northeast-1
```

```bash
aws dynamodb create-table \
  --table-name tfstate-lock-bedrock-finops \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-northeast-1
```

確認コマンド:

```bash
aws s3 ls s3://tfstate-bedrock-finops-automation --region ap-northeast-1
aws dynamodb describe-table --table-name tfstate-lock-bedrock-finops --region ap-northeast-1
```

### 4. 通知先メールアドレスを設定する

`sns-notifier` モジュールが SNS Topic と Email サブスクリプションを Terraform で作成します。
`environments/dev/terraform.tfvars` の `notification_email_addresses` に通知を受け取りたいメールアドレスを指定してください。

```hcl
notification_email_addresses = ["your-email@example.com"]
```

複数指定も可能です。

```hcl
notification_email_addresses = ["you@example.com", "team@example.com"]
```

`apply` 後、各メールアドレス宛に AWS から購読確認メールが届くので、リンクをクリックして承認してください（承認するまで通知は届きません）。

### 5. `terraform.tfvars` を確認する

`environments/dev/terraform.tfvars` は初期状態で次の内容です。

```hcl
aws_region   = "ap-northeast-1"
environment  = "dev"
project_name = "bedrock-finops-automation"
owner        = "your-name"
cost_center  = "personal"

notification_email_addresses = ["your-email@example.com"]
```

最低でも `owner` と `notification_email_addresses` は自分用に変えておいてください。

例:

```hcl
owner        = "takuya"
cost_center  = "personal-lab"

notification_email_addresses = ["takuya@example.com"]
```

### 6. Terraform で dev 環境をデプロイする

`environments/dev` に移動して初期化します。

```bash
cd environments/dev
terraform init
terraform fmt -recursive
terraform validate
terraform plan
```

問題なければ、適用は自分で実行します。

```bash
terraform apply
```

デプロイ後に主要な出力を確認します。

```bash
terraform output
```

特に確認したい出力:

- `report_bucket_name`
- `state_machine_arn`
- `state_machine_name`
- `sns_topic_arn`

### 7. SNS Email サブスクリプションを承認する

`apply` 実行後、`notification_email_addresses` に指定した各メールアドレス宛に AWS から「AWS Notification - Subscription Confirmation」というメールが届きます。
本文中の `Confirm subscription` リンクをクリックしてください。承認するまで通知メールは届きません。

サブスクリプションの状態は以下でも確認できます。

```bash
aws sns list-subscriptions-by-topic \
  --topic-arn "$(terraform output -raw sns_topic_arn)" \
  --region ap-northeast-1
```

`SubscriptionArn` が `PendingConfirmation` のままなら未承認です。

### 8. GitHub Actions 用 Secret を追加する

統合テストワークフローでは `STATE_MACHINE_ARN` も使います。
dev 環境の apply 後に GitHub に登録してください。

```bash
terraform output -raw state_machine_arn
```

GitHub の `Settings > Secrets and variables > Actions` に次を登録します（登録先はモノレポルートの `terraform-lab` リポジトリ）。

- `AWS_ROLE_ARN`
- `STATE_MACHINE_ARN`

**それぞれ何を登録するか:**

**`AWS_ROLE_ARN`** — `bootstrap/` で作成した IAM ロールの ARN。GitHub Actions が OIDC で AWS に認証する際に Assume するロール（`bootstrap/main.tf` で作成）。

```bash
cd bootstrap
terraform output -raw github_actions_role_arn
```

出力例: `arn:aws:iam::123456789012:role/github-actions-bedrock-finops-automation`

**`STATE_MACHINE_ARN`** — `environments/dev` の apply 後に作成される Step Functions ステートマシンの ARN。統合テスト workflow（`bedrock-finops-integration-test.yml`）が Step Functions を手動起動する際に使う（`terraform.yml` 側の plan/apply では使わない）。

```bash
cd environments/dev
terraform output -raw state_machine_arn
```

出力例: `arn:aws:states:ap-northeast-1:123456789012:stateMachine:bedrock-finops-automation-workflow-dev`

> `AWS_ROLE_ARN` は `bootstrap` の apply 後、`STATE_MACHINE_ARN` は `environments/dev` の apply 後でないと値が取得できない点に注意。

### 9. ローカルで最低限の確認をする

まず Terraform の整合性を確認します。

```bash
cd /home/takuya/terraform-lab/bedrock-finops-automation/environments/dev
terraform fmt -check -recursive
terraform validate
```

次に Python テストを実行します。

```bash
cd /home/takuya/terraform-lab/bedrock-finops-automation
source .venv/bin/activate
pytest modules/ --tb=short --cov=modules --cov-report=term-missing -q
```

### 10. Step Functions を手動実行して動作確認する

初回は scheduler が無効なので、手動で 1 回流します。

現在のステートマシン ARN を確認:

```bash
cd /home/takuya/terraform-lab/bedrock-finops-automation/environments/dev
terraform output -raw state_machine_arn
```

前月分で実行する場合:

```bash
aws stepfunctions start-execution \
  --state-machine-arn "YOUR_STATE_MACHINE_ARN" \
  --name "manual-test-$(date +%Y%m%d%H%M%S)" \
  --input '{"source":"manual-test"}' \
  --region ap-northeast-1
```

対象月を指定して実行する場合:

```bash
aws stepfunctions start-execution \
  --state-machine-arn "YOUR_STATE_MACHINE_ARN" \
  --name "manual-test-2025-01-$(date +%Y%m%d%H%M%S)" \
  --input '{"source":"manual-test","target_year_month":"2025-01"}' \
  --region ap-northeast-1
```

実行状況の確認:

```bash
aws stepfunctions list-executions \
  --state-machine-arn "YOUR_STATE_MACHINE_ARN" \
  --max-results 5 \
  --region ap-northeast-1
```

詳細確認:

```bash
aws stepfunctions describe-execution \
  --execution-arn "YOUR_EXECUTION_ARN" \
  --region ap-northeast-1
```

### 11. S3 に成果物が出力されているか確認する

対象月が `2025-01` の場合、次の 5 ファイルが出ていれば一連の処理は成功です。

```text
raw/2025-01/current_month.json
raw/2025-01/prev_month.json
anomaly/2025-01/anomaly_report.json
ai-report/2025-01/analysis.json
html/2025-01/report.html
```

確認コマンド:

```bash
aws s3 ls s3://YOUR_REPORT_BUCKET/raw/2025-01/ --region ap-northeast-1
aws s3 ls s3://YOUR_REPORT_BUCKET/anomaly/2025-01/ --region ap-northeast-1
aws s3 ls s3://YOUR_REPORT_BUCKET/ai-report/2025-01/ --region ap-northeast-1
aws s3 ls s3://YOUR_REPORT_BUCKET/html/2025-01/ --region ap-northeast-1
```

### 12. GitHub Actions の統合テストを使う

GitHub に `AWS_ROLE_ARN` と `STATE_MACHINE_ARN` を登録済みなら、Actions から E2E テストも実行できます。

手順:

1. GitHub の `Actions` タブを開く
2. `bedrock-finops-automation Integration Test` ワークフローを選ぶ
3. `Run workflow` を押す
4. `target_year_month` を空欄にすると前月、`2025-01` のように入れると対象月指定で実行

### 13. 毎月自動実行を有効化する

手動テストで問題なければ、`environments/dev/main.tf` の scheduler を有効化します。

```hcl
module "scheduler" {
  source = "../../modules/scheduler"

  project_name      = var.project_name
  environment       = var.environment
  state_machine_arn = module.workflow.state_machine_arn
  enabled           = true
}
```

その後、再度 plan を確認し、自分で apply します。

```bash
cd environments/dev
terraform plan
terraform apply
```

## 実行後に見るポイント

### Step Functions

- 実行ステータスが `SUCCEEDED` になっているか
- どのステートで失敗したか
- Lambda の返り値が次ステートに渡っているか

### CloudWatch Logs

- `/aws/lambda/{function_name}`
- `/aws/states/{state_machine_name}`

特に `ai-reporter` と `sns-notifier` は外部サービス連携を含むので確認しやすいです。

### Email

- SNS Topic にメッセージが Publish されているか（CloudWatch Logs で確認）
- 受信メールにレポート URL が含まれているか
- 要約が想定どおりに表示されているか

## よく使うコマンド

### Terraform

```bash
cd environments/dev
terraform init
terraform fmt -recursive
terraform validate
terraform plan
terraform output
```

### Python テスト

```bash
cd /home/takuya/terraform-lab/bedrock-finops-automation
source .venv/bin/activate
pytest modules/ --tb=short --cov=modules --cov-report=term-missing -q
```

### Step Functions

```bash
aws stepfunctions list-state-machines --region ap-northeast-1
aws stepfunctions list-executions --state-machine-arn "YOUR_STATE_MACHINE_ARN" --region ap-northeast-1
```

## ハンズオンの後片付け

不要になったら次の順番でリソースを削除します。`terraform destroy` は Claude Code では実行できないため、すべて自分で実行してください。

### 1. 定期実行を無効化する（有効化していた場合のみ）

`environments/dev/main.tf` の scheduler モジュールを `enabled = false` に戻してから apply するか、そのまま destroy に進んでも構いません（destroy で EventBridge Rule ごと削除されます）。

### 2. dev 環境のリソースを削除する

```bash
cd environments/dev
terraform plan -destroy
```

内容を確認したうえで、実際の削除は自分で実行します。

```bash
terraform destroy
```

S3 バケットは `force_destroy = true`（dev 環境のみ）なので、中にオブジェクトが残っていても削除できます。

### 3. bootstrap の IAM ロールを削除する

```bash
cd bootstrap
terraform plan -destroy -var="github_owner=YOUR_GITHUB_NAME"
terraform destroy -var="github_owner=YOUR_GITHUB_NAME"
```

削除されるのは `aws_iam_role.github_actions` と `aws_iam_role_policy_attachment.github_actions_admin` のみです。GitHub Actions OIDC Provider（`aws_iam_openid_connect_provider`）は `data` source で参照しているだけの既存リソースなので、`terraform-lab` 内の他プロジェクトが使い続けられるよう削除されません。

### 4. Terraform バックエンド用の S3 / DynamoDB を削除する（完全に片付ける場合）

バックエンド用リソースは Terraform 管理外（手順3で作成したもの）なので手動で削除します。他プロジェクトで同じバケット・テーブルを使い回していないか確認してから実行してください。

```bash
aws s3 rb s3://tfstate-bedrock-finops-automation --force --region ap-northeast-1
aws dynamodb delete-table --table-name tfstate-lock-bedrock-finops --region ap-northeast-1
```

### 5. GitHub Secrets を削除する（完全に片付ける場合）

`terraform-lab` リポジトリの `Settings > Secrets and variables > Actions` から以下を削除します。

- `AWS_ROLE_ARN`
- `STATE_MACHINE_ARN`

### 6. SNS サブスクリプションの確認

手順2の `terraform destroy` で SNS Topic ごと削除されるため、購読も自動的に解除されます。念のため以下で残っていないか確認できます。

```bash
aws sns list-subscriptions --region ap-northeast-1 | grep bedrock-finops
```

## トラブルシュート

### `terraform init` が backend 作成前に失敗する

`tfstate-bedrock-finops-automation` と `tfstate-lock-bedrock-finops` が未作成の可能性があります。先に README の手順 3 を実施してください。

### `bootstrap` の apply で `EntityAlreadyExists`（OIDC Provider）が出る

```
Error: creating IAM OIDC Provider: ... EntityAlreadyExists: Provider with url
https://token.actions.githubusercontent.com already exists.
```

このエラーは、同一 AWS アカウント内で `terraform-lab` の他プロジェクトが既に GitHub Actions OIDC Provider を作成済みの場合に発生します（OIDC Provider は同一 URL につき AWS アカウントに1つしか作成できない）。
`bootstrap/main.tf` では OIDC Provider を `resource` ではなく `data` source として参照する構成にしているため、通常は発生しません。もしこのエラーが出た場合は `main.tf` の該当ブロックが `resource "aws_iam_openid_connect_provider"` に戻っていないか確認してください。

### GitHub Actions で AWS 認証に失敗する

確認点:

- `AWS_ROLE_ARN` が GitHub Secrets に登録されているか（モノレポルート `terraform-lab` リポジトリ側に登録すること）
- `bootstrap` の `github_owner` が正しいか
- `bootstrap` の `github_repo` が `terraform-lab`（モノレポ自体のリポジトリ名）になっているか。`bedrock-finops-automation` のままだと trust policy の `sub` 条件が実際のリポジトリと一致せず認証に失敗する
- workflow ファイルがモノレポルートの `.github/workflows/` に配置されているか（`bedrock-finops-automation/.github/workflows/` に置いても GitHub Actions からは認識されない）

### Email 通知だけ失敗する

確認点:

- SNS Email サブスクリプションが `Confirmed` になっているか（`PendingConfirmation` のままだと届かない）
- `notification_email_addresses` のメールアドレスが正しいか
- 迷惑メールフォルダに振り分けられていないか
- `sns-notifier` Lambda の CloudWatch Logs にエラーが出ていないか

### Bedrock 呼び出しで失敗する

確認点:

- 対象 AWS アカウントで Bedrock の利用申請が済んでいるか
- 利用リージョンが `ap-northeast-1` になっているか

## 参考ドキュメント

- 詳細設計: [ARCHITECTURE.md](./ARCHITECTURE.md)
- GitHub Actions OIDC ロール作成: `bootstrap/`
- dev 環境エントリポイント: `environments/dev/`
- GitHub Actions workflow 本体（モノレポルート側）: `../.github/workflows/bedrock-finops-terraform.yml`, `../.github/workflows/bedrock-finops-integration-test.yml`

## 最後に実行する順番だけもう一度

最短で進めるならこの順番です。

1. `.venv` を作る
2. `bootstrap/` で OIDC ロールを作る
3. tfstate 用 S3 / DynamoDB を作る
4. `terraform.tfvars` に `notification_email_addresses` を設定する
5. `environments/dev` で `terraform init`, `plan`, `apply`
6. SNS の購読確認メールを承認する
7. `pytest` を流す
8. Step Functions を手動実行する
9. 問題なければ scheduler を `enabled = true` にして再 apply する
