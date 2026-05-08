# bedrock-finops-automation — アーキテクチャ完全理解ドキュメント

## 目次

1. [システム概要](#1-システム概要)
2. [全体アーキテクチャ図](#2-全体アーキテクチャ図)
3. [ディレクトリ構成と役割](#3-ディレクトリ構成と役割)
4. [モジュール詳細](#4-モジュール詳細)
5. [データフロー：Step Functions ペイロード連鎖](#5-データフローstep-functions-ペイロード連鎖)
6. [S3 オブジェクト構造](#6-s3-オブジェクト構造)
7. [DynamoDB スキーマとステータス遷移](#7-dynamodb-スキーマとステータス遷移)
8. [IAM 設計](#8-iam-設計)
9. [機密情報管理](#9-機密情報管理)
10. [CI/CD パイプライン](#10-cicd-パイプライン)
11. [コスト最適化設計](#11-コスト最適化設計)
12. [エラーハンドリングと再試行](#12-エラーハンドリングと再試行)
13. [環境ごとの差異](#13-環境ごとの差異)
14. [初回セットアップ手順](#14-初回セットアップ手順)

---

## 1. システム概要

AWS の月次コストを自動で収集・分析・通知する FinOps 自動化基盤。

**処理の流れ**

```
毎月1日 09:00 JST
  EventBridge（スケジューラ）
    → Step Functions（オーケストレータ）
      → collector        : Cost Explorer から当月・前月コストを取得
      → anomaly-detector : 前月比・集中度・新規サービスを検知
      → ai-reporter      : Bedrock（Claude 3 Haiku）で AI 所見を生成
      → html-formatter   : HTML レポートを S3 に保存し署名付き URL を発行
      → chatwork-notifier: 要約 + URL を Chatwork に通知
```

**技術選定の理由**

| 選択 | 理由 |
|------|------|
| Lambda（Python 3.12） | サーバーレス。月1回実行のため常時稼働不要 |
| Step Functions STANDARD | 実行履歴を1年保持。監査証跡・デバッグに活用 |
| Claude 3 Haiku | コスト最適化。レポート生成は軽量タスクのため Sonnet/Opus 不要 |
| Chatwork | 通知先として採用。API v2 で標準ライブラリ（urllib）のみで送信可能 |
| OIDC 認証 | アクセスキー禁止。GitHub Actions からの AWS 認証を OIDC で実現 |

---

## 2. 全体アーキテクチャ図

```
┌─────────────────────────────────────────────────────────────────┐
│  GitHub Actions                                                  │
│  ┌─────────────┐  OIDC   ┌──────────────────────────────────┐  │
│  │  PR → Plan  │────────▶│  IAM Role (bootstrap/)           │  │
│  │  main→Apply │         │  github-actions-bedrock-finops... │  │
│  └─────────────┘         └──────────────┬───────────────────┘  │
└─────────────────────────────────────────┼───────────────────────┘
                                          │ terraform apply
                                          ▼
┌─────────────────────────────────────────────────────────────────┐
│  AWS ap-northeast-1                                              │
│                                                                  │
│  EventBridge Rule                                                │
│  cron(0 0 1 * ? *)  ────────────────────────────────────────┐  │
│  = 毎月1日 00:00 UTC                                         │  │
│                                                              ▼  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Step Functions STANDARD  (bedrock-finops-automation-    │   │
│  │                            workflow-dev)                  │   │
│  │                                                          │   │
│  │  CollectCostData                                         │   │
│  │    ├── Lambda: collector ──────── us-east-1:Cost Explorer│   │
│  │    │                    ──────── S3: raw/{YYYY-MM}/      │   │
│  │    │                    ──────── DynamoDB: status=collected│  │
│  │    ▼                                                     │   │
│  │  DetectAnomalies                                         │   │
│  │    ├── Lambda: anomaly-detector                          │   │
│  │    │                    ──────── S3: anomaly/{YYYY-MM}/  │   │
│  │    │                    ──────── DynamoDB: status=anomaly_│  │
│  │    ▼                                detected             │   │
│  │  GenerateAIReport                                        │   │
│  │    ├── Lambda: ai-reporter ─────── Bedrock: claude-3-haiku│  │
│  │    │                    ──────── S3: ai-report/{YYYY-MM}/│   │
│  │    │                    ──────── DynamoDB: status=ai_analyzed│
│  │    ▼                                                     │   │
│  │  FormatHTMLReport                                        │   │
│  │    ├── Lambda: html-formatter                            │   │
│  │    │                    ──────── S3: html/{YYYY-MM}/     │   │
│  │    │                    ──────── S3 Presigned URL (7日)  │   │
│  │    │                    ──────── DynamoDB: status=html_generated│
│  │    ▼                                                     │   │
│  │  SendChatworkNotification                                │   │
│  │    ├── Lambda: chatwork-notifier                         │   │
│  │    │    ├── Secrets Manager: Chatwork API token          │   │
│  │    │    ├── SSM Parameter Store: Chatwork room ID        │   │
│  │    │    └── Chatwork API v2                              │   │
│  │    │                    ──────── DynamoDB: status=completed│  │
│  │    ▼                                                     │   │
│  │  WorkflowSucceeded / WorkflowFailed                      │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌──────────────────────┐  ┌────────────────────────────────┐   │
│  │  S3 Bucket           │  │  DynamoDB                      │   │
│  │  reports-dev-{acct}  │  │  report-history-dev            │   │
│  │  ├── raw/            │  │  PK: report_id                 │   │
│  │  ├── anomaly/        │  │  SK: report_date               │   │
│  │  ├── ai-report/      │  │  TTL: 1年後に自動削除          │   │
│  │  └── html/           │  └────────────────────────────────┘   │
│  │  (90日→Glacier,1年削除)│                                      │
│  └──────────────────────┘                                        │
│                                                                  │
│  CloudWatch Logs: /aws/lambda/... (30日保持)                    │
│                   /aws/states/...  (30日保持)                    │
└─────────────────────────────────────────────────────────────────┘
                          │
                          ▼
                     Chatwork Room
```

---

## 3. ディレクトリ構成と役割

```
bedrock-finops-automation/
│
├── bootstrap/              # 【初回のみ手動適用】GitHub Actions OIDC 用 IAM
│   ├── main.tf             # OIDC Provider + IAM Role (AdministratorAccess)
│   ├── outputs.tf          # github_actions_role_arn を出力
│   └── variables.tf        # github_owner, github_repo, project_name
│
├── environments/
│   └── dev/
│       ├── main.tf         # 全モジュールの呼び出し（依存順に記述）
│       ├── variables.tf    # aws_region, environment, project_name, owner, cost_center
│       ├── terraform.tfvars# 実際の変数値
│       ├── outputs.tf      # 各モジュールの出力を環境レベルで公開
│       ├── backend.tf      # S3 リモートステート設定
│       └── versions.tf     # Terraform / AWS Provider バージョン固定
│
├── modules/
│   ├── storage/            # S3 + DynamoDB（全モジュールが参照）
│   ├── collector/          # コストデータ収集 Lambda
│   ├── anomaly-detector/   # 異常検知 Lambda
│   ├── ai-reporter/        # AI レポート生成 Lambda（Bedrock呼び出し）
│   ├── html-formatter/     # HTML 整形 Lambda（Presigned URL 発行）
│   ├── chatwork-notifier/  # Chatwork 通知 Lambda
│   ├── workflow/           # Step Functions ステートマシン
│   └── scheduler/          # EventBridge 月次スケジュール
│
└── .github/workflows/
    ├── terraform.yml       # メイン CI/CD（plan + apply + unit test）
    └── integration-test.yml# 統合テスト（Week4 で整備予定）
```

---

## 4. モジュール詳細

### 4.1 storage

全 Lambda が依存する共通ストレージ。

**S3 Bucket** (`{project_name}-reports-{env}-{account_id}`)
- バージョニング有効（上書き履歴保持）
- SSE-S3 (AES256) 暗号化
- パブリックアクセス完全ブロック
- ライフサイクル:
  - 非カレントバージョン: 30日で削除
  - カレントバージョン: 90日後 GLACIER 移行 → 365日後削除
- `force_destroy = true`（dev 環境のみ）

**DynamoDB** (`{project_name}-report-history-{env}`)
- 課金モード: PAY_PER_REQUEST（月1回実行のためプロビジョン不要）
- PK: `report_id`（`finops-202501-xxxxxxxx` 形式）
- SK: `report_date`（`2025-01` 形式）
- PITR 有効（誤削除対策）
- SSE 有効（AWS 管理キー）
- TTL: `expire_at`（1年後の Unix timestamp）

### 4.2 collector

**Lambda**: `{project_name}-collector-{env}`
- メモリ: 512MB 以下、タイムアウト: 変数で設定

**処理内容**:
1. `event.target_year_month` があれば指定月、なければ前月を対象に設定
2. Cost Explorer `GetCostAndUsage` を2回呼び出し（当月・前月）
   - **注意**: Cost Explorer のエンドポイントは `us-east-1` 固定
   - 集計粒度: `MONTHLY`、グループ: `SERVICE`（上位10件をPython側でソート）
3. 生データを S3 の `raw/{YYYY-MM}/` に JSON 保存
4. DynamoDB に `status=collected` で初期レコードを書き込み
5. サマリー（合計コスト・上位10サービス・S3キー）を返す

**Step Functions の 256KB 制限への対策**: 生データは S3 に置きキーのみをペイロードで渡す。

### 4.3 anomaly-detector

**Lambda**: `{project_name}-anomaly-detector-{env}`

**検知ルール**（3種類）:

| ルール | 閾値 | 重要度 |
|--------|------|--------|
| 前月比コスト増加（COST_INCREASE） | >20% | MEDIUM |
| 前月比コスト増加（COST_INCREASE） | >50% | HIGH |
| サービス集中度（SERVICE_CONCENTRATION） | 上位1サービスが全体の >60% | MEDIUM |
| 新規サービス（NEW_SERVICE） | 前月未存在 + コスト >$0.1 | LOW |

**ノイズ除去**:
- 前月コスト <$0.01 の場合は増加チェックをスキップ
- 総コスト <$1 の場合は集中度チェックをスキップ
- 新規サービスのコスト <$0.1 は除外

閾値は環境変数（`MEDIUM_THRESHOLD_PCT`、`HIGH_THRESHOLD_PCT`、`SERVICE_CONCENTRATION_THRESHOLD`）で上書き可能。

### 4.4 ai-reporter

**Lambda**: `{project_name}-ai-reporter-{env}`

**Bedrock 呼び出し仕様**:
- モデル: `anthropic.claude-3-haiku-20240307-v1:0`（固定。コスト最適化）
- API: Messages API（`anthropic_version: bedrock-2023-05-31`）
- `max_tokens: 1024`、`temperature: 0.3`（一貫性重視）
- プロンプト: サービス上位5件のみ渡す（10件→5件でトークン節約）
- エンドポイント: `ap-northeast-1`（Cost Explorer とは異なる）

**出力 JSON 形式**（Claude に要求）:
```json
{
  "summary": "全体的な所見を2〜3文で",
  "highlights": ["注目ポイント1", "注目ポイント2"],
  "recommendations": ["改善提案1", "改善提案2", "改善提案3"],
  "risk_level": "LOW | MEDIUM | HIGH"
}
```

JSON パース失敗時はフォールバック（`risk_level: UNKNOWN`）でワークフローを止めない。

### 4.5 html-formatter

**Lambda**: `{project_name}-html-formatter-{env}`

- HTML を標準ライブラリのみで生成（外部テンプレートエンジン不使用）
- XSS 対策: `_escape()` 関数で全ユーザー由来データをエスケープ
- S3 に `html/{YYYY-MM}/report.html` として保存（`Content-Type: text/html`）
- **Presigned URL** を7日間有効で発行（Chatwork から直接閲覧可能）

**レポート構成**:
- コスト概要（当月・前月・前月比・異常件数）4つのメトリクスカード
- サービス別コスト表（コスト・割合・バーチャート）
- 異常検知テーブル（重要度別に色分け）
- AI 所見（リスクレベルバッジ + サマリー + 注目ポイント + 改善提案）

### 4.6 chatwork-notifier

**Lambda**: `{project_name}-chatwork-notifier-{env}`

- HTTP 通信: 標準ライブラリ `urllib` のみ使用（`requests` 等の外部依存なし）
- Chatwork 記法: `[info][title]...[/title]...[/info]` でボックス表示
- AI サマリーは先頭100文字に切り詰めて通知メッセージを簡潔に保つ
- HIGH 重要度の異常のみ本文に詳細を展開（MEDIUM/LOW は件数のみ）

**機密情報の取得先**:
- API トークン: Secrets Manager（`{project_name}/chatwork-api-token`）
- ルーム ID: SSM Parameter Store（String 型、非機密のため安価な SSM を使用）

### 4.7 workflow

**Step Functions STANDARD ステートマシン**: `{project_name}-workflow-{env}`

- ASL 定義は `.tftpl` ファイルで管理。`templatefile()` で Lambda ARN を注入
- 全ステートで Lambda 一時障害に対するリトライを設定（`MaxAttempts: 2`）
- いずれかのステートで失敗 → `WorkflowFailed` ステートへ遷移
- X-Ray トレーシング有効
- 実行ログ: CloudWatch Logs（`include_execution_data = true`）

**リトライ設定**:

| ステート | IntervalSeconds | MaxAttempts | BackoffRate |
|---------|----------------|-------------|-------------|
| CollectCostData | 5 | 2 | 2 |
| DetectAnomalies | 5 | 2 | 2 |
| GenerateAIReport | 10 | 2 | 2（Bedrock スロットリング対策） |
| FormatHTMLReport | 5 | 2 | 2 |
| SendChatworkNotification | 10 | 2 | 2 |

### 4.8 scheduler

**EventBridge Rule**: `cron(0 0 1 * ? *)` = 毎月1日 00:00 UTC（= 09:00 JST）

- `state = var.enabled ? "ENABLED" : "DISABLED"`
- dev 環境は `enabled = false`（誤発動防止。手動テスト完了後に `true` に変更）
- イベント重複配信対策: `maximum_retry_attempts = 2`、`maximum_event_age_in_seconds = 3600`
- Step Functions への初期入力: `{"source": "eventbridge-scheduler", "description": "..."}`
  - `target_year_month` を省略 → collector が自動的に前月を対象にする

---

## 5. データフロー：Step Functions ペイロード連鎖

各 Lambda の返り値がそのまま次の Lambda の `event` になる（`OutputPath: "$.Payload"` 設定による）。

```
collector の返り値:
{
  "report_id": "finops-202501-xxxxxxxx",
  "report_date": "2025-01",
  "current_month": {
    "start": "2025-01-01",
    "end": "2025-02-01",
    "total_cost": 123.45,
    "top_services": [{"service": "Amazon EC2", "cost": 56.78}, ...],
    "s3_key": "raw/2025-01/current_month.json"
  },
  "prev_month": {
    "start": "2024-12-01",
    "end": "2025-01-01",
    "total_cost": 100.00,
    "top_services": [...],
    "s3_key": "raw/2025-01/prev_month.json"
  }
}

anomaly-detector がマージして追加:
{
  ...（collector の全フィールド）,
  "anomalies": [
    {"type": "COST_INCREASE", "severity": "MEDIUM", "description": "...", ...}
  ],
  "anomaly_summary": {
    "count": 1,
    "has_high_severity": false,
    "s3_key": "anomaly/2025-01/anomaly_report.json",
    "severities": ["MEDIUM"]
  }
}

ai-reporter がマージして追加:
{
  ...（anomaly-detector の全フィールド）,
  "ai_report": {
    "summary": "...",
    "highlights": ["...", "..."],
    "recommendations": ["...", "...", "..."],
    "risk_level": "MEDIUM",
    "s3_key": "ai-report/2025-01/analysis.json"
  }
}

html-formatter がマージして追加:
{
  ...（ai-reporter の全フィールド）,
  "html_report": {
    "s3_key": "html/2025-01/report.html",
    "presigned_url": "https://s3.amazonaws.com/...?X-Amz-Signature=..."
  }
}

chatwork-notifier の最終返り値（スリム化）:
{
  "report_id": "finops-202501-xxxxxxxx",
  "report_date": "2025-01",
  "status": "completed",
  "chatwork_message_id": "1234567890",
  "html_s3_key": "html/2025-01/report.html"
}
```

---

## 6. S3 オブジェクト構造

```
{project_name}-reports-{env}-{account_id}/
├── raw/
│   └── 2025-01/
│       ├── current_month.json   # Cost Explorer の生レスポンス（当月）
│       └── prev_month.json      # Cost Explorer の生レスポンス（前月）
├── anomaly/
│   └── 2025-01/
│       └── anomaly_report.json  # 検知した異常のリスト
├── ai-report/
│   └── 2025-01/
│       └── analysis.json        # Bedrock の出力 + 使用したプロンプト
└── html/
    └── 2025-01/
        └── report.html          # 閲覧用 HTML レポート（Presigned URL でアクセス）
```

---

## 7. DynamoDB スキーマとステータス遷移

**テーブル名**: `{project_name}-report-history-{env}`

| 属性 | 型 | 説明 |
|------|-----|------|
| `report_id` | S (PK) | `finops-{YYYYMM}-{request_id[:8]}` |
| `report_date` | S (SK) | `YYYY-MM` |
| `status` | S | 下記のステータス遷移を参照 |
| `metadata` | S | collector が保存するコストサマリー（JSON 文字列） |
| `anomaly_count` | N | 検知した異常件数 |
| `has_high_severity` | BOOL | HIGH 重要度の異常があるか |
| `ai_risk_level` | S | AI が判定したリスクレベル |
| `html_s3_key` | S | HTML レポートの S3 キー |
| `chatwork_message_id` | S | Chatwork のメッセージ ID |
| `created_at` | S | ISO 8601 UTC |
| `updated_at` | S | ISO 8601 UTC（各ステップで更新） |
| `completed_at` | S | ISO 8601 UTC（最終ステップで設定） |
| `expire_at` | N | Unix timestamp（TTL、1年後） |

**ステータス遷移**:

```
collected → anomaly_detected → ai_analyzed → html_generated → completed
                                                                    ↑
                                           各ステップの DynamoDB 更新がここに集約
```

---

## 8. IAM 設計

Confused Deputy 問題を防ぐため、全ての信頼ポリシーに `aws:SourceAccount` 条件を付与。

### collector Lambda

| アクション | リソース | 理由 |
|-----------|---------|------|
| `ce:GetCostAndUsage` | `*` | CE はリソースレベル制御非対応 |
| `s3:PutObject`, `s3:GetObject` | `{bucket_arn}/raw/*` | raw プレフィックスに限定 |
| `dynamodb:PutItem`, `dynamodb:UpdateItem` | `{table_arn}` | 対象テーブルに限定 |
| `secretsmanager:GetSecretValue` | `arn:...:secret:{project_name}/*` | プロジェクト名プレフィックスに限定 |
| CloudWatch Logs | マネージドポリシー（AWSLambdaBasicExecutionRole） | |

※ anomaly-detector、ai-reporter、html-formatter、chatwork-notifier も同様のパターン（アクセスするプレフィックスが異なる）

### Step Functions

| アクション | リソース |
|-----------|---------|
| `lambda:InvokeFunction` | 各 Lambda の ARN + `ARN:*`（エイリアス対応） |
| CloudWatch Logs 配信系 | `*`（Logs Delivery は ARN 指定不可） |
| X-Ray | `*` |

### EventBridge Scheduler

| アクション | リソース |
|-----------|---------|
| `states:StartExecution` | 対象ステートマシン ARN のみ |

### GitHub Actions (bootstrap)

- OIDC で認証。`sub` クレームをリポジトリ単位でスコープ制限
- AdministratorAccess をアタッチ（IAM ロール・ポリシー作成に必要）
- main ブランチ保護 + PR レビュー必須で apply を制御

---

## 9. 機密情報管理

| 情報 | 管理場所 | 理由 |
|------|---------|------|
| Chatwork API トークン | Secrets Manager | 高機密。自動ローテーション対応 |
| Chatwork ルーム ID | SSM Parameter Store（String） | 機密性低。SSM は無料枠あり（Secrets Manager は $0.40/月） |
| AWS 認証情報 | OIDC（アクセスキーなし） | キー漏洩リスクゼロ |
| GitHub Secrets | `AWS_ROLE_ARN` | bootstrap の output から取得した IAM ロール ARN |

Secrets Manager のシークレット命名規則: `{project_name}/{key}`
例: `bedrock-finops-automation/chatwork-api-token`

---

## 10. CI/CD パイプライン

**ファイル**: `.github/workflows/terraform.yml`

```
PR オープン/更新:
  1. unit-test   : pytest で Lambda ユニットテスト実行
  2. terraform-plan (needs: unit-test):
     - OIDC で AWS 認証
     - terraform fmt -check
     - terraform validate
     - terraform plan
     - Plan 結果を PR コメントに投稿（既存コメントがあれば更新）

main マージ:
  1. unit-test
  2. terraform-apply (needs: unit-test):
     - OIDC で AWS 認証
     - terraform apply -auto-approve
     - concurrency: terraform-apply（並行実行防止）
```

**Terraform バージョン**: 1.9.0（`versions.tf` で固定）
**リモートステート**: S3 バックエンド（`backend.tf`）

---

## 11. コスト最適化設計

| 施策 | 効果 |
|------|------|
| Claude 3 Haiku（Sonnet/Opus 禁止） | AI 推論コストを最小化 |
| `max_tokens: 1024` | Bedrock 出力トークンを制限 |
| プロンプトでサービスを5件に絞る | 入力トークンを削減 |
| Lambda メモリ 512MB 以下 | 実行コスト抑制 |
| DynamoDB PAY_PER_REQUEST | 月1回実行のためプロビジョン不要 |
| S3 90日→Glacier移行、1年後削除 | ストレージコスト最小化 |
| Cost Explorer API 月数回以内（1回$0.01） | API コスト管理 |
| SSM Parameter Store（ルーム ID） | Secrets Manager（$0.40/月）を使わない |
| EventBridge スケジュール（dev: DISABLED） | 開発中の誤発動防止 |

---

## 12. エラーハンドリングと再試行

**Lambda レベル**:
- Bedrock JSON パース失敗: フォールバックレスポンスを返してワークフローを継続
- Chatwork API HTTP エラー: `urllib.error.HTTPError` をキャッチしてログ記録後に再スロー

**Step Functions レベル**:
- 各ステートでリトライ設定（Lambda スロットリング・一時障害対応）
- 最終的な失敗は `WorkflowFailed` ステートへ Catch

**ログ確認箇所**:
- Lambda 実行ログ: `/aws/lambda/{function_name}`（30日保持）
- Step Functions 実行ログ: `/aws/states/{state_machine_name}`（30日保持）
- Step Functions コンソール: 実行履歴・ペイロード・エラー詳細

---

## 13. 環境ごとの差異

| 設定 | dev | prod（想定） |
|------|-----|-------------|
| `force_destroy` (S3) | true | false |
| EventBridge `enabled` | false | true |
| Terraform backend | S3 リモートステート | 別バケット |
| IAM ロール名サフィックス | `-dev` | `-prod` |

---

## 14. 初回セットアップ手順

```bash
# Step 1: bootstrap（GitHub Actions OIDC 用 IAM を作成）
cd bootstrap/
terraform init
terraform apply -var="github_owner=YOUR_GITHUB_USERNAME"
# 出力された github_actions_role_arn を GitHub Secrets > AWS_ROLE_ARN に登録

# Step 2: Secrets Manager にシークレットを作成（手動）
aws secretsmanager create-secret \
  --name "bedrock-finops-automation/chatwork-api-token" \
  --secret-string '{"api_token": "YOUR_CHATWORK_TOKEN"}'

# Step 3: SSM Parameter Store にルーム ID を登録（手動）
aws ssm put-parameter \
  --name "/bedrock-finops-automation/chatwork-room-id" \
  --value "YOUR_ROOM_ID" \
  --type String

# Step 4: dev 環境の Terraform 適用（初回のみローカルから、以降は GitHub Actions）
cd environments/dev/
terraform init
terraform plan
# ※ apply はユーザー自身が実行（CLAUDE.md ルール）
terraform apply

# Step 5: 動作確認（Step Functions を手動実行）
aws stepfunctions start-execution \
  --state-machine-arn "arn:aws:states:ap-northeast-1:ACCOUNT_ID:stateMachine:bedrock-finops-automation-workflow-dev" \
  --input '{"target_year_month": "2025-01"}'

# Step 6: 確認完了後、スケジューラを有効化
# environments/dev/main.tf の scheduler モジュールで enabled = true に変更
```
