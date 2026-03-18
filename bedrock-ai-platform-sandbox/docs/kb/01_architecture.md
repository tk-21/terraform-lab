# システムアーキテクチャ概要

## プロジェクト概要

このシステムは AWS Bedrock を基盤とする、マルチテナント対応のエンタープライズ AI プラットフォームです。
インフラ運用の自動化・AI による Q&A・コスト制御を統合的に提供します。

---

## コンポーネント構成

### ネットワーク層（networking モジュール）

| コンポーネント | 設定値 | 役割 |
|-------------|-------|------|
| VPC | CIDR: 10.0.0.0/16、DNS 解決有効 | 全リソースの基盤ネットワーク |
| パブリックサブネット | 10.0.1.0/24（AZ: ap-northeast-1a）、10.0.2.0/24（AZ: ap-northeast-1c） | NAT Gateway 配置 |
| プライベートサブネット | 10.0.11.0/24（AZ: ap-northeast-1a）、10.0.12.0/24（AZ: ap-northeast-1c） | Lambda・Aurora 配置 |
| NAT Gateway | 1台（AZ: ap-northeast-1a のパブリックサブネット） | プライベートサブネットからの外部通信 |
| VPC Endpoint（S3） | Gateway 型 | S3 への VPC 内通信（NAT Gateway 不使用） |
| VPC Endpoint（DynamoDB） | Gateway 型 | DynamoDB への VPC 内通信 |
| VPC Endpoint（bedrock-runtime） | Interface 型、プライベート DNS 有効 | Bedrock API をインターネット経由禁止 |
| VPC Endpoint（secretsmanager） | Interface 型、プライベート DNS 有効 | Secrets Manager への安全なアクセス |

**設計思想**: Bedrock への通信はインターネットを一切経由しない。VPC Endpoint により、プライベートサブネット内の Lambda が直接 Bedrock API を呼び出す。

---

### AI 基盤層（bedrock-foundation モジュール）

| コンポーネント | 設定値 | 役割 |
|-------------|-------|------|
| IAM ロール（bedrock-invoke） | Lambda がAssumeRole、SourceAccount 条件付き | Bedrock 呼び出し専用ロール |
| Bedrock Guardrail | PII 匿名化・コンテンツフィルタ・プロンプトインジェクション対策 | 有害コンテンツのブロック |
| CloudTrail | Bedrock API 全件ログ、ログファイル整合性検証 | 監査ログ |
| CloudWatch Logs | CloudTrail ログの転送先（90日保持） | メトリクスフィルタの対象 |

**Guardrail 設定**:
- PII 匿名化: EMAIL / PHONE / NAME / SSN / クレジットカード / IP アドレス（入出力ともに ANONYMIZE）
- プロンプトインジェクション: HIGH で検知・ブロック
- 性的・憎悪コンテンツ: HIGH でブロック

---

### RAG 基盤層（knowledge-base モジュール）

```
[ドキュメント（S3）]
        │ StartIngestionJob
        ▼
Titan Text Embeddings V2
（1024 次元ベクトル化）
        │ RDS Data API
        ▼
Aurora PostgreSQL 16 Serverless v2
└── bedrock_integration.bedrock_kb
    （pgvector HNSW インデックス）
        │ bedrock:Retrieve
        ▼
Router Lambda / Bedrock Agent
（RAG 検索・回答生成）
```

| コンポーネント | 設定値 | 役割 |
|-------------|-------|------|
| S3 バケット（documents） | SSE-KMS 暗号化、パブリックアクセス全ブロック、90日→ IA 移行 | ドキュメント格納 |
| Aurora PostgreSQL | Serverless v2、min 0.5 ACU / max 4.0 ACU、RDS Data API 有効 | ベクトルデータ永続化 |
| Bedrock Knowledge Base | Titan Embeddings V2、Aurora pgvector ストレージ | RAG 検索エンジン |
| S3 Data Source | チャンクサイズ 512 トークン、オーバーラップ 10% | ドキュメント分割・インデックス化 |

---

### ルーティング層（router-lambda モジュール）

プロンプトの複雑度を判定し、Haiku / Sonnet を動的に選択する Lambda。

