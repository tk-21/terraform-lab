# CLAUDE.md — serverless-api-platform

## プロジェクト概要

API Gateway × Lambda × DynamoDB による**プロダクションレベルのサーバーレスREST API基盤**のハンズオン。

認証・バリデーション・エラーハンドリング・CI/CDまでを一気通貫で実装し、
「APIバックエンドをゼロから設計・構築・運用できる」を証明する転職・案件獲得向けポートフォリオ。

---

## システム全体像

```
[クライアント]
      ↓ HTTPS
[API Gateway（REST API）]
  - WAF（レートリミット・IPブロック）
  - カスタムドメイン（Route53 + ACM）
  - Cognito オーソライザー（JWT検証）
  - リクエストバリデーション（JSONスキーマ）
      ↓ イベント
[Lambda 関数群]
  - list-items   GET    /items
  - get-item     GET    /items/{id}
  - create-item  POST   /items
  - update-item  PUT    /items/{id}
  - delete-item  DELETE /items/{id}
      ↓
[DynamoDB]
  - ホットデータ（Single Table Design）
  - DynamoDB Accelerator（DAX）← prodのみ
      ↓ Streams
[Lambda: stream-processor]
  - 変更イベントをS3に監査ログとして保存
```

---

## ディレクトリ構成

```
serverless-api-platform/
├── CLAUDE.md
├── README.md
├── Makefile
├── docs/
│   ├── architecture.md        # Mermaid アーキテクチャ図
│   ├── api-spec.yaml          # OpenAPI 3.0 仕様書
│   ├── adr/
│   │   ├── 001-single-table-design.md
│   │   ├── 002-cognito-vs-custom-auth.md
│   │   └── 003-rest-vs-http-api.md
│   └── runbook.md
├── terraform/
│   ├── environments/
│   │   ├── dev/
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   ├── outputs.tf
│   │   │   ├── backend.tf
│   │   │   ├── providers.tf
│   │   │   └── github-oidc.tf
│   │   └── prod/
│   │       └── （dev と同構成・変数のみ差異）
│   └── modules/
│       ├── lambda-function/    # Lambda共通モジュール
│       ├── api-gateway/        # REST API・ステージ・WAF
│       ├── cognito/            # User Pool・App Client
│       ├── dynamodb/           # テーブル・GSI・Streams・DAX
│       ├── iam/                # 実行ロール（最小権限）
│       └── monitoring/         # CloudWatch・アラーム・ダッシュボード
├── src/
│   ├── list_items/
│   │   ├── handler.py
│   │   └── requirements.txt
│   ├── get_item/
│   │   ├── handler.py
│   │   └── requirements.txt
│   ├── create_item/
│   │   ├── handler.py
│   │   └── requirements.txt
│   ├── update_item/
│   │   ├── handler.py
│   │   └── requirements.txt
│   ├── delete_item/
│   │   ├── handler.py
│   │   └── requirements.txt
│   ├── stream_processor/
│   │   ├── handler.py
│   │   └── requirements.txt
│   └── shared/
│       ├── models.py           # Pydantic データモデル
│       ├── repository.py       # DynamoDB アクセス層
│       ├── exceptions.py       # カスタム例外クラス
│       └── response.py         # APIレスポンス共通フォーマット
├── tests/
│   ├── unit/
│   │   ├── test_create_item.py
│   │   ├── test_list_items.py
│   │   ├── test_update_item.py
│   │   └── test_repository.py
│   └── integration/
│       └── test_api_e2e.py
└── .github/
    └── workflows/
        ├── ci.yml              # PR: lint・test・terraform plan
        └── cd.yml              # main: apply → deploy → smoke test
```

---

## 命名規則

| リソース種別 | パターン | 例 |
|---|---|---|
| Lambda 関数 | `sap-<env>-<操作>-<リソース>` | `sap-dev-create-item` |
| API Gateway | `sap-<env>-api` | `sap-dev-api` |
| Cognito User Pool | `sap-<env>-user-pool` | `sap-dev-user-pool` |
| DynamoDB Table | `sap-<env>-items` | `sap-dev-items` |
| IAM Role | `sap-<env>-<lambda名>-role` | `sap-dev-create-item-role` |
| S3 Bucket | `sap-<env>-<用途>-<account_id>` | `sap-dev-audit-logs-123456789012` |
| WAF WebACL | `sap-<env>-api-waf` | `sap-dev-api-waf` |
| CloudWatch LogGroup | `/aws/lambda/sap-<env>-<操作>-<リソース>` | 自動命名 |

