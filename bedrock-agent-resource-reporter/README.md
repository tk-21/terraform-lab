# bedrock-agent-resource-reporter

Amazon Bedrock Agent を使い、AWSリソースの自律調査・Markdownレポート生成・S3保存・SNS通知を行うエージェントを Terraform でゼロから構築する個人検証プロジェクト。

## このハンズオンで得られること

- Bedrock Agent が Lambda ベースの複数ツールをどうオーケストレーションするかを体験できる
- Terraform で Bedrock Agent / Lambda / S3 / SNS / KMS をまとめて構築する流れを学べる
- 自然言語の指示から AWS リソース調査レポートを生成し、S3 保存と通知までつなげる実装例を確認できる
- 「Agent 向きの処理」と「通常のワークフロー実装向きの処理」の違いを具体例で理解できる
- 検証後にどのリソースを確認し、どこにコストがかかるかまで一通り把握できる

## 概要

「東京リージョンのEC2一覧を調べてS3にレポートを保存して」という1文を入力するだけで、エージェントが複数ステップを自律的に実行します。

```
ユーザー入力
    │
    ▼
Bedrock Agent (Claude 3 Haiku)
    │
    ├─ aws-inspector Lambda  ──▶ EC2 / Cost Explorer / CloudWatch
    ├─ report-writer Lambda  ──▶ S3 (SSE-KMS, Markdown形式)
    └─ notifier Lambda       ──▶ SNS メール通知
```

## 動作例

以下は Bedrock コンソールの Test パネルでの実際のやりとりイメージです。

### 入力プロンプト

```
東京リージョンのEC2一覧を調べてS3にレポートを保存して、SNSで通知してください。
```

---

### エージェントの動き（コンソール上で可視化される）

```
Step 1  aws-inspector::listEc2Instances を呼び出す
        → { "region": "ap-northeast-1" }

Step 2  aws-inspector::getCostAndUsage を呼び出す
        → {}

Step 3  aws-inspector::getCwAlarms を呼び出す
        → {}

Step 4  report-writer::generateReport を呼び出す
        → { "title": "東京リージョン AWSリソースレポート", "data": { ... } }

Step 5  report-writer::saveToS3 を呼び出す
        → { "title": "東京リージョン AWSリソースレポート", "content": "..." }

Step 6  notifier::sendSnsNotification を呼び出す
        → { "subject": "AWSリソースレポート完了", "message": "...", "report_uri": "s3://..." }
```

---

### エージェントの最終返答

```
東京リージョンのAWSリソース調査が完了しました。

【調査結果】
- EC2インスタンス: 3台 (running: 2台、stopped: 1台)
- 直近30日のコスト: 上位サービスは Amazon EC2 ($12.34)、Amazon S3 ($0.45)
- CloudWatchアラーム: 2件 (OK: 1件、ALARM: 1件)

【レポート保存先】
s3://bedrock-agent-reporter-reports-123456789012/reports/2025-03-21/東京リージョン_AWSリソースレポート.md

SNS通知を送信しました。登録済みのメールアドレスに通知が届きます。
```

---

### S3 に保存される Markdown レポートの内容

```markdown
# 東京リージョン AWSリソースレポート

**Generated at:** 2025-03-21 10:23:45 UTC

## Summary

### EC2 Instances

Region: ap-northeast-1 | Count: 3

- `i-0abc1234def56789a` (t3.micro) - running - web-server-01
- `i-0abc1234def56789b` (t3.small) - running - api-server-01
- `i-0abc1234def56789c` (t3.micro) - stopped - batch-worker-01

### Cost Summary

Period: 2025-02-19 to 2025-03-21

- Amazon EC2: 12.3400 USD
- Amazon S3: 0.4500 USD
- AWS Key Management Service: 1.0000 USD
- AmazonCloudWatch: 0.0000 USD

### CloudWatch Alarms

Total: 2

- HighCPUAlarm: ALARM
- DiskSpaceAlarm: OK
```

---

### SNS で届くメール