**ルーティングロジック**:
1. テナント設定を DynamoDB から取得（preferred_model が設定されていればそのモデルを使用）
2. 日次トークン上限チェック（超過時は 429 を返却）
3. 複雑度判定:
   - プロンプト長 > 1000 文字 → Sonnet
   - 複雑系キーワード検出（analyze / compare / explain / implement / design / architect / debug / optimize 等）→ Sonnet
   - それ以外 → Haiku（コスト最適化）
4. Guardrail を適用して bedrock:InvokeModel を呼び出し
5. DynamoDB に使用トークン数を記録

---

### マルチテナント層（multi-tenant モジュール）

| テーブル | パーティションキー | ソートキー | 用途 |
|---------|-----------------|----------|------|
| tenants | tenant_id（S） | なし | テナント設定（tier、トークン上限、preferred_model） |
| usage | tenant_id（S） | date（S: YYYYMMDD） | 日次トークン使用量（TTL: 90日） |

**テナント Tier**:
- `free`: 日次 10,000 トークン、Haiku のみ
- `standard`: 日次 100,000 トークン、ルーティング対応
- `premium`: 日次 500,000 トークン、Sonnet 固定

---

### コスト制御層（cost-controller モジュール）

- EventBridge により 1 時間ごとに Lambda を起動
- DynamoDB の usage テーブルを全テナントスキャン
- トークン使用量が日次上限の 80% を超えたテナントを検出し、SNS 経由で通知
- AWS Budgets で月額 $30 上限アラートを設定（80% / 100% 閾値で通知）

---

### API 層（api-gateway モジュール）

| コンポーネント | 設定値 | 役割 |
|-------------|-------|------|
| WAF v2 WebACL | OWASP 共通ルール・既知悪意パターン・IP レートリミット（5分/IP） | 攻撃遮断 |
| HTTP API（v2） | CORS 設定（x-tenant-id ヘッダー許可）、スロットリング burst 100 / rate 50 | エンドポイント公開 |
| Lambda Integration | router-lambda へのプロキシ統合（payload format 2.0） | リクエスト転送 |
| アクセスログ | CloudWatch Logs、30日保持 | 監査・デバッグ |

**エンドポイント**: `POST https://<api_id>.execute-api.ap-northeast-1.amazonaws.com/chat`

---

### Bedrock Agent 層（bedrock-agent モジュール）

インフラ運用専用の AI エージェント。Knowledge Base による RAG と、Action Group による実行能力を持つ。

**Action Group: infra-ops**

| オペレーション | 説明 |
|-------------|------|
| getInfraStatus | インフラコンポーネントの稼働状況を返す |
| getCostSummary | DynamoDB から月次トークン使用量を集計して返す |
| getActiveAlerts | 発生中の CloudWatch Alarm 一覧を返す |

---

### 可観測性層（observability モジュール）

| コンポーネント | 内容 |
|-------------|------|
| X-Ray Group | Lambda トレースを集約、Insights 有効 |
| CloudWatch Metric Filter | CloudTrail から InvokeModel / InvokeModelWithResponseStream をカウント抽出 |
| CloudWatch Alarm × 3 | Router Lambda errors / Cost Controller errors / API 5xx |
| CloudWatch Dashboard | API Gateway・Lambda × 3・DynamoDB × 2・Bedrock 呼び出し数・Alarm Status（21 ウィジェット） |

---

## データフロー全体図

```
[外部クライアント]
        │ POST /chat
        ▼
WAF v2 ─▶ API Gateway HTTP API
                │
                ▼
        router-lambda（VPC プライベートサブネット）
                │
                ├─▶ DynamoDB: テナント設定取得・使用量記録
                │
                ├─▶ bedrock:InvokeModel（Haiku or Sonnet）
                │       └── VPC Endpoint 経由（インターネット非通過）
                │               └── Guardrail 適用
                │
                └─▶ bedrock:RetrieveAndGenerate（RAG 時）
                        └── Knowledge Base → Aurora pgvector

[Bedrock Agent]（別経路: InvokeAgent API）
        │
        ├─▶ Knowledge Base: Retrieve（pgvector 近似最近傍検索）
        └─▶ Action Group Lambda: infra-ops
                └─▶ DynamoDB: 使用量集計
```