**プロジェクト prefix**: `sap`（Serverless API Platform）

---

## DynamoDB Single Table Design

```
テーブル名: sap-<env>-items

PK: entity_type#entity_id    例: ITEM#item-uuid-xxxx
SK: metadata                 例: ITEM#item-uuid-xxxx（自己参照）

Attributes:
  item_id       (String)  UUID
  user_id       (String)  所有者
  name          (String)
  description   (String)
  status        (String)  ACTIVE / ARCHIVED
  created_at    (String)  ISO8601 UTC
  updated_at    (String)  ISO8601 UTC
  expires_at    (Number)  TTL（UNIXタイム）

GSI-1 (user-index):
  PK: user_id              # ユーザー別アイテム一覧
  SK: created_at           # 日付降順ソート

GSI-2 (status-index):
  PK: status               # ステータス別一覧（管理用）
  SK: created_at

TTL: expires_at（ARCHIVEDから30日後に自動削除）
Streams: NEW_AND_OLD_IMAGES（監査ログ用）
PITR: 有効（prodのみ）
```

---

## API レスポンス共通フォーマット

```json
// 成功
{
  "success": true,
  "data": { ... },
  "meta": {
    "request_id": "xxx",
    "timestamp": "2024-01-15T12:00:00Z"
  }
}

// エラー
{
  "success": false,
  "error": {
    "code": "ITEM_NOT_FOUND",
    "message": "指定されたアイテムが見つかりません",
    "request_id": "xxx"
  }
}

// ページネーション（一覧）
{
  "success": true,
  "data": [ ... ],
  "pagination": {
    "next_cursor": "base64encodedkey==",
    "has_more": true,
    "count": 20
  }
}
```

---

## Lambda 設計方針

```python
# 全 Lambda に AWS Lambda Powertools を適用（必須）
from aws_lambda_powertools import Logger, Tracer, Metrics
from aws_lambda_powertools.event_handler import APIGatewayRestResolver
from aws_lambda_powertools.utilities.typing import LambdaContext

logger = Logger()
tracer = Tracer()
metrics = Metrics(namespace="ServerlessApiPlatform")
app = APIGatewayRestResolver(enable_validation=True)  # Pydanticバリデーション自動化

@logger.inject_lambda_context(correlation_id_path="requestContext.requestId")
@tracer.capture_lambda_handler
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event: dict, context: LambdaContext) -> dict:
    return app.resolve(event, context)
```

---

## エラーハンドリング方針

```python
# shared/exceptions.py で定義するカスタム例外
class ItemNotFoundError(Exception):      # → 404
class ItemAlreadyExistsError(Exception): # → 409
class ValidationError(Exception):        # → 400
class UnauthorizedError(Exception):      # → 401
class ForbiddenError(Exception):         # → 403

# 各 Lambda で共通のエラーハンドラーを使用
# → APIレスポンス共通フォーマットで error オブジェクトを返す
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
    Project     = "serverless-api-platform"
    ManagedBy   = "terraform"
    Environment = var.environment
    Owner       = "platform-team"
  }
}
```

---

## コスト管理

- **月額目標**: ~$3以下（Cognito 無料枠・Lambda 無料枠・DynamoDB PAY_PER_REQUEST）
- DAX は prod のみ（dev は DynamoDB 直接アクセス）
- WAF は prod のみ（dev はコスト削減のためスキップ可）
- Lambda: arm64 アーキテクチャで ~20% コスト削減

---

## 禁止事項

- Lambda 関数内でのハードコードされた ARN・Account ID・テーブル名
- Powertools 未使用のログ出力（`print()` 禁止）
- Lambda 実行ロールへの `*` リソース指定（最小権限必須）
- Cognito トークン検証をアプリ側で実装すること（API Gateway オーソライザーに委譲）
- DynamoDB のフルスキャン（Scan API の使用禁止、必ずGSI経由で Query）
- 環境変数への秘匿情報ハードコード（SSM Parameter Store 経由必須）

---

## 日本語コメント方針

設計の「なぜ」をコードに残す。

```hcl
# API Gateway の統合タイムアウトは最大29秒。
# Lambda のタイムアウトをこれより短く設定することで、
# API GW側でタイムアウトする前にLambdaがエラーを返せる。
resource "aws_lambda_function" "create_item" {
  timeout = 25  # API GW統合タイムアウト(29s)より短く設定
  ...
}
```