```
件名: AWSリソースレポート完了

EC2インスタンス3台、コスト情報、CloudWatchアラーム2件の調査が完了しました。

Report saved to: s3://bedrock-agent-reporter-reports-123456789012/reports/2025-03-21/東京リージョン_AWSリソースレポート.md

Timestamp: 2025-03-21 10:23:52 UTC
```

---

### その他のプロンプト例

```
# コストだけ確認してメールで教えて（S3保存なし）
今月のAWSコストをサービス別に教えてください。

# 過去レポートを確認する
これまでに保存したレポートの一覧を見せて。

# アラームが発生しているか確認する
CloudWatchアラームで問題が起きているものはある？
```

## なぜ Bedrock Agent を使うのか

### このシステムがやりたいこと

「EC2を調べて、レポートを作って、S3に保存して、通知する」という **複数ステップの処理を1文の指示で動かすこと**。

### Agent なしで実現しようとすると

Lambda や Step Functions で実現しようとすると、以下を全部コードで書く必要があります。

```
1. EC2 を調べる
2. コストを調べる
3. CloudWatch アラームを調べる
4. 上記3つのデータでレポートを生成する
5. レポートを S3 に保存する
6. 保存先 URL を SNS に通知する
```

処理の **順序・条件分岐・データの受け渡し** をすべて事前に設計・実装しなければなりません。
「コストだけ調べて通知する」「過去レポートを一覧で見せて」といった別の指示には対応できません。

### Agent を使うと何が変わるか

| | Agent なし（Step Functions 等） | Bedrock Agent |
|---|---|---|
| 処理の順序 | 事前にコードで固定 | 指示に応じて LLM が動的に決定 |
| ツールの選択 | 全ステップを必ず実行 | 必要なツールだけを呼び出す |
| 指示の変更 | コード修正が必要 | プロンプトを変えるだけ |
| データの受け渡し | 自前で実装 | Agent が前ステップの結果を次に渡す |

### 具体例

同じ仕組みで、以下のような**異なる指示**にも対応できます。

```
# EC2 だけ調べて通知（レポート保存なし）
「東京リージョンの EC2 インスタンスを確認してメールで教えて」

# コストレポートだけ作る
「今月のコストをサービス別にまとめてレポートを S3 に保存して」

# 過去レポートを参照する
「先週保存したレポートの一覧を見せて」
```

Step Functions でこれを実現するには、それぞれ別のワークフローを定義する必要があります。
Agent では**プロンプトを変えるだけ**で同じインフラが使い回せます。

### まとめ

Bedrock Agent は「ツール（Lambda）を何をどの順番で呼ぶか」を LLM に委ねる仕組みです。
**処理の順序が固定できない・指示が自然言語で来る・ステップ数が可変**、という条件が揃う場合に Agent が有効です。

## ディレクトリ構成

```
bedrock-agent-resource-reporter/
├── environments/
│   └── dev/
│       ├── main.tf          # KMS / S3 / SNS + モジュール呼び出し
│       ├── variables.tf
│       ├── terraform.tfvars
│       └── versions.tf
├── modules/
│   ├── networking/          # VPC, サブネット, NAT GW, VPCエンドポイント
│   ├── bedrock-agent/       # Agent 本体, Action Groups (OpenAPI), IAM ロール
│   └── lambda-actions/      # Lambda 3関数 + IAM ロール + Bedrock 呼び出し許可
│       └── src/
│           ├── aws_inspector/main.py
│           ├── report_writer/main.py
│           └── notifier/main.py
└── docs/
    └── architecture.md
```

## Action Groups

| グループ名 | ツール | 説明 |
|---|---|---|
| `aws-inspector` | `getCostAndUsage` | 過去30日のサービス別コストを取得 |
| | `listEc2Instances` | 指定リージョンのEC2インスタンス一覧 |
| | `getCwAlarms` | CloudWatchアラームの状態一覧 |
| `report-writer` | `generateReport` | Markdownレポートを生成 |
| | `saveToS3` | レポートをS3に保存 |
| | `listPastReports` | 過去30日のレポート一覧を取得 |
| `notifier` | `sendSnsNotification` | SNSで完了通知を送信 |

## インフラ構成

