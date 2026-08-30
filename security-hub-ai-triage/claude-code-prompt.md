# security-hub-ai-triage — Claude Code 統合プロンプト

## 依頼内容

以下の仕様に従い、`security-hub-ai-triage` プロジェクトのすべてのファイルを生成してください。
CLAUDE.md に記載されたディレクトリ構成どおりに、すべてのファイルを実装してください。

---

## 生成対象ファイル一覧

### Terraform

**terraform/variables.tf**
以下の変数を定義する：
- `project_name`（default: `"security-hub-ai-triage"`）
- `environment`（default: `"dev"`）
- `aws_region`（default: `"ap-northeast-1"`）
- `sns_notification_email`（SNS メール通知先）
- `bedrock_model_id`（default: `"jp.anthropic.claude-haiku-4-5-20251001-v1:0"`）

**terraform/main.tf**
以下のモジュールを呼び出す：
- `module "iam"` - Lambda 実行ロール
- `module "dynamodb"` - 重複排除テーブル
- `module "s3"` - レポート保存バケット
- `module "sns"` - 高優先度 Finding の通知 Topic とメール購読
- `module "lambda"` - triage-handler 関数
- `module "eventbridge"` - Security Hub Findings ルール

**terraform/modules/iam/main.tf**
Lambda 実行ロールに以下の権限を最小権限で付与する：
- `bedrock:InvokeModel`（対象リソース: Haiku モデルの ARN のみ）
- `dynamodb:GetItem`, `dynamodb:PutItem`（対象リソース: テーブル ARN のみ）
- `s3:PutObject`（対象リソース: バケット ARN/* のみ）
- `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`
- `sns:Publish`（対象リソース: SNS Topic ARN のみ）

**terraform/modules/dynamodb/main.tf**
CLAUDE.md のテーブル設計に従い、TTL 有効の DynamoDB テーブルを作成する。
billing_mode は PAY_PER_REQUEST とする。

**terraform/modules/s3/main.tf**
CLAUDE.md のバケット設定に従い作成する。
バケット名: `${var.project_name}-reports-${data.aws_caller_identity.current.account_id}`

**terraform/modules/lambda/main.tf**
- ランタイム: python3.12、アーキテクチャ: arm64
- ソースコード: `../../lambda/triage_handler/` を ZIP 化してデプロイ
- 環境変数: `DYNAMODB_TABLE_NAME`, `S3_BUCKET_NAME`, `SNS_TOPIC_ARN`,
  `BEDROCK_MODEL_ID` を渡す
- `archive_file` data source で ZIP を生成する

**terraform/modules/eventbridge/main.tf**
CLAUDE.md のイベントパターンで EventBridge ルールを作成し、Lambda をターゲットとする。
Lambda の resource-based policy（`aws_lambda_permission`）も忘れずに追加する。

---

### Lambda（Python 3.12）

**lambda/triage_handler/requirements.txt**
```
boto3>=1.34.0
```
（boto3 は Lambda ランタイムに含まれるが、ローカルテスト用に記載する）

**lambda/triage_handler/handler.py**

以下の処理を実装する：

```
1. EventBridge イベントから Security Hub Findings を抽出
   - event["detail"]["findings"] がリストのため、ループで処理
2. 各 Finding に対して：
   a. DedupChecker で重複チェック → 処理済みならスキップ
   b. Finding から必要フィールドを抽出（FindingId, Title, Severity.Label,
      Resources[0].Type, Resources[0].Id, Description）
   c. BedrockClient でトリアージ実行
   d. Severity が CRITICAL または HIGH の場合、SnsNotifier で通知
   e. ReportSaver で S3 に保存
   f. DedupChecker で処理済みとして記録（verdict と risk_score も保存）
3. 処理件数・スキップ件数をログ出力して返す
```

すべての関数に docstring を記載し、AWS API 呼び出し箇所には使用する IAM アクションをコメントで記載すること。

**lambda/triage_handler/bedrock_client.py**

以下の仕様で実装する：
- `BedrockClient` クラスとして実装
- `boto3.client("bedrock-runtime")` を使用
- `invoke_model()` で CLAUDE.md のシステムプロンプト・ユーザープロンプトを渡す
- レスポンスから JSON を安全にパースする（Markdown コードブロック除去処理を含める）
- `ThrottlingException` に対して指数バックオフ（1秒→2秒→4秒、最大3回）でリトライ
- パース失敗時は `verdict: "監視継続", risk_score: 5` のデフォルト値を返す（処理を止めない）
- ユーザープロンプトに含める情報: FindingTitle, Severity, ResourceType, ResourceId,
  Description, 検出リージョン

**lambda/triage_handler/sns_notifier.py**

以下の仕様で実装する：
- `SnsNotifier` クラスとして実装
- `boto3.client("sns")` を使用して Topic ARN に publish
- SNS の件名・本文を組み立てる
- 通知失敗は例外を raise せず、エラーログを出力して `False` を返す

**lambda/triage_handler/dedup_checker.py**

以下の仕様で実装する：
- `DedupChecker` クラスとして実装
- `is_processed(finding_id: str) -> bool` メソッド: DynamoDB に GetItem して処理済みか確認
- `mark_processed(finding_id: str, verdict: str, risk_score: int) -> None` メソッド:
  処理済みとして PutItem（ttl = 現在時刻 + 7日のエポック秒を計算して設定）
- 日時は JST で扱う（`datetime.timezone(datetime.timedelta(hours=9))`）

**lambda/triage_handler/report_saver.py**

以下の仕様で実装する：
- `ReportSaver` クラスとして実装
- `save(finding: dict, triage_result: dict) -> str` メソッド: S3 に保存して オブジェクトキーを返す
- キー形式: `findings/{year}/{month}/{day}/{finding_id_sanitized}.json`
  （finding_id の `/` や `:` を `-` に置換してファイル名として安全にする）
- 保存内容は CLAUDE.md の JSON フォーマットに従う
- `processed_at` は JST の ISO8601 形式

---

### GitHub Actions

**.github/workflows/deploy.yml**

CLAUDE.md の設計に従い、以下を実装する：
- PR 時: `terraform fmt -check`, `terraform validate`, `terraform plan`
- main マージ時: `terraform apply -auto-approve`
- Lambda の ZIP ファイルを生成するステップを `terraform apply` の前に追加する
  （`pip install -r requirements.txt -t ./package && zip -r lambda.zip .`）
- Plan 結果を PR コメントに投稿する（`actions/github-script` を使用）

---

### その他

**.gitignore**
以下を含める：
```
*.tfvars
!*.tfvars.example
.terraform/
.terraform.lock.hcl
__pycache__/
*.pyc
*.zip
.env
```

**terraform/terraform.tfvars.example**
```hcl
project_name           = "security-hub-ai-triage"
environment            = "dev"
sns_notification_email = "your-email@example.com"
```

**README.md**
以下のセクションで構成する：
1. プロジェクト概要（アーキテクチャ図はテキストの矢印で表現）
2. 前提条件（AWS CLI, Terraform, Python 3.12, Security Hub 有効化）
3. セットアップ手順（SNS 通知先メールアドレス設定 → terraform init → apply → 購読確認）
4. 動作確認方法（Security Hub のテスト検出結果を手動生成する方法）
5. コスト目安
6. 注意事項（Security Hub は使用後に無効化しないとコストが発生し続ける）

---

## 実装完了後の確認事項

以下をすべて満たしているか確認してから完了を報告してください：

- [ ] `terraform validate` が通る構成になっているか
- [ ] Lambda の IAM ロールに `*` ワイルドカードが使われていないか
- [ ] Lambda の `sns:Publish` が対象 SNS Topic ARN のみに制限されているか
- [ ] DynamoDB の TTL が正しく設定されているか（属性名 `ttl`, エポック秒）
- [ ] S3 バケットのパブリックアクセスがすべてブロックされているか
- [ ] EventBridge の `aws_lambda_permission` が設定されているか
- [ ] すべての Python 関数に docstring が記載されているか
- [ ] Bedrock レスポンスの Markdown コードブロック除去処理が含まれているか
- [ ] 日時表示がすべて JST になっているか
