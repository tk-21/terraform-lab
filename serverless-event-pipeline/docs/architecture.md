# アーキテクチャ概要

## システム全体図

```mermaid
graph TB
    subgraph Ingestion["データ投入層"]
        S3IN[S3 PUT]
        APIGW[API Gateway POST]
        KDS[Kinesis Data Streams<br/>sep-&lt;env&gt;-events-stream]
    end

    subgraph Lambda["Lambda 処理層"]
        INGESTOR[ingestor<br/>バリデーション・正規化]
        TRANSFORMER[transformer<br/>ビジネスロジック変換]
        AGGREGATOR[aggregator<br/>集計処理]
        DLQHANDLER[dlq-handler<br/>失敗イベント再処理]
    end

    subgraph Queue["メッセージキュー"]
        SQS[SQS<br/>sep-&lt;env&gt;-transform-queue]
        DLQ[DLQ<br/>sep-&lt;env&gt;-transform-dlq]
    end

    subgraph Storage["ストレージ層"]
        DDB[DynamoDB<br/>sep-&lt;env&gt;-events]
        S3ARCH[S3 Parquet<br/>sep-&lt;env&gt;-archive-&lt;account_id&gt;]
        S3DL[S3 Dead Letter<br/>sep-&lt;env&gt;-dead-letter-archive-&lt;account_id&gt;]
    end

    subgraph Observability["オブザーバビリティ"]
        XRAY[X-Ray<br/>分散トレーシング]
        CW[CloudWatch<br/>メトリクス・アラーム]
        SNS[SNS<br/>アラート通知]
    end

    S3IN --> INGESTOR
    APIGW --> KDS
    KDS --> INGESTOR
    INGESTOR --> SQS
    SQS --> TRANSFORMER
    SQS -- 失敗時 --> DLQ
    TRANSFORMER --> DDB
    TRANSFORMER --> S3ARCH
    DDB -- DynamoDB Streams --> AGGREGATOR
    DLQ -- アラーム起動 --> DLQHANDLER
    DLQHANDLER -- 一時エラー --> SQS
    DLQHANDLER -- 恒久エラー --> S3DL
    CW -- 閾値超過 --> SNS

    INGESTOR -.-> XRAY
    TRANSFORMER -.-> XRAY
    AGGREGATOR -.-> XRAY
    DLQHANDLER -.-> XRAY
    INGESTOR -.-> CW
    TRANSFORMER -.-> CW
```

## コンポーネント詳細

### Lambda 関数

| 関数名 | トリガー | 主な処理 | 出力先 |
|---|---|---|---|
| `sep-<env>-ingestor` | Kinesis / S3 / API GW | JSON バリデーション・正規化 | SQS transform-queue |
| `sep-<env>-transformer` | SQS transform-queue | ビジネスロジック変換 | DynamoDB / S3 Parquet |
| `sep-<env>-aggregator` | DynamoDB Streams | ステータス別集計 | DynamoDB（集計テーブル更新） |
| `sep-<env>-dlq-handler` | CloudWatch Alarm / スケジュール | 失敗分類・再エンキュー | SQS / S3 dead-letter-archive |

### データフロー

```
1. クライアントがイベントを投入（API GW POST / S3 PUT / Kinesis PUT）
2. ingestor が Pydantic v2 でバリデーション・正規化
3. 正規化済みイベントを SQS transform-queue に送信
4. transformer がビジネスロジック変換を適用
5. 変換済みデータを DynamoDB（ホット）と S3 Parquet（コールド）に書き込み
6. DynamoDB Streams が aggregator をトリガー
7. aggregator がステータス別集計メトリクスを更新
```

### エラーハンドリング

```
transformer 処理失敗
  → Lambda 自動リトライ（最大 2 回、指数バックオフ）
  → 全リトライ失敗 → SQS DLQ に移動
  → CloudWatch Alarm (DLQメッセージ数 >= 1)
  → SNS 通知 → dlq-handler 起動
  → 一時エラー: 元キューに再エンキュー（指数バックオフ付き）
  → 恒久エラー: S3 dead-letter-archive に保存
```

## インフラ構成

### Terraform モジュール構成

```
terraform/modules/
├── lambda-function/   # Lambda 関数共通設定（arm64, Powertools, X-Ray）
├── kinesis-pipeline/  # Kinesis Data Streams + Lambda ESM
├── sqs-pipeline/      # SQS + Lambda ESM（DLQ 必須）
├── dynamodb/          # テーブル・GSI・Streams・TTL・PITR
├── observability/     # X-Ray グループ・CloudWatch ダッシュボード・アラーム
└── iam/               # Lambda 実行ロール（最小権限）
```

### セキュリティ設計

- Lambda 実行ロール: 最小権限（`*` リソース指定禁止）
- 秘匿情報: SSM Parameter Store 経由（環境変数ハードコード禁止）
- S3 バケット: パブリックアクセスブロック有効・KMS 暗号化
- DynamoDB: 保管時暗号化（AWS マネージドキー）
- Kinesis: KMS サーバーサイド暗号化

### コスト見積もり（月額）

| リソース | 概算コスト |
|---|---|
| Kinesis Data Streams (1 shard) | ~$15 |
| Lambda 実行 | ~$0（無料枠内） |
| DynamoDB PAY_PER_REQUEST | ~$0（低トラフィック時） |
| S3 ストレージ | ~$0.1 |
| CloudWatch | ~$1 |
| **合計** | **~$16/月** |

> 検証後は Kinesis を 1 shard に削減して目標 $5 以下を目指す。