| リソース | 設定 |
|---|---|
| リージョン | ap-northeast-1 |
| Bedrock モデル | Claude 3 Haiku（`bedrock_model_id` で変更可） |
| VPC | 10.0.0.0/16、パブリック×2 / プライベート×2 |
| NAT Gateway | 1つのみ（コスト最適化） |
| VPC Endpoint | S3 (Gateway) |
| S3 | SSE-KMS + バージョニング + パブリックアクセスブロック |
| Lambda メモリ | 256 MB（上限 512 MB） |
| 月額目安 | ~$7（軽量テスト時） |

## ハンズオン実行手順

このハンズオンは、以下の流れで進めると迷いません。

| フェーズ | やること | 目安時間 |
|---|---|---|
| 1. 事前準備 | ツール確認、AWS認証、Bedrockモデルアクセス有効化 | 10〜15分 |
| 2. 設定確認 | `terraform.tfvars` の確認、必要なら値を変更 | 5分 |
| 3. デプロイ | `terraform init` → `terraform plan` → `terraform apply` | 10分前後 |
| 4. 動作確認 | Bedrock Agent を実行し、S3 と SNS の結果を確認 | 10分 |
| 5. 後片付け | 検証終了後に `terraform destroy` | 5分 |

> 注意: `terraform apply` と `terraform destroy` はこのリポジトリの運用ポリシー上、ユーザー自身が実行してください。

### 0. まずゴールを確認する

この README の手順を最後まで実施すると、次の状態になります。

- Bedrock Agent が東京リージョンの EC2 / Cost Explorer / CloudWatch を調査できる
- 調査結果を Markdown レポートとして S3 に保存できる
- 必要に応じて SNS で通知できる
- Bedrock コンソールまたは AWS CLI から Agent を試せる

### 1. 前提条件を確認する

以下が揃っていることを確認してください。

| 項目 | 確認コマンド | 必要バージョン・状態 |
|---|---|---|
| Terraform | `terraform version` | `>= 1.7` |
| AWS CLI | `aws --version` | v2 推奨 |
| Python | `python3 --version` | 3.11 以上 |
| AWS 認証情報 | `aws sts get-caller-identity` | 正常応答すること |

```bash
terraform version
aws --version
python3 --version
aws sts get-caller-identity
```

`aws sts get-caller-identity` が失敗する場合は、先に AWS 認証設定を済ませてください。

### 2. リポジトリに移動する

```bash
cd /path/to/terraform-lab/bedrock-agent-resource-reporter
ls -la
```

`README.md`、`environments/`、`modules/` が見えていれば問題ありません。

### 3. AWS 認証情報を設定する

IAM ユーザーまたは IAM ロールを利用してください。root アカウントは使いません。

#### 必要な IAM 権限

手早く検証する場合は、少なくとも以下に相当する権限が必要です。

```text
AmazonBedrockFullAccess
AmazonS3FullAccess
AWSLambda_FullAccess
AmazonSNSFullAccess
AmazonVPCFullAccess
AWSKeyManagementServicePowerUser
IAMFullAccess
CloudWatchFullAccess
```

#### 設定方法

```bash
# 推奨: AWS CLI プロファイルを使用
aws configure --profile handson

export AWS_PROFILE=handson
export AWS_DEFAULT_REGION=ap-northeast-1

# 確認
aws sts get-caller-identity
```

環境変数で直接指定する場合は、`AWS_ACCESS_KEY_ID`、`AWS_SECRET_ACCESS_KEY`、`AWS_DEFAULT_REGION` を設定してください。

### 4. Bedrock のモデルアクセスを有効化する

Claude 3 Haiku のモデルアクセスがないと、Terraform で Agent を作成しても利用できません。デプロイ前に必ず確認します。

1. AWS コンソールでリージョンを `ap-northeast-1` に切り替える
2. `Amazon Bedrock` を開く
3. 左メニューの `Model access` を開く
4. `Manage model access` を押す
5. `Anthropic` の `Claude 3 Haiku` を選択する
6. `Request model access` を実行する
7. ステータスが `Access granted` になることを確認する

> モデルアクセスはリージョン単位です。東京リージョン `ap-northeast-1` で有効になっていることが重要です。

