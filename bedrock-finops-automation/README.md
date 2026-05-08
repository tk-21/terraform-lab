# bedrock-finops-automation

AWS Cost Explorer と Amazon Bedrock を使って、月次コストレポートを自動生成し、Chatwork に通知する FinOps 自動化基盤です。

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
5. Chatwork に要約とレポート URL を通知

## アーキテクチャ概要

```text
EventBridge (毎月1日 09:00 JST)
  -> Step Functions
       -> collector
       -> anomaly-detector
       -> ai-reporter
       -> html-formatter
       -> chatwork-notifier
```

補足:

- AWS リソースのデプロイ先リージョンは `ap-northeast-1`
- Cost Explorer API は `us-east-1` 固定
- 開発環境では scheduler は `enabled = false` で無効化済み
- 機密情報は Secrets Manager / SSM Parameter Store で管理

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
├── modules/chatwork-notifier/ Chatwork 通知 Lambda
├── modules/workflow/       Step Functions
├── modules/scheduler/      EventBridge スケジューラ
├── ARCHITECTURE.md         詳細設計
└── README.md               このファイル
```

## この README の読み方

ハンズオンは次の順番で進めると迷いません。

1. ローカル準備
2. GitHub Actions 用 OIDC ロール作成
3. Terraform バックエンド作成
4. Chatwork 用の機密情報登録
5. Terraform の plan / apply
6. Step Functions の手動実行
7. 毎月実行の有効化

## 事前準備

### 前提ツール

- Terraform `>= 1.5.0`
- AWS CLI
- Git
- GitHub リポジトリ
- `python3` と `venv`

### AWS 側で必要なもの

- このプロジェクトをデプロイする AWS アカウント
- IAM / S3 / DynamoDB / Lambda / Step Functions / EventBridge / Secrets Manager / SSM Parameter Store を操作できる権限
- Amazon Bedrock で対象モデルを利用できる状態
- Chatwork API トークン
- Chatwork ルーム ID

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

```bash
cd bootstrap
terraform init
terraform plan -var="github_owner=YOUR_GITHUB_NAME"
```

内容を確認したうえで、実際の適用は自分で実行します。

```bash
terraform apply -var="github_owner=YOUR_GITHUB_NAME"
```

作成後、出力値を確認します。

```bash
terraform output github_actions_role_arn
```

この値を GitHub リポジトリの `Settings > Secrets and variables > Actions` に登録します。

- Secret 名: `AWS_ROLE_ARN`
- 値: `terraform output github_actions_role_arn` の結果

補足:

- `github_repo` はデフォルトで `bedrock-finops-automation`
- 別リポジトリ名で使う場合は `-var="github_repo=..."` を追加

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

### 4. Chatwork 用の機密情報を AWS に登録する

`chatwork-notifier` Lambda は以下を参照します。

- API トークン: Secrets Manager
- ルーム ID: SSM Parameter Store

登録コマンド:

```bash
aws secretsmanager create-secret \
  --name "bedrock-finops-automation/chatwork-api-token" \
  --secret-string '{"api_token":"YOUR_CHATWORK_API_TOKEN"}' \
  --region ap-northeast-1
```

```bash
aws ssm put-parameter \
  --name "/bedrock-finops-automation/chatwork-room-id" \
  --value "YOUR_CHATWORK_ROOM_ID" \
  --type "String" \
  --region ap-northeast-1
```

すでに存在する場合は更新します。

```bash
aws secretsmanager put-secret-value \
  --secret-id "bedrock-finops-automation/chatwork-api-token" \
  --secret-string '{"api_token":"YOUR_CHATWORK_API_TOKEN"}' \
  --region ap-northeast-1
```

```bash
aws ssm put-parameter \
  --name "/bedrock-finops-automation/chatwork-room-id" \
  --value "YOUR_CHATWORK_ROOM_ID" \
  --type "String" \
  --overwrite \
  --region ap-northeast-1
```

### 5. `terraform.tfvars` を確認する

`environments/dev/terraform.tfvars` は初期状態で次の内容です。

```hcl
aws_region   = "ap-northeast-1"
environment  = "dev"
project_name = "bedrock-finops-automation"
owner        = "your-name"
cost_center  = "personal"
```

最低でも `owner` は自分用に変えておくのがおすすめです。

例:

```hcl
owner        = "takuya"
cost_center  = "personal-lab"
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

### 7. GitHub Actions 用 Secret を追加する

統合テストワークフローでは `STATE_MACHINE_ARN` も使います。
dev 環境の apply 後に GitHub に登録してください。

```bash
terraform output -raw state_machine_arn
```

GitHub の `Settings > Secrets and variables > Actions` に次を登録します。

- `AWS_ROLE_ARN`
- `STATE_MACHINE_ARN`

### 8. ローカルで最低限の確認をする

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

### 9. Step Functions を手動実行して動作確認する

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

### 10. S3 に成果物が出力されているか確認する

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

### 11. GitHub Actions の統合テストを使う

GitHub に `AWS_ROLE_ARN` と `STATE_MACHINE_ARN` を登録済みなら、Actions から E2E テストも実行できます。

手順:

1. GitHub の `Actions` タブを開く
2. `Integration Test` ワークフローを選ぶ
3. `Run workflow` を押す
4. `target_year_month` を空欄にすると前月、`2025-01` のように入れると対象月指定で実行

### 12. 毎月自動実行を有効化する

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

特に `ai-reporter` と `chatwork-notifier` は外部サービス連携を含むので確認しやすいです。

### Chatwork

- 通知が実際に投稿されているか
- HTML レポート URL が開けるか
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

## トラブルシュート

### `terraform init` が backend 作成前に失敗する

`tfstate-bedrock-finops-automation` と `tfstate-lock-bedrock-finops` が未作成の可能性があります。先に README の手順 3 を実施してください。

### GitHub Actions で AWS 認証に失敗する

確認点:

- `AWS_ROLE_ARN` が GitHub Secrets に登録されているか
- `bootstrap` の `github_owner` が正しいか
- リポジトリ名を変えている場合は `github_repo` を合わせたか

### Chatwork 通知だけ失敗する

確認点:

- Secrets Manager の `bedrock-finops-automation/chatwork-api-token`
- SSM Parameter Store の `/bedrock-finops-automation/chatwork-room-id`
- Chatwork API トークンの権限
- Chatwork ルーム ID の指定ミス

### Bedrock 呼び出しで失敗する

確認点:

- 対象 AWS アカウントで Bedrock の利用申請が済んでいるか
- 利用リージョンが `ap-northeast-1` になっているか

## 参考ドキュメント

- 詳細設計: [ARCHITECTURE.md](./ARCHITECTURE.md)
- GitHub Actions OIDC ロール作成: `bootstrap/`
- dev 環境エントリポイント: `environments/dev/`

## 最後に実行する順番だけもう一度

最短で進めるならこの順番です。

1. `.venv` を作る
2. `bootstrap/` で OIDC ロールを作る
3. tfstate 用 S3 / DynamoDB を作る
4. Chatwork 用の Secret / Parameter を作る
5. `environments/dev` で `terraform init`, `plan`, `apply`
6. `pytest` を流す
7. Step Functions を手動実行する
8. 問題なければ scheduler を `enabled = true` にして再 apply する
