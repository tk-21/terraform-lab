# bedrock-agent-resource-reporter

Amazon Bedrock Agent を使い、AWSリソースの自律調査・Markdownレポート生成・S3保存・SNS通知を行うエージェントを Terraform でゼロから構築する個人検証プロジェクト。

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

## 使い方

### 前提条件

- Terraform >= 1.7
- AWS CLI 設定済み（IAM ユーザー or ロール。root アカウント不要）
- Bedrock の Claude 3 Haiku モデルアクセスを有効化済み
  - AWS コンソール → Amazon Bedrock → Model access → Claude 3 Haiku を有効化

### 1. デプロイ

```bash
cd environments/dev

terraform init
terraform plan
terraform apply
```

### 2. SNS通知の受信設定（メール通知を受け取る場合）

```bash
# デプロイ後、SNS トピック ARN を確認
terraform output
```

AWS コンソール → SNS → トピック `bedrock-agent-reporter-notifications` → サブスクリプションの作成 → メールアドレスを登録 → 届いた確認メールのリンクをクリック

### 3. エージェントへの質問

#### 方法A: AWS コンソール（推奨）

1. AWS コンソール → **Amazon Bedrock** → 左メニュー **Agents**
2. `bedrock-agent-resource-reporter` をクリック
3. 画面右側の **Test** パネルにプロンプトを入力して **Run**

```
東京リージョンのEC2一覧を調べてS3にレポートを保存して、SNSで通知してください。
```

エージェントが `aws-inspector` → `report-writer` → `notifier` の順で自律的に動きます。

#### 方法B: AWS CLI

```bash
# デプロイ後に Agent ID / Alias ID を取得
AGENT_ID=$(terraform output -raw agent_id)
ALIAS_ID=$(terraform output -raw agent_alias_id)

# エージェントに質問を送る
aws bedrock-agent-runtime invoke-agent \
  --agent-id $AGENT_ID \
  --agent-alias-id $ALIAS_ID \
  --session-id "session-$(date +%s)" \
  --input-text "東京リージョンのEC2一覧を調べてS3にレポートを保存して" \
  --region ap-northeast-1 \
  response.json

cat response.json
```

### 4. レポートの確認

保存されたレポートは S3 バケットで確認できます。

```bash
# バケット名を確認
terraform output -raw reports_bucket_name

# レポート一覧を表示
aws s3 ls s3://<バケット名>/reports/ --region ap-northeast-1
```

### 5. 削除

```bash
# S3 バケット内のオブジェクトを先に削除
aws s3 rm s3://<バケット名> --recursive --region ap-northeast-1

terraform destroy
```

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