### 5. `terraform.tfvars` を確認する

まずはデフォルト値のままで問題ありません。変更したい場合だけ編集してください。

```bash
sed -n '1,120p' environments/dev/terraform.tfvars
```

主に確認する値は以下です。

```hcl
region           = "ap-northeast-1"
bedrock_model_id = "anthropic.claude-3-haiku-20240307-v1:0"
vpc_cidr         = "10.0.0.0/16"
```

コストを抑えて試すなら、`bedrock_model_id` は既定の Claude 3 Haiku のままにするのがおすすめです。

### 6. Terraform でデプロイ準備をする

```bash
cd environments/dev
terraform init
terraform plan
```

確認ポイントは次のとおりです。

- `terraform init` が `Terraform has been successfully initialized!` で終わる
- `terraform plan` の末尾に `Plan: XX to add, 0 to change, 0 to destroy.` が表示される
- 予期しないリージョンやリソース名になっていない

ここまで問題なければ、実際の作成コマンドはユーザー自身で実行してください。

```bash
terraform apply
```

完了後は、少なくとも以下の出力が得られることを確認します。

```text
agent_alias_id
agent_arn
agent_id
reports_bucket_name
sns_topic_arn
```

### 7. デプロイ後の出力値を確認する

あとでテストや確認に使うため、出力値を控えておくとスムーズです。

```bash
terraform output
```

個別に見る場合は以下を使います。

```bash
terraform output -raw agent_id
terraform output -raw agent_alias_id
terraform output -raw reports_bucket_name
terraform output -raw sns_topic_arn
```

### 8. SNS 通知を受け取りたい場合は購読設定をする

メール通知を試したい場合のみ実施してください。

#### コンソールで設定する方法

1. `Amazon SNS` を開く
2. `トピック` から `bedrock-agent-reporter-notifications` を開く
3. `サブスクリプションの作成` を押す
4. プロトコルに `Eメール` を選ぶ
5. 自分のメールアドレスを入力して作成する
6. 届いた確認メールの `Confirm subscription` を開く

#### CLI で設定する方法

```bash
SNS_ARN=$(terraform output -raw sns_topic_arn)

aws sns subscribe \
  --topic-arn "$SNS_ARN" \
  --protocol email \
  --notification-endpoint your-email@example.com \
  --region ap-northeast-1
```

CLI で作成した場合も、確認メールのリンクをクリックしないと通知は届きません。

### 9. Bedrock Agent をテストする

最初の動作確認は、ステップ実行の様子が見えるコンソール実行がおすすめです。

#### 方法 A: AWS コンソールから試す

1. `Amazon Bedrock` を開く
2. `Agents` を開く
3. `bedrock-agent-resource-reporter` を選ぶ
4. `Test` パネルまたは `Test agent` を開く
5. エイリアスに `TestAlias` を選ぶ
6. 次のプロンプトを入力して実行する

```text
東京リージョンのEC2一覧を調べてS3にレポートを保存して、SNSで通知してください。
```

期待する動きは以下です。

- `aws-inspector` 系のアクションが呼ばれる
- `report-writer` が Markdown レポートを生成し、S3 に保存する
- `notifier` が SNS 通知を送る

#### 方法 B: AWS CLI から試す

```bash
AGENT_ID=$(terraform output -raw agent_id)
ALIAS_ID=$(terraform output -raw agent_alias_id)

aws bedrock-agent-runtime invoke-agent \
  --agent-id "$AGENT_ID" \
  --agent-alias-id "$ALIAS_ID" \
  --session-id "session-$(date +%s)" \
  --input-text "東京リージョンのEC2一覧を調べてS3にレポートを保存して" \
  --region ap-northeast-1 \
  /tmp/response.json

cat /tmp/response.json
```

#### 試しやすい追加プロンプト

```text
今月のAWSコストをサービス別に教えてください。
CloudWatchアラームで問題が起きているものはありますか？
これまでに保存したレポートの一覧を見せてください。
```

### 10. 結果を確認する

#### S3 にレポートが保存されたか確認する

