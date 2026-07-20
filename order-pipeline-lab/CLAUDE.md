# order-pipeline-lab — Claude Code 規約

## プロジェクト概要
ECサイト注文処理を模した、障害耐性重視の非同期処理パイプライン。
面接・ポートフォリオで「なぜこの設計か」を口頭で説明できることがゴール。

**コアアーキテクチャ:**
```
API Gateway → SQS(注文キュー) → Step Functions
  ├── Lambda: 在庫確認
  ├── ECS Fargate: 決済処理（Dockerコンテナ）
  ├── Lambda: 通知送信
  └── 失敗時: DLQ → Lambda 補償処理
DynamoDB: 注文ステータス管理
CloudWatch + X-Ray: 可観測性
```

---

## ディレクトリ構成規約

```
order-pipeline-lab/
├── CLAUDE.md
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── modules/
│       ├── sqs/
│       ├── step_functions/
│       ├── lambda/
│       ├── ecs/
│       └── monitoring/
├── lambda/
│   ├── inventory-check/      # Python 3.12, arm64
│   ├── notification/         # Python 3.12, arm64
│   └── dlq-reprocessor/      # Python 3.12, arm64
├── ecs/
│   └── payment-processor/    # Dockerコンテナ (Python)
│       ├── Dockerfile
│       ├── app.py
│       └── requirements.txt
├── step_functions/
│   └── order-pipeline.asl.json
└── docs/
    └── adr/
        ├── adr-001-sqs-visibility-timeout.md
        ├── adr-002-step-functions-retry.md
        └── adr-003-dlq-compensation.md
```

---

## 命名規約

| リソース | 命名パターン | 例 |
|---------|------------|-----|
| SQSキュー | `{project}-{role}-queue` | `order-pipeline-orders-queue` |
| DLQ | `{project}-{role}-dlq` | `order-pipeline-orders-dlq` |
| Lambda | `{project}-{function}` | `order-pipeline-inventory-check` |
| ECS Cluster | `{project}-cluster` | `order-pipeline-cluster` |
| ECS Service | `{project}-{role}-svc` | `order-pipeline-payment-svc` |
| Step Functions | `{project}-{name}-sfn` | `order-pipeline-order-sfn` |
| DynamoDB | `{project}-{table}` | `order-pipeline-orders` |
| ECR | `{project}/{image}` | `order-pipeline/payment-processor` |

---

## コスト制約 (MUST)

- **NAT Gateway 禁止** — VPC Endpoint で代替 (SQS/DynamoDB/ECR/CloudWatch)
- Lambda: `arm64` + `python3.12` 固定
- ECS Fargate: `arm64` + Spot 優先 (`FARGATE_SPOT` capacity provider)
- DynamoDB: オンデマンドモード (PAY_PER_REQUEST)
- 推定コスト上限: ~$5/month (常時稼働なし、テスト実行のみ)

---

## 禁止パターン (NEVER)

```
# NAT Gateway
resource "aws_nat_gateway" ...  # ← 禁止

# Lambda inline コード
handler = "inline_code"  # ← 禁止、必ずファイル参照

# ワイルドカードIAM
"Action": ["*"]  # ← 禁止

# ハードコード認証情報
aws_access_key_id = "AKIA..."  # ← 禁止

# ECS Public IP なしでの ECR pull (VPC Endpoint 必須)
assign_public_ip = false  # ECR endpoint なしは禁止
```

---

## Terraform 規約

- `terraform fmt` 適用済みのコードのみコミット
- 全リソースに `tags` ブロック必須:
  ```hcl
  tags = {
    Project     = "order-pipeline-lab"
    Environment = "dev"
    ManagedBy   = "terraform"
  }
  ```
- `locals` でタグをまとめて定義、各リソースで `merge()` する
- `output.tf` に接続情報・ARN を必ず出力
- State は local (S3バックエンドは Phase 追加課題)

---

## Lambda 規約

- Runtime: `python3.12`, Architecture: `arm64`
- Lambda Powertools for Python 必須 (Logger, Tracer, Metrics)
- 環境変数は SSM Parameter Store 参照、ハードコード禁止
- タイムアウト: デフォルト 30秒、用途に応じて調整
- コメント: 日本語で「なぜ」を書く (「何をするか」は不要)

```python
# なぜ: DLQメッセージの受信回数をチェックし、
#       maxReceiveCount 超過時は補償処理に切り替える
receive_count = int(record["attributes"]["ApproximateReceiveCount"])
```

---

## ECS / Docker 規約

- ベースイメージ: `python:3.12-slim` (arm64)
- 非rootユーザーで実行 (`USER appuser`)
- `.dockerignore` 必須
- ヘルスチェック実装必須
- Fargate タスクサイズ: `cpu=256, memory=512` (最小構成)

---

## Step Functions 規約

- ASL (Amazon States Language) は JSON で管理
- 全 Task に `Retry` ブロック必須:
  ```json
  "Retry": [
    {
      "ErrorEquals": ["Lambda.ServiceException", "Lambda.TooManyRequestsException"],
      "IntervalSeconds": 2,
      "MaxAttempts": 3,
      "BackoffRate": 2.0
    }
  ]
  ```
- 全 Task に `Catch` ブロック必須 (補償処理へルーティング)
- X-Ray トレーシング: 有効化必須

---

## SQS 規約

| パラメータ | 値 | 理由 |
|-----------|-----|------|
| `visibility_timeout_seconds` | 300 | Step Functions 最大実行時間より長く設定 |
| `message_retention_seconds` | 86400 (1日) | DLQ 調査時間を確保 |
| `max_receive_count` | 3 | 3回失敗でDLQへ |
| DLQ `message_retention_seconds` | 604800 (7日) | 調査・再処理の猶予 |

---

## ADR (Architecture Decision Record) 規約

- `docs/adr/` に Markdown で作成
- 形式: `## Context / ## Decision / ## Consequences`
- **AI生成コンテンツ禁止**: 自分の言葉で記述すること
- 各フェーズ完了後に必ず該当ADRを記述

---

## フェーズ完了チェックリスト

各 phase.md 末尾のチェックリストを全項目 ✅ にしてから次フェーズへ。
口頭説明チェック: 「この設計を15分で説明できるか？」を自問する。

---

## 主要リージョン

`ap-northeast-1` (Tokyo) 固定