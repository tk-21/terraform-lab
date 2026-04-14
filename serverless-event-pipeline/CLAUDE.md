# CLAUDE.md — serverless-event-pipeline

## プロジェクト概要

S3 / Kinesis / SQS × Lambda × DynamoDB / S3 によるプロダクションレベルの
**イベント駆動サーバーレスデータパイプライン**のハンズオン。

「設計できる・コードに落とせる・運用まで考えられる」を証明する転職・案件獲得向けポートフォリオ。

---

## システム全体像

```
[データ投入]
  S3 PUT / API Gateway POST / Kinesis Data Streams

      ↓ イベントトリガー

[Lambda 処理層]
  ingestor     → バリデーション・正規化
  transformer  → ビジネスロジック変換
  aggregator   → 集計処理（DynamoDB Streams トリガー）
  dlq-handler  → 失敗イベント再処理・アラート

      ↓

[ストレージ層]
  DynamoDB     → ホットデータ（PITR有効）
  S3 (Parquet) → コールドデータ・分析用

[オブザーバビリティ]
  X-Ray        → 分散トレーシング
  CloudWatch   → カスタムメトリクス・ダッシュボード
  Powertools   → 構造化ログ・トレース・メトリクス
```

---

## ディレクトリ構成

```
serverless-event-pipeline/
├── CLAUDE.md
├── README.md
├── Makefile
├── docs/
│   ├── architecture.md       # Mermaid アーキテクチャ図
│   ├── adr/                  # Architecture Decision Records
│   │   ├── 001-kinesis-vs-sqs.md
│   │   ├── 002-dynamodb-design.md
│   │   └── 003-error-handling-strategy.md
│   └── runbook.md            # 障害対応手順書
├── terraform/
│   ├── environments/
│   │   ├── dev/
│   │   └── prod/
│   └── modules/
│       ├── lambda-function/   # Lambda共通モジュール
│       ├── kinesis-pipeline/  # Kinesis + Lambda ESM
│       ├── sqs-pipeline/      # SQS + Lambda ESM（DLQ付き）
│       ├── dynamodb/          # テーブル設計・GSI・Streams
│       ├── observability/     # X-Ray・CloudWatch・アラーム
│       └── iam/               # Lambda実行ロール（最小権限）
├── src/
│   ├── ingestor/
│   │   ├── handler.py
│   │   ├── validator.py
│   │   └── requirements.txt
│   ├── transformer/
│   │   ├── handler.py
│   │   ├── transform.py
│   │   └── requirements.txt
│   ├── aggregator/
│   │   ├── handler.py
│   │   └── requirements.txt
│   ├── dlq_handler/
│   │   ├── handler.py
│   │   └── requirements.txt
│   └── shared/
│       ├── models.py          # Pydantic データモデル
│       └── utils.py
├── tests/
│   ├── unit/
│   │   ├── test_ingestor.py
│   │   ├── test_transformer.py
│   │   └── test_aggregator.py
│   └── integration/
│       └── test_pipeline_e2e.py
└── .github/
    └── workflows/
        ├── ci.yml             # PR: lint・test・terraform plan
        └── cd.yml             # main merge: terraform apply → deploy
```

---

## 命名規則

| リソース種別 | パターン | 例 |
|---|---|---|
| Lambda 関数 | `sep-<env>-<役割>` | `sep-prod-ingestor` |
| Kinesis Stream | `sep-<env>-<用途>-stream` | `sep-prod-events-stream` |
| SQS Queue | `sep-<env>-<用途>-queue` | `sep-prod-transform-queue` |
| DLQ | `sep-<env>-<用途>-dlq` | `sep-prod-transform-dlq` |
| DynamoDB Table | `sep-<env>-<用途>` | `sep-prod-events` |
| S3 Bucket | `sep-<env>-<用途>-<account_id>` | `sep-prod-archive-123456789012` |
| IAM Role | `sep-<env>-<lambda名>-role` | `sep-prod-ingestor-role` |
| CloudWatch LogGroup | `/aws/lambda/sep-<env>-<役割>` | 自動命名 |

