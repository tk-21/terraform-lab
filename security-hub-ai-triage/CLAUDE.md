# CLAUDE.md - security-hub-ai-triage

## プロジェクト概要

Security Hub の検出結果を EventBridge で受け取り、Lambda + Amazon Bedrock（Claude Haiku）で
自動トリアージ（即対応 / 監視継続 / 無視可能）を行い、Amazon SNS でメール通知するシステム。
重複排除に DynamoDB、フルレポート保存に S3 を使用する。

## ゴール

- Security Hub のアラートノイズを AI で自動分類し、対応優先度を明確化する
- CRITICAL/HIGH のみ Amazon SNS 通知し、エンジニアの疲弊を防ぐ
- すべてのインフラを Terraform で管理し、GitHub Actions（OIDC）で自動デプロイする

---

## ディレクトリ構成

以下の構成でファイルを生成すること。

```
security-hub-ai-triage/
├── terraform/
│   ├── modules/
│   │   ├── eventbridge/
│   │   │   ├── main.tf          # EventBridge ルール・ターゲット
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   ├── lambda/
│   │   │   ├── main.tf          # Lambda Function リソース
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   ├── dynamodb/
│   │   │   ├── main.tf          # 重複排除テーブル（TTL: 7日）
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   ├── s3/
│   │   │   ├── main.tf          # フルレポート保存バケット
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   └── iam/
│   │       ├── main.tf          # Lambda 実行ロール・ポリシー
│   │       ├── variables.tf
│   │       └── outputs.tf
│   ├── main.tf                  # モジュール呼び出し
│   ├── variables.tf             # 共通変数（region, project_name, SNS 通知先等）
│   ├── outputs.tf
│   └── terraform.tfvars.example # .gitignore 対象の example ファイル
├── lambda/
│   └── triage_handler/
│       ├── handler.py           # メインエントリーポイント
│       ├── bedrock_client.py    # Bedrock 呼び出しラッパー
│       ├── sns_notifier.py      # Amazon SNS 通知
│       ├── dedup_checker.py     # DynamoDB 重複チェック
│       ├── report_saver.py      # S3 保存
│       └── requirements.txt
├── .github/
│   └── workflows/
│       └── deploy.yml           # OIDC 認証 + terraform plan/apply
├── .gitignore
├── CLAUDE.md                    # このファイル
└── README.md
```

---

## 技術スタック・制約

| 項目 | 値 |
|------|-----|
| AWS リージョン | ap-northeast-1（東京）|
| Terraform バージョン | ~> 1.7 |
| Python バージョン | 3.12 |
| Bedrock 推論プロファイル | jp.anthropic.claude-haiku-4-5-20251001-v1:0 |
| 通知先 | Amazon SNS（メール） |
| 認証方式 | GitHub Actions OIDC（アクセスキー不使用）|
| Lambda アーキテクチャ | arm64（Graviton / コスト削減）|
| Lambda メモリ | 256MB |
| Lambda タイムアウト | 30秒 |

---

## Terraform 実装規約

### 命名規則
- リソース名: `{project_name}-{role}` 例: `security-hub-ai-triage-triage-handler`
- モジュール名: スネークケース 例: `module "lambda" {}`
- 変数名: スネークケース

### 共通タグ
すべてのリソースに以下のタグを付与すること：
```hcl
tags = {
  Project     = var.project_name
  Environment = var.environment
  ManagedBy   = "terraform"
}
```

### IAM ポリシー設計（最小権限）
Lambda 実行ロールに付与する権限：
- `bedrock:InvokeModel` - Bedrock モデル呼び出し
- `dynamodb:GetItem`, `dynamodb:PutItem` - 重複排除テーブル操作
- `s3:PutObject` - レポート保存
- `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents` - CloudWatch Logs
- `sns:Publish` - SNS Topic への通知

**禁止**: `*` ワイルドカード、`AdministratorAccess` の使用

### Amazon SNS
Terraform で SNS Topic とメール購読を作成する。Lambda の環境変数には Topic ARN のみ渡し、`sns:Publish` はその Topic に限定する。
```hcl
# terraform/variables.tf に追加
variable "sns_notification_email" {
  description = "SNS メール通知先"
  type        = string
}
```

---

## Lambda 実装規約

### handler.py の構造
```python
import json
import logging
import os
from bedrock_client import BedrockClient
from sns_notifier import SnsNotifier
from dedup_checker import DedupChecker
from report_saver import ReportSaver

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def lambda_handler(event, context):
    """
    EventBridge から Security Hub Findings を受け取り、トリアージを行う。

    Args:
        event: EventBridge イベント（Security Hub Findings フォーマット）
        context: Lambda コンテキスト

    Returns:
        dict: 処理結果サマリ
    """
    # 実装...
```

### コメント規約
- 関数・クラスには docstring を必ず記載する
- ビジネスロジックの「なぜ」をインラインコメントで説明する
- AWS API 呼び出し箇所には使用する IAM アクションをコメントで明記する

