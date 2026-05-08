# AWS Bedrock AI Platform Sandbox — アーキテクチャドキュメント

> **目的**: エンタープライズ相当のマルチテナントAI基盤をAWS個人環境で月$30以内に再現する。  
> **リージョン**: ap-northeast-1（東京）  
> **IaC**: Terraform（全リソース管理）  
> **認証**: OIDC（アクセスキー禁止）

---

## 目次

1. [システム全体図](#1-システム全体図)
2. [ネットワーク設計](#2-ネットワーク設計)
3. [リクエストフロー](#3-リクエストフロー)
4. [モジュール構成](#4-モジュール構成)
5. [各モジュール詳細](#5-各モジュール詳細)
6. [マルチテナント設計](#6-マルチテナント設計)
7. [セキュリティ設計](#7-セキュリティ設計)
8. [コスト制御設計](#8-コスト制御設計)
9. [可観測性設計](#9-可観測性設計)
10. [CI/CD パイプライン](#10-cicd-パイプライン)
11. [データモデル](#11-データモデル)
12. [コスト見積もり](#12-コスト見積もり)
13. [ディレクトリ構成](#13-ディレクトリ構成)

---

## 1. システム全体図

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              AWS ap-northeast-1                                 │
│                                                                                 │
│  ┌──────────────────────────────────────────────────────────────────────────┐   │
│  │  GitHub Actions (OIDC)                                                   │   │
│  │  PR → plan comment  /  merge to main → apply                            │   │
│  └──────────────────────────────┬───────────────────────────────────────────┘   │
│                                 │ OIDC AssumeRole                               │
│  ┌─────────────┐                │                                               │
│  │  Client     │                ▼                                               │
│  │  (any HTTP) │──POST /chat──▶ WAF v2 WebACL                                  │
│  └─────────────┘                │                                               │
│                                 ▼                                               │
│                          API Gateway HTTP API v2                                │
│                          throttle: 50 rps / burst 100                          │
│                                 │                                               │
│              ┌──────────────────┼──────────────────────┐                        │
│              │  VPC (10.0.0.0/16)                       │                        │
│              │                  ▼                       │                        │
│              │        ┌──────────────────┐              │                        │
│              │        │  Router Lambda   │              │                        │
│              │        │  (Python 3.12)   │              │                        │
│              │        │  512MB / 30s     │              │                        │
│              │        └────────┬─────────┘              │                        │
│              │                 │                        │                        │
│              │    ┌────────────┼───────────────┐        │                        │
│              │    ▼            ▼               ▼        │                        │
│              │ DynamoDB   Bedrock Runtime  DynamoDB      │                        │
│              │ (tenants)  (Haiku/Sonnet)  (usage)       │                        │
│              │            + Guardrail                   │                        │
│              │                 │                        │                        │
│              │                 ▼                        │                        │
│              │        ┌──────────────────┐              │                        │
│              │        │  Bedrock Agent   │              │                        │
│              │        │  (Sonnet 3.5)    │              │                        │
│              │        └────────┬─────────┘              │                        │
│              │                 │                        │                        │
│              │    ┌────────────┼──────────┐             │                        │
│              │    ▼            ▼          ▼             │                        │
│              │ Knowledge   Action     CloudWatch        │                        │
│              │ Base (RAG)  Handler    / X-Ray           │                        │
│              │ Aurora+pgvector        (observability)   │                        │
│              └──────────────────────────────────────────┘                        │
│                                                                                 │
│  ┌─────────────────────────┐   ┌──────────────────────────┐                    │
│  │  Cost Controller Lambda  │   │  CloudTrail + S3 Bucket  │                    │
│  │  EventBridge 1h trigger  │   │  (全APIアクセス監査)      │                    │
│  └──────────┬──────────────┘   └──────────────────────────┘                    │
│             │                                                                   │
│             ▼                                                                   │
│  ┌──────────────────────┐                                                       │
│  │  AWS Budgets $30/mo  │──▶ SNS Topic ──▶ Email                               │
│  └──────────────────────┘                                                       │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. ネットワーク設計

### VPC構成

```
VPC: 10.0.0.0/16
│
├── Public Subnet 1a  (10.0.1.0/24)  ── Internet Gateway ── Internet
├── Public Subnet 1c  (10.0.2.0/24)  ┘
│        │
│    NAT Gateway (1つのみ、コスト最適化)
│        │
├── Private Subnet 1a (10.0.11.0/24) ── Lambda, Aurora
└── Private Subnet 1c (10.0.12.0/24) ┘
```

### VPC Endpoints（プライベートルーティング）

| Endpoint | タイプ | 用途 |
|----------|--------|------|
| S3 | Gateway | ドキュメントバケット・CloudTrail |
| DynamoDB | Gateway | テナント・使用量テーブル |
| Bedrock Runtime | Interface | モデル呼び出し（プライベートDNS有効） |
| Secrets Manager | Interface | Aurora パスワード取得 |

> Gateway型はコスト無料。Interface型は月約$14（2エンドポイント×2AZ）。

### ルーティング

```
[Private Subnet]
  └── Private Route Table
        ├── 0.0.0.0/0 → NAT Gateway（インターネットへ）
        ├── S3 prefix → S3 Gateway Endpoint
        └── DynamoDB prefix → DynamoDB Gateway Endpoint

[Public Subnet]
  └── Public Route Table
        └── 0.0.0.0/0 → Internet Gateway
```

---

## 3. リクエストフロー

### 通常チャットリクエスト（POST /chat）

```
Client
  │
  │ POST /chat
  │ Headers: x-tenant-id: tenant-xyz
  │ Body: {"prompt": "インフラコストを分析して"}
  ▼
WAF v2 WebACL
  ├── AWSManagedRulesCommonRuleSet  (OWASP Top10)
  ├── AWSManagedRulesKnownBadInputsRuleSet (SQLi/XSS)
  └── IP Rate Limit (1000 req/5min per IP)
  │
  ▼
API Gateway HTTP API v2
  └── POST /chat route
  │
  ▼
Router Lambda (VPC Private Subnet)
  │
  ├─① DynamoDB GetItem (tenants テーブル)
  │     → tier, daily_limit, preferred_model, guardrail_enabled
  │
  ├─② 日次予算チェック
  │     DynamoDB GetItem (usage テーブル, PK=tenant_id, SK=今日)
  │     → total_tokens >= token_limit_daily? → 429 Too Many Requests
  │
  ├─③ モデル選択ロジック
  │     preferred_model が指定 → そのモデルを使用
  │     プロンプト > 1000文字 OR 複雑キーワード → Claude 3.5 Sonnet
  │     それ以外 → Claude 3 Haiku
  │
  ├─④ Bedrock InvokeModel (VPC Endpoint経由)
  │     + ApplyGuardrail (PII匿名化 + コンテンツフィルタ)
  │
  └─⑤ DynamoDB UpdateItem (usage テーブル)
        ADD total_tokens, input_tokens, output_tokens
  │
  ▼
Response
  {"response": "...", "model_used": "amazon.titan-text-haiku-v1", ...}
```

### 複雑キーワード判定（Sonnet選択トリガー）

```
analyze, compare, explain, implement, design, architect,
debug, optimize, refactor, summarize, translate, evaluate,
review, generate code, write code, create a, step-by-step
```

---

## 4. モジュール構成

### 依存関係グラフ

```
networking
    │
    ├──────────────────────────────────┐
    ▼                                  ▼
bedrock-foundation              (VPCセキュリティグループ)
    │                                  │
    ├───────────┬───────────┐          │
    ▼           ▼           ▼          ▼
knowledge-  multi-tenant  (IAM)   api-gateway
base            │                      │
    │           ▼                      ▼
    │       router-lambda ◀────────────┘
    │           │
    │           └──────────────────────┐
    ▼                                  ▼
bedrock-agent ◀──────────────── cost-controller
    │
    ▼
observability ◀─────────── 全モジュール
```

### モジュール一覧

| モジュール | 主要リソース | 目的 |
|-----------|------------|------|
| networking | VPC, Subnet, NAT GW, VPC Endpoints | プライベートネットワーク基盤 |
| bedrock-foundation | IAM Role, Guardrail, CloudTrail | セキュリティ基盤 |
| knowledge-base | Aurora pgvector, S3, Bedrock KB | RAG基盤 |
| multi-tenant | DynamoDB (tenants, usage) | テナント管理・使用量追跡 |
| router-lambda | Lambda, IAM | インテリジェントルーティング |
| cost-controller | Lambda, Budgets, SNS | コスト監視・制御 |
| api-gateway | HTTP API v2, WAF v2 | APIエントリポイント |
| bedrock-agent | Bedrock Agent, Lambda | AIエージェント |
| observability | X-Ray, CloudWatch, Dashboard | 可観測性 |

---

## 5. 各モジュール詳細

### 5.1 networking

```
┌─── networking module ──────────────────────────────────────┐
│                                                             │
│  aws_vpc (10.0.0.0/16)                                      │
│    enable_dns_hostnames = true                              │
│    enable_dns_support   = true                              │
│                                                             │
│  Public Subnets                                             │
│    10.0.1.0/24 (ap-northeast-1a)  ──── Internet Gateway    │
│    10.0.2.0/24 (ap-northeast-1c) ─┘                        │
│              │                                              │
│         NAT Gateway (EIP)                                   │
│              │ ※1つのみ（コスト最適化）                       │
│  Private Subnets                                            │
│    10.0.11.0/24 (ap-northeast-1a)                          │
│    10.0.12.0/24 (ap-northeast-1c)                          │
│                                                             │
│  VPC Endpoints                                              │
│    s3_endpoint (Gateway) - タグ付きのみ                     │
│    dynamodb_endpoint (Gateway)                              │
│    bedrock_runtime_endpoint (Interface, private DNS)        │
│    secretsmanager_endpoint (Interface)                      │
│                                                             │
│  Security Group: vpc_endpoint_sg                            │
│    Inbound: 443 from 10.0.0.0/16                           │
│    Outbound: All                                            │
└─────────────────────────────────────────────────────────────┘
```

---

### 5.2 bedrock-foundation

```
┌─── bedrock-foundation module ──────────────────────────────┐
│                                                             │
│  IAM Role: bedrock_invoke_role                              │
│    Principal: Lambda                                        │
│    Condition:                                               │
│      aws:SourceAccount = ${account_id}                     │
│      aws:SourceArn     = arn:aws:lambda:region:acct:*      │
│    Policy: bedrock_invoke_policy                            │
│      bedrock:InvokeModel  (Haiku, Sonnet ARNs のみ)        │
│      bedrock:ApplyGuardrail                                 │
│                                                             │
│  Bedrock Guardrail: platform_guardrail                      │
│  ┌─ PII匿名化 ──────────────────────────────────────────┐  │
│  │  EMAIL, PHONE, NAME, SSN,                            │  │
│  │  CREDIT_DEBIT_CARD, IP_ADDRESS → ANONYMIZE           │  │
│  └──────────────────────────────────────────────────────┘  │
│  ┌─ コンテンツフィルタ ────────────────────────────────┐  │
│  │  SEXUAL         : HIGH  (input/output)               │  │
│  │  VIOLENCE       : MEDIUM (input/output)              │  │
│  │  HATE           : HIGH  (input/output)               │  │
│  │  INSULTS        : MEDIUM (input/output)              │  │
│  │  MISCONDUCT     : MEDIUM (input/output)              │  │
│  │  PROMPT_ATTACK  : HIGH  (input only)                 │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                             │
│  CloudTrail: bedrock_trail                                  │
│    S3バケット (KMS暗号化, ライフサイクル90日→IA, 365日削除)  │
│    CloudWatch Logs (90日保持)                               │
│    ログファイル整合性検証: enabled                           │
│    データイベント: AWS::Bedrock::Model                       │
└─────────────────────────────────────────────────────────────┘
```

---

### 5.3 knowledge-base

```
┌─── knowledge-base module ───────────────────────────────────┐
│                                                              │
│  S3 Bucket: kb-docs-{project}-{env}                         │
│    KMS暗号化, バージョニング有効                              │
│    パブリックアクセス完全ブロック                              │
│    ライフサイクル: 90日 → STANDARD_IA                        │
│    バケットポリシー: bedrock.amazonaws.com への読み取り許可   │
│                                                              │
│  Aurora PostgreSQL Serverless v2                             │
│    Engine: aurora-postgresql 16.4                            │
│    スケーリング: 0.5 ACU (min) → 4.0 ACU (max)             │
│    RDS Data API: enabled                                     │
│    マスターパスワード: Secrets Manager自動管理               │
│    CloudWatch Logs: postgresql                               │
│                                                              │
│  pgvector スキーマ (Terraform初期化)                         │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ CREATE EXTENSION vector;                               │ │
│  │ CREATE SCHEMA bedrock_integration;                     │ │
│  │ CREATE TABLE bedrock_integration.bedrock_kb (          │ │
│  │   id        uuid PRIMARY KEY,                          │ │
│  │   embedding vector(1024),    ← Titan V2の次元数        │ │
│  │   chunks    text,                                      │ │
│  │   metadata  json                                       │ │
│  │ );                                                     │ │
│  │ CREATE INDEX bedrock_kb_embedding_idx                  │ │
│  │   USING hnsw (embedding vector_cosine_ops);            │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  Bedrock Knowledge Base                                      │
│    ベクターストア: RDS (Aurora)                              │
│    埋め込みモデル: Titan Text Embeddings V2 (1024次元)       │
│    データソース: S3                                          │
│    チャンキング: 512トークン, オーバーラップ10%              │
│                                                              │
│  IAM Role: knowledge_base_role                               │
│    S3読み取り, Titanモデル呼び出し,                          │
│    Aurora Data API実行, Secrets Manager読み取り              │
└──────────────────────────────────────────────────────────────┘
```

---

### 5.4 multi-tenant

```
┌─── multi-tenant module ─────────────────────────────────────┐
│                                                              │
│  DynamoDB: tenants テーブル                                  │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ PK: tenant_id (String)                                  │ │
│  │ GSI: tier-index (tier → コスト集計用)                   │ │
│  │                                                         │ │
│  │ Attributes:                                             │ │
│  │   tier              : free | standard | premium         │ │
│  │   token_limit_daily : Number                            │ │
│  │   token_limit_monthly: Number                           │ │
│  │   preferred_model   : String (オプション)               │ │
│  │   guardrail_enabled : Boolean                           │ │
│  │   created_at        : ISO8601                           │ │
│  │                                                         │ │
│  │ PITR: enabled, SSE: enabled                             │ │
│  └─────────────────────────────────────────────────────────┘ │
│                                                              │
│  DynamoDB: usage テーブル                                    │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ PK: tenant_id (String)                                  │ │
│  │ SK: date (String, YYYYMMDD)                             │ │
│  │                                                         │ │
│  │ Attributes:                                             │ │
│  │   total_tokens  : Number (累計)                         │ │
│  │   input_tokens  : Number                                │ │
│  │   output_tokens : Number                                │ │
│  │   last_model    : String                                │ │
│  │   last_updated  : ISO8601                               │ │
│  │   expires_at    : Unix epoch (TTL = 90日)               │ │
│  │                                                         │ │
│  │ PITR: enabled, SSE: enabled                             │ │
│  └─────────────────────────────────────────────────────────┘ │
│                                                              │
│  初期データ (terraform_data で投入)                          │
│  ┌─────────────────┬────────────┬───────────┬────────────┐  │
│  │ tenant_id       │ tier       │ daily     │ monthly    │  │
│  ├─────────────────┼────────────┼───────────┼────────────┤  │
│  │ default         │ standard   │ 100,000   │ 2,000,000  │  │
│  │ tenant-premium  │ premium    │ 500,000   │ 10,000,000 │  │
│  │ (Sonnet固定)    │            │           │            │  │
│  └─────────────────┴────────────┴───────────┴────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

---

### 5.5 router-lambda

```
┌─── router-lambda module ────────────────────────────────────┐
│                                                              │
│  Lambda Function                                             │
│    Runtime: Python 3.12                                      │
│    Memory:  512 MB                                           │
│    Timeout: 30s                                              │
│    VPC:     Private Subnets のみ                            │
│    X-Ray:   Active tracing                                   │
│                                                              │
│  ルーティングロジック (src/index.py)                         │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │                                                         │ │
│  │  Event ──▶ _parse_body() ──▶ _extract_tenant_id()      │ │
│  │               │                                         │ │
│  │               ▼                                         │ │
│  │           _get_tenant(tenant_id)                        │ │
│  │               │ 404 if not found                        │ │
│  │               ▼                                         │ │
│  │           _is_over_daily_budget()                       │ │
│  │               │ 429 if exceeded                         │ │
│  │               ▼                                         │ │
│  │           _select_model(prompt, tenant_config)          │ │
│  │           ┌──────────────────────────────────────────┐  │ │
│  │           │ preferred_model 設定あり → 固定モデル     │  │ │
│  │           │ プロンプト > 1000文字 → Sonnet            │  │ │
│  │           │ 複雑キーワード含む   → Sonnet            │  │ │
│  │           │ それ以外            → Haiku              │  │ │
│  │           └──────────────────────────────────────────┘  │ │
│  │               │                                         │ │
│  │               ▼                                         │ │
│  │           _invoke_bedrock(prompt, model, guardrail)     │ │
│  │               │                                         │ │
│  │               ▼                                         │ │
│  │           _record_usage(tenant_id, tokens)              │ │
│  │           (ベストエフォート、失敗しても応答は返す)       │ │
│  │               │                                         │ │
│  │               ▼                                         │ │
│  │           Response {response, model_used, tenant_id}   │ │
│  └─────────────────────────────────────────────────────────┘ │
│                                                              │
│  環境変数                                                    │
│    TENANT_TABLE, USAGE_TABLE                                 │
│    GUARDRAIL_ID, GUARDRAIL_VERSION                           │
│    HAIKU_MODEL_ID, SONNET_MODEL_ID                           │
└──────────────────────────────────────────────────────────────┘
```

---

### 5.6 cost-controller

```
┌─── cost-controller module ──────────────────────────────────┐
│                                                              │
│  EventBridge ──(1時間ごと)──▶ Cost Controller Lambda        │
│                                                              │
│  Cost Controller Lambda (src/index.py)                       │
│    Runtime: Python 3.12                                      │
│    Memory:  256 MB                                           │
│    Timeout: 60s                                              │
│    WARN_PERCENT: 80 (デフォルト)                             │
│                                                              │
│    処理フロー                                                │
│    1. DynamoDB Scan (tenants テーブル)                       │
│    2. 各テナントの今日の使用量を取得                         │
│    3. 使用率計算: used / daily_limit × 100                   │
│    4. 80% 以上 → SNS "WARNING" メッセージ発行               │
│    4. 100% 以上 → SNS "EXCEEDED" メッセージ発行             │
│                                                              │
│  SNS Topic: budget_alerts                                    │
│    サブスクリプション: Email (alert_email 設定時)            │
│    パブリッシャー許可: Lambda, budgets.amazonaws.com         │
│                                                              │
│  AWS Budgets: monthly_cost_budget                            │
│    タイプ: COST                                              │
│    上限: $30/月 (設定可能)                                   │
│    通知:                                                     │
│      80% 到達 → SNS                                         │
│      100% 到達 → SNS                                        │
└──────────────────────────────────────────────────────────────┘
```

---

### 5.7 api-gateway

```
┌─── api-gateway module ──────────────────────────────────────┐
│                                                              │
│  WAF v2 WebACL (REGIONAL)                                    │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ Rule 1: AWSManagedRulesCommonRuleSet        (優先度1)   │ │
│  │         → OWASP Top10 (XSS, SQLi, etc.)                │ │
│  │ Rule 2: AWSManagedRulesKnownBadInputsRuleSet (優先度2)  │ │
│  │         → 既知の悪意あるインプット                       │ │
│  │ Rule 3: IPRateLimit                          (優先度3)  │ │
│  │         → 1,000リクエスト / 5分 / IP                   │ │
│  └─────────────────────────────────────────────────────────┘ │
│                    │                                         │
│                    ▼                                         │
│  HTTP API v2                                                 │
│    プロトコル: HTTP                                          │
│    CORS設定:                                                 │
│      Allow-Origin:  * (dev環境のみ)                         │
│      Allow-Methods: POST, OPTIONS                            │
│      Allow-Headers: content-type, x-tenant-id, authorization│
│      Max-Age:       300s                                     │
│                                                              │
│    ルート: POST /chat ──▶ Router Lambda (AWS_PROXY)         │
│                                                              │
│    $default ステージ                                         │
│      スロットリング: バースト100, レート50 rps              │
│      詳細メトリクス: enabled                                │
│      アクセスログ: CloudWatch Logs (30日保持)               │
└──────────────────────────────────────────────────────────────┘
```

---

### 5.8 bedrock-agent

```
┌─── bedrock-agent module ────────────────────────────────────┐
│                                                              │
│  Bedrock Agent: infra_ops_agent                              │
│    モデル: Claude 3.5 Sonnet                                 │
│    セッションTTL: 600秒                                      │
│    Guardrail: 適用済み                                       │
│    指示: 日本語のインフラ運用アシスタント                    │
│                                                              │
│  Action Group: infra-ops                                     │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ OpenAPI 3.0 スキーマ (schema/infra_ops.json)            │ │
│  │                                                         │ │
│  │ GET  /infrastructure/status                             │ │
│  │   → サービス健全性ステータス一覧                         │ │
│  │   Returns: {status, timestamp, services: {...}}         │ │
│  │                                                         │ │
│  │ GET  /costs/summary                                     │ │
│  │   → 月間コスト見積もり + トークン使用量集計             │ │
│  │   Returns: {month, currency, total_estimated,           │ │
│  │             breakdown, total_tokens_this_month}         │ │
│  │                                                         │ │
│  │ POST /alerts/acknowledge                                │ │
│  │   Body: {alert_id, reason?}                             │ │
│  │   → アラート確認ログ記録                                │ │
│  │   Returns: {status, alert_id, timestamp}               │ │
│  └─────────────────────────────────────────────────────────┘ │
│                    │                                         │
│                    ▼                                         │
│  Action Handler Lambda (src/index.py)                        │
│    Runtime: Python 3.12 / 256MB / 30s                        │
│    X-Ray: Active tracing                                     │
│                                                              │
│  Knowledge Base Association                                  │
│    State: ENABLED                                            │
│    → Aurora pgvector への RAG クエリが可能                  │
└──────────────────────────────────────────────────────────────┘
```

---

### 5.9 observability

```
┌─── observability module ────────────────────────────────────┐
│                                                              │
│  X-Ray Group: bedrock-platform                               │
│    フィルタ: annotation.project = "bedrock-ai-platform-sandbox"│
│    インサイト: enabled                                       │
│                                                              │
│  CloudWatch Metric Filters (CloudTrail → カスタムメトリクス) │
│    BedrockInvokeCount        ← InvokeModel イベント数        │
│    BedrockInvokeStreamCount  ← InvokeModelWithResponseStream │
│    名前空間: bedrock-ai-platform-sandbox/dev                 │
│                                                              │
│  CloudWatch Alarms                                           │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ router_lambda_errors : Errors > 5 / 5分 → SNS          │ │
│  │ cost_controller_errors: Errors > 5 / 5分 → SNS         │ │
│  │ api_gateway_5xx      : 5xxError > 10 / 5分 → SNS       │ │
│  │   ※ ALARM / OK 両方で通知                               │ │
│  └─────────────────────────────────────────────────────────┘ │
│                                                              │
│  CloudWatch Dashboard: {project}-{env}-dashboard             │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ Row 1: API & Bedrock                                    │ │
│  │   [API Requests & Errors] [API Latency p50/p99]         │ │
│  │   [Bedrock InvokeModel Calls]                           │ │
│  │                                                         │ │
│  │ Row 2: Lambda Functions                                  │ │
│  │   [Router Lambda Invoc/Errors]                          │ │
│  │   [Action Handler Invoc/Errors]                         │ │
│  │   [Cost Controller Invoc/Errors]                        │ │
│  │                                                         │ │
│  │ Row 3: Data Layer                                        │ │
│  │   [DynamoDB Tenants RCU/WCU]                            │ │
│  │   [DynamoDB Usage RCU/WCU]                              │ │
│  │                                                         │ │
│  │ Row 4: Alarm Status                                      │ │
│  │   [3アラームの状態パネル]                               │ │
│  └─────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

---

## 6. マルチテナント設計

### テナント階層とトークン制限

```
┌─────────────┬──────────────────────────────────────────────────────┐
│ Tier        │ 特徴                                                  │
├─────────────┼──────────────────────────────────────────────────────┤
│ free        │ 最小トークン制限, guardrail必須                       │
│ standard    │ 日次100K / 月次2M, モデル自動選択                    │
│ premium     │ 日次500K / 月次10M, Sonnet固定可                     │
└─────────────┴──────────────────────────────────────────────────────┘
```

### テナント識別フロー

```
HTTP Request
  ├── Body: {"tenant_id": "xxx", ...}    ← 優先
  └── Header: x-tenant-id: xxx           ← フォールバック

↓ 未指定の場合
  "default" テナントを使用
```

### 使用量集計（DynamoDB）

```
usage テーブル書き込みパターン (Router Lambda):

UpdateItem {
  Key: {tenant_id: "T", date: "20260506"},
  UpdateExpression: "
    ADD total_tokens :tokens,
        input_tokens :in,
        output_tokens :out
    SET last_model    = :model,
        last_updated  = :ts,
        expires_at    = :ttl   ← 90日後のUnix epoch
  "
}
```

---

## 7. セキュリティ設計

### 多層防御アーキテクチャ

```
Layer 1: ネットワーク
  VPC Private Subnets → Lambda/Aurora はインターネット直接通信不可
  VPC Endpoints → AWSサービス通信はプライベートルート
  NAT Gateway → アウトバウンドのみ許可

Layer 2: エッジ保護
  WAF v2 → OWASP Top10, SQLi/XSS, IPレート制限
  API Gateway スロットリング → DoS緩和

Layer 3: 認証・認可
  OIDC → アクセスキー不要
  IAM最小権限 → リソースARN単位で制限
  SourceAccount条件 → クロスアカウント呼び出し禁止

Layer 4: データ保護
  Bedrock Guardrail → PII匿名化 + コンテンツフィルタ
  KMS暗号化 → S3, CloudTrail, Aurora
  DynamoDB SSE → 保存データ暗号化

Layer 5: 監査
  CloudTrail → 全BedrockAPI呼び出しを記録
  CloudWatch Logs → Lambda実行ログ（JSON形式）
  X-Ray → 分散トレーシング
```

### IAM設計（最小権限）

```
bedrock_invoke_role (Lambda用)
  ├── bedrock:InvokeModel
  │     Resource: 指定モデルARNのみ（Haiku, Sonnet）
  └── bedrock:ApplyGuardrail
        Condition:
          aws:SourceAccount = ${account_id}
          ArnLike: aws:SourceArn = Lambda ARN

knowledge_base_role
  ├── s3:GetObject / ListBucket  → kb-docs-* バケットのみ
  ├── bedrock:InvokeModel        → Titan Embeddings V2 のみ
  ├── rds-data:ExecuteStatement  → Aurora クラスターのみ
  └── secretsmanager:GetSecretValue → Aurora 認証情報のみ

router_lambda_role
  ├── bedrock:InvokeModel        → モデルARN限定
  ├── dynamodb:GetItem           → tenants テーブルのみ
  ├── dynamodb:GetItem/UpdateItem → usage テーブルのみ
  ├── xray:PutTraceSegments
  ├── logs:CreateLogGroup/Stream/PutLogEvents → 明示的ロググループのみ
  └── ec2:CreateNetworkInterface等 → VPCアクセス用
```

---

## 8. コスト制御設計

### コスト制御の2層構造

```
Layer 1: テナントレベル (Router Lambda)
  ┌─────────────────────────────────────────────────────────┐
  │ リクエストごとにDynamoDBで日次使用量を確認              │
  │ 上限超過 → 即座に429 Too Many Requests で拒否          │
  └─────────────────────────────────────────────────────────┘

Layer 2: インフラレベル (Cost Controller Lambda)
  ┌─────────────────────────────────────────────────────────┐
  │ 1時間ごとに全テナントをスキャン                        │
  │ 80% 到達 → SNS WARNING 通知                            │
  │ 100% 到達 → SNS EXCEEDED 通知                          │
  └─────────────────────────────────────────────────────────┘

Layer 3: AWSレベル (AWS Budgets)
  ┌─────────────────────────────────────────────────────────┐
  │ 月次コスト $30 上限                                     │
  │ 80% ($24) / 100% ($30) → SNS → Email                  │
  └─────────────────────────────────────────────────────────┘
```

### モデル選択によるコスト最適化

```
単純なプロンプト (< 1000文字 + 複雑キーワードなし)
  └── Claude 3 Haiku (最安値)

複雑なプロンプト (> 1000文字 OR 複雑キーワードあり)
  └── Claude 3.5 Sonnet (高品質)

premium テナント (preferred_model 固定)
  └── Claude 3.5 Sonnet (常時高品質)
```

---

## 9. 可観測性設計

### トレーシングパス

```
Client Request
    │
    ▼
API Gateway (アクセスログ → CloudWatch Logs)
    │
    ▼ X-Ray Trace 開始
Router Lambda ─── X-Ray Segment
    ├── DynamoDB GetItem    (Subsegment)
    ├── DynamoDB GetItem    (Subsegment)
    ├── Bedrock InvokeModel (Subsegment)
    └── DynamoDB UpdateItem (Subsegment)
    │
    ▼ (Bedrock Agent経由の場合)
Bedrock Agent ─── X-Ray Trace継続
    └── Action Handler Lambda (Subsegment)
          ├── DynamoDB Scan  (Subsegment)
          └── CloudWatch     (Subsegment)
```

### メトリクス収集パス

```
CloudTrail (Bedrock データイベント)
    │
    ▼
CloudWatch Logs (cloudtrail-log-group)
    │
    ▼
Metric Filters
    ├── BedrockInvokeCount
    └── BedrockInvokeStreamCount
    │
    ▼
CloudWatch Custom Metrics
(namespace: bedrock-ai-platform-sandbox/dev)
    │
    ▼
CloudWatch Dashboard (21ウィジェット)
```

---

## 10. CI/CD パイプライン

### GitHub Actions フロー

```
git push / Pull Request (paths: environments/**, modules/**)
    │
    ▼
GitHub Actions: terraform job
    │
    ├── 1. Checkout
    │
    ├── 2. AWS Credentials (OIDC)
    │       Role: secrets.AWS_ROLE_ARN
    │       Session: GitHubActions-Terraform
    │       ※ アクセスキー不要
    │
    ├── 3. Terraform Setup (v1.9.0)
    │
    ├── 4. terraform init
    │       backend: S3 (tfstate-bedrock-ai-platform-sandbox)
    │       lock:    DynamoDB (tfstate-lock-bedrock-ai-platform)
    │
    ├── 5. terraform fmt -check -recursive
    │
    ├── 6. terraform validate
    │
    ├── 7. terraform plan -out=tfplan
    │       -var owner=github-actions
    │
    ├── [Pull Request時のみ]
    │   └── 8. PR コメント投稿 (plan出力, 60K文字上限)
    │           既存botコメントを置き換え
    │
    └── [main マージ時のみ]
        └── 9. terraform apply -auto-approve tfplan
```

### 必要な GitHub Secrets

| Secret | 説明 |
|--------|------|
| `AWS_ROLE_ARN` | OIDC AssumeRole 対象のIAMロールARN |
| `ALERT_EMAIL` | 予算通知先メールアドレス (任意) |

---

## 11. データモデル

### DynamoDB: tenants テーブル

```json
{
  "tenant_id": "tenant-premium",          // PK
  "tier": "premium",                       // GSI PK (tier-index)
  "token_limit_daily": 500000,
  "token_limit_monthly": 10000000,
  "preferred_model": "anthropic.claude-3-5-sonnet-20241022-v2:0",
  "guardrail_enabled": true,
  "created_at": "2026-05-06T00:00:00Z"
}
```

### DynamoDB: usage テーブル

```json
{
  "tenant_id": "tenant-premium",          // PK
  "date": "20260506",                      // SK (YYYYMMDD)
  "total_tokens": 12345,
  "input_tokens": 8000,
  "output_tokens": 4345,
  "last_model": "anthropic.claude-3-5-sonnet-20241022-v2:0",
  "last_updated": "2026-05-06T12:34:56Z",
  "expires_at": 1757116800                 // TTL: 90日後
}
```

### Aurora PostgreSQL: bedrock_kb テーブル

```sql
bedrock_integration.bedrock_kb
┌────────────┬───────────────┬────────────────────────────┐
│ id (uuid)  │ embedding     │ chunks (text)               │
│ PRIMARY KEY│ vector(1024)  │ metadata (json)             │
│            │ HNSW Index    │                             │
└────────────┴───────────────┴────────────────────────────┘
※ HNSW = Hierarchical Navigable Small World (高速近傍探索)
※ 距離関数 = cosine similarity
```

---

## 12. コスト見積もり

| コンポーネント | 単価 | 月次見積もり |
|--------------|------|------------|
| NAT Gateway | $0.062/h | ~$4.50 |
| Interface VPC Endpoint (2個×2AZ) | $0.014/h/AZ | ~$14.00 |
| Aurora Serverless v2 (0.5 ACU min) | $0.12/ACU-h | ~$2〜5 |
| Aurora ストレージ (10GB) | $0.10/GB | ~$1.00 |
| S3 (ドキュメント + CloudTrailログ) | $0.025/GB | ~$0.50 |
| Bedrock API (従量課金) | モデル依存 | ~$3〜8 |
| DynamoDB (オンデマンド) | 従量 | ~$0.10 |
| Lambda | 無料枠内 | $0 |
| WAF v2 | $8/WebACL + $0.60/M req | ~$8.00 |
| API Gateway (HTTP API) | $1.00/M req | ~$0.10 |
| CloudWatch (3アラーム + ダッシュボード) | 従量 | ~$3.30 |
| **合計** | | **$36〜44/月** |

> 注意: Interface VPC Endpoint のコストが大きい。月$30以内に抑えるには Bedrock Runtime Endpoint の削除も検討余地あり（その場合 NAT Gateway 経由に変更）。

---

## 13. ディレクトリ構成

```
bedrock-ai-platform-sandbox/
├── CLAUDE.md                           ← Claude Code 設計書
├── README.md
├── ARCHITECTURE.md                     ← このファイル
│
├── .github/
│   └── workflows/
│       └── terraform.yml               ← OIDC + plan/apply
│
├── environments/
│   └── dev/
│       ├── versions.tf                 ← terraform >= 1.5.0, aws ~> 5.0
│       ├── backend.tf                  ← S3 remote state
│       ├── main.tf                     ← 9モジュール呼び出し
│       ├── variables.tf                ← region, project, env, owner, vpc_cidr
│       ├── outputs.tf                  ← 27個のアウトプット
│       └── terraform.tfvars            ← 実際の変数値
│
└── modules/
    ├── networking/
    │   ├── main.tf                     ← VPC, Subnet, NAT GW, VPC Endpoints
    │   ├── variables.tf
    │   └── outputs.tf
    │
    ├── bedrock-foundation/
    │   ├── main.tf                     ← IAM, Guardrail, CloudTrail
    │   ├── variables.tf
    │   └── outputs.tf
    │
    ├── knowledge-base/
    │   ├── main.tf                     ← S3, Aurora pgvector, Bedrock KB
    │   ├── variables.tf
    │   └── outputs.tf
    │
    ├── multi-tenant/
    │   ├── main.tf                     ← DynamoDB tenants + usage
    │   ├── variables.tf
    │   └── outputs.tf
    │
    ├── router-lambda/
    │   ├── main.tf                     ← Lambda, IAM, CloudWatch Logs
    │   ├── variables.tf
    │   ├── outputs.tf
    │   └── src/
    │       └── index.py                ← ルーティングロジック (215行)
    │
    ├── cost-controller/
    │   ├── main.tf                     ← Lambda, EventBridge, SNS, Budgets
    │   ├── variables.tf
    │   ├── outputs.tf
    │   └── src/
    │       └── index.py                ← 使用量監視 (114行)
    │
    ├── api-gateway/
    │   ├── main.tf                     ← HTTP API v2, WAF v2
    │   ├── variables.tf
    │   └── outputs.tf
    │
    ├── bedrock-agent/
    │   ├── main.tf                     ← Bedrock Agent, Action Group, Lambda
    │   ├── variables.tf
    │   ├── outputs.tf
    │   └── schema/
    │       └── infra_ops.json          ← OpenAPI 3.0 アクションスキーマ
    │
    └── observability/
        ├── main.tf                     ← X-Ray, Metrics, Alarms, Dashboard
        ├── variables.tf
        └── outputs.tf
```

---

*最終更新: 2026-05-06*