**プロジェクト prefix**: `sep`（Serverless Event Pipeline）

---

## Lambda 設計方針

```python
# 全 Lambda に AWS Lambda Powertools を適用（必須）
from aws_lambda_powertools import Logger, Tracer, Metrics
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.typing import LambdaContext

logger = Logger()   # 構造化JSON ログ（相関IDあり）
tracer = Tracer()   # X-Ray セグメント自動付与
metrics = Metrics(namespace="ServerlessEventPipeline")

@logger.inject_lambda_context(correlation_id_path="headers.x-correlation-id")
@tracer.capture_lambda_handler
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event: dict, context: LambdaContext) -> dict:
    ...
```

---

## エラーハンドリング戦略

```
処理失敗
  ↓
Lambda リトライ（最大2回、指数バックオフ）
  ↓ 全リトライ失敗
SQS DLQ へ移動（MessageAttribute に失敗理由・試行回数を付与）
  ↓ DLQメッセージ数 >= 1
CloudWatch Alarm → SNS → Email/Chatwork
  ↓
dlq-handler Lambda がアラーム起因で起動
  ↓
失敗理由を分類:
  - 一時エラー（Throttling・タイムアウト）→ 再エンキュー
  - 恒久エラー（バリデーション失敗）    → S3 dead-letter-archive に保存
```

---

## DynamoDB テーブル設計

```
テーブル: sep-<env>-events
  PK: entity_id (String)     # 例: USER#u123
  SK: event_ts   (String)    # 例: EVENT#2024-01-15T12:00:00Z

GSI-1 (status-index):
  PK: status     (String)    # PENDING / PROCESSED / FAILED
  SK: event_ts   (String)

TTL: expires_at（30日後自動削除）
PITR: 有効（本番のみ）
Streams: NEW_AND_OLD_IMAGES（aggregator Lambda のトリガー）
```

---

## Terraform バージョン・プロバイダ

```hcl
terraform {
  required_version = "~> 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}
```

---

## タグ戦略（全リソース必須）

```hcl
locals {
  common_tags = {
    Project     = "serverless-event-pipeline"
    ManagedBy   = "terraform"
    Environment = var.environment
    Owner       = "platform-team"
  }
}
```

---

## Lambda デプロイ戦略

```
Terraform で S3 に zip をアップロード → Lambda に適用
  ↓ 本番デプロイ時
Lambda Alias（prod）→ Weighted Routing でカナリアデプロイ
  10% トラフィックを新バージョンに流す
  ↓ エラー率が閾値以下なら
100% 切り替え（CloudWatch Alarm で自動ロールバック）
```

---

## コスト管理

- **月額目標**: ~$5以下（Kinesis Shard が主要コスト）
- 検証後は Kinesis Stream を 1 shard に削減
- Lambda: arm64 アーキテクチャで ~20% コスト削減
- DynamoDB: PAY_PER_REQUEST（オンデマンド）モード

---

## 禁止事項

- Lambda 関数内でのハードコードされた ARN・Account ID
- Powertools 未使用のログ出力（`print()` 禁止）
- DLQ なしの SQS → Lambda イベントソースマッピング
- Lambda 実行ロールへの `*` リソース指定（最小権限必須）
- 同期呼び出し（Lambda → Lambda 直接 invoke）の使用
- 環境変数への秘匿情報ハードコード（SSM Parameter Store 経由必須）

---

## 日本語コメント方針

設計の「なぜ」をコードに残す。

```hcl
# SQS の可視性タイムアウトは Lambda タイムアウトの6倍に設定する。
# Lambda がタイムアウトした場合にメッセージが再処理対象になるまでの猶予時間。
# 参照: https://docs.aws.amazon.com/lambda/latest/dg/with-sqs.html
resource "aws_sqs_queue" "transform" {
  visibility_timeout_seconds = var.lambda_timeout * 6
  ...
}
```