```bash
BUCKET=$(terraform output -raw reports_bucket_name)

aws s3 ls "s3://${BUCKET}/reports/" \
  --recursive \
  --region ap-northeast-1
```

一覧に Markdown ファイルが見えたら保存成功です。中身を見る場合は、実際のキーを指定して取得します。

```bash
aws s3 cp "s3://${BUCKET}/reports/<YYYY-MM-DD>/<ファイル名>.md" - \
  --region ap-northeast-1
```

#### Lambda ログを確認する

期待した結果にならないときは、どの関数で止まったかを先に見るのが近道です。

```bash
aws logs tail /aws/lambda/bedrock-agent-aws-inspector \
  --since 30m \
  --region ap-northeast-1

aws logs tail /aws/lambda/bedrock-agent-report-writer \
  --since 30m \
  --region ap-northeast-1

aws logs tail /aws/lambda/bedrock-agent-notifier \
  --since 30m \
  --region ap-northeast-1
```

### 11. 検証が終わったら削除する

NAT Gateway と KMS キーは放置すると課金が続きます。検証が終わったら、必ずリソースを片付けてください。

```bash
BUCKET=$(terraform output -raw reports_bucket_name)
aws s3 rm "s3://${BUCKET}" --recursive --region ap-northeast-1
```

その後、ユーザー自身で以下を実行してください。

```bash
terraform destroy
```

### よくあるつまずき

#### `Error: Error creating Bedrock Agent`

Bedrock のモデルアクセスが有効になっていない可能性があります。まず Step 4 を見直してください。

```bash
aws bedrock list-foundation-models \
  --by-provider Anthropic \
  --region ap-northeast-1 \
  --query 'modelSummaries[?modelId==`anthropic.claude-3-haiku-20240307-v1:0`]'
```

#### `AccessDeniedException`

AWS 認証情報か IAM 権限不足の可能性が高いです。

```bash
aws sts get-caller-identity
```

#### Agent が Lambda を呼び出せない

デプロイ直後は Agent の準備完了まで少し時間がかかることがあります。

```bash
aws bedrock list-agents --region ap-northeast-1
```

ステータスが `PREPARED` になってから再試行してください。

## コスト試算

### 常時稼働コスト（月額固定）

| リソース | 単価 | 月額目安 |
|---|---|---|
| NAT Gateway | $0.062/h + $0.062/GB | ~$5 |
| KMS キー | $1/キー/月 | $1 |
| **固定合計** | | **~$6/月** |

### 従量課金（使った分だけ）

| リソース | 単価 | テスト数回時の目安 |
|---|---|---|
| Bedrock Claude 3 Haiku | 入力 $0.00025/1K tokens、出力 $0.00125/1K tokens | $0.01〜$0.05/回 |
| Lambda 実行 | 月100万回まで無料 | ほぼ $0 |
| S3 ストレージ | $0.025/GB/月 | ほぼ $0 |
| SNS | $0.50/100万通 | ほぼ $0 |

### 月額合計目安

| ケース | 目安 |
|---|---|
| デプロイしただけ（未使用） | ~$6 |
| テスト数回実施 | ~$7〜$8 |
| 上限（CLAUDE.md 設定） | $20 |

### 注意事項

- NAT Gateway と VPC Interface Endpoint は **デプロイ中は常時課金**されます
- 検証が終わったら必ず `terraform destroy` で削除してください
- root アカウントは使用せず、必要な IAM 権限を持つ IAM ユーザー/ロールで実行してください

## 設計方針

- **IaC**: Terraform モジュール分割（networking / bedrock-agent / lambda-actions）
- **認証**: IAM ロールのみ（アクセスキー禁止）
- **最小権限**: Lambda ごとに独立した IAM ロール、Bedrock Agent の呼び出し元を `source_arn` で限定
- **コスト制約**: NAT GW 1つ・Lambda 256 MB・Claude 3 Haiku・月額 $20 上限

## タグ

全リソースに以下のタグを付与（`provider default_tags` で自動適用）:

```hcl
Environment = "dev"
Project     = "bedrock-agent-resource-reporter"
Owner       = "your-name"
```