例：
```python
# iam: dynamodb:GetItem
# FindingId をキーに過去処理済みかチェック（TTL: 7日）
response = dynamodb.get_item(
    TableName=TABLE_NAME,
    Key={"finding_id": {"S": finding_id}}
)
```

### エラーハンドリング
- Bedrock 呼び出しは `ThrottlingException` を考慮し、指数バックオフでリトライ（最大3回）
- SNS 通知失敗はログ記録のみ（処理を止めない）
- DynamoDB / S3 エラーは `raise` して Lambda エラーとして記録する

---

## Bedrock プロンプト設計

### システムプロンプト
```
あなたはAWSセキュリティの専門家です。Security Hubの検出結果を分析し、
以下のJSONフォーマットのみで回答してください。説明文やMarkdownは不要です。

{
  "verdict": "即対応" | "監視継続" | "無視可能",
  "reason": "判断理由（日本語2〜3文）",
  "action": "推奨する具体的なアクション（日本語）",
  "risk_score": 1〜10の整数
}

判定基準:
- 即対応: 本番環境への即時影響リスクがある（risk_score 8以上）
- 監視継続: 対応は必要だが緊急性は低い（risk_score 4〜7）
- 無視可能: 誤検知または許容リスク（risk_score 1〜3）
```

### ユーザープロンプトに含める情報
- FindingTitle
- Severity（CRITICAL / HIGH / MEDIUM / LOW / INFORMATIONAL）
- ResourceType と ResourceId
- Description
- 検出リージョン

---

## SNS 通知フォーマット

CRITICAL / HIGH のみ通知する（MEDIUM 以下は S3 保存のみ）。

```
[info][title]🚨 Security Hub アラート - {verdict}[/title]
■ 検出名: {title}
■ 重大度: {severity}
■ リソース: {resource_id}
■ AI判定: {verdict}（リスクスコア: {risk_score}/10）
■ 理由: {reason}
■ 推奨アクション: {action}
■ 検出時刻: {detected_at}
[/info]
```

---

## EventBridge ルール設計

Security Hub の CRITICAL / HIGH のみをトリガーとする（Lambda の無駄な起動を防ぐ）。

```json
{
  "source": ["aws.securityhub"],
  "detail-type": ["Security Hub Findings - Imported"],
  "detail": {
    "findings": {
      "Severity": {
        "Label": ["CRITICAL", "HIGH", "MEDIUM", "LOW"]
      }
    }
  }
}
```

※ EventBridge ではすべて受け取り、Lambda 内で CRITICAL/HIGH のみ SNS 通知する設計とする。
  （通知要否の判断ロジックをコードで管理するため）

---

## DynamoDB テーブル設計

| 属性 | 型 | 説明 |
|------|-----|------|
| finding_id | S（PK）| Security Hub の FindingId |
| processed_at | S | ISO8601 形式の処理日時 |
| verdict | S | AI の判定結果 |
| risk_score | N | リスクスコア（1〜10）|
| ttl | N | エポック秒（処理日時 + 7日）|

TTL 属性名: `ttl`（DynamoDB TTL 機能を有効化すること）

---

## S3 保存設計

### バケット設定
- バケット名: `{project_name}-reports-{account_id}`
- バージョニング: 有効
- パブリックアクセス: すべてブロック
- サーバーサイド暗号化: SSE-S3（AES256）

### オブジェクトキー形式
```
findings/{year}/{month}/{day}/{finding_id}.json
例: findings/2025/08/01/arn-aws-securityhub-ap-northeast-1-123456-finding-abcd.json
```

### 保存内容（JSON）
```json
{
  "original_finding": { /* Security Hub Finding 原文 */ },
  "triage_result": {
    "verdict": "即対応",
    "reason": "...",
    "action": "...",
    "risk_score": 9
  },
  "processed_at": "2025-08-01T10:00:00+09:00",
  "model_id": "jp.anthropic.claude-haiku-4-5-20251001-v1:0"
}
```

---

## GitHub Actions ワークフロー設計

```yaml
# .github/workflows/deploy.yml
name: Deploy

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:
  id-token: write   # OIDC に必要
  contents: read

jobs:
  terraform:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ap-northeast-1
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "~> 1.7"
      # PR: plan のみ / main マージ: apply
```

---

## 実装時の注意事項

1. **Bedrock 推論プロファイル ID**: `jp.anthropic.claude-haiku-4-5-20251001-v1:0` を使用する（日本リージョン向け）
2. **JSON パース**: Bedrock レスポンスに Markdown コードブロックが混入する場合があるため、
   `json.loads()` 前に ` ```json ` と ` ``` ` を除去する処理を入れること
3. **Security Hub の FindingId**: ARN 形式で長いため、DynamoDB のキーとして使用する際は
   そのまま使用して問題ない（最大 2048 バイト以内）
4. **タイムゾーン**: 通知・ログの日時はすべて JST（Asia/Tokyo）で表示する
5. **Lambda パッケージ**: `requirements.txt` に記載した依存ライブラリは
   Terraform の `archive_file` でまとめて ZIP 化する
