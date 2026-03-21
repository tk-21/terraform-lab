# Streaming Analytics Sandbox

## プロジェクト概要
リアルタイムイベントストリームをデータレイクへ格納・変換・分析する Terraform プロジェクト。
「ストリームが S3 に届くまで」「JSON が Parquet になるまで」を全工程 IaC で体験する。

## 技術スタック
- IaC: Terraform（モジュール化必須）
- クラウド: AWS ap-northeast-1
- 認証: OIDC（アクセスキー禁止）
- CI/CD: GitHub Actions
- 言語: Python 3.12（Firehose 変換 Lambda）、PySpark 3.3（Glue ETL）

---

## ディレクトリ構成

```
streaming-analytics-sandbox/
├── CLAUDE.md
├── README.md
├── .github/workflows/terraform.yml
├── environments/dev/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── terraform.tfvars
│   ├── backend.tf
│   └── versions.tf
└── modules/
    ├── data-lake/      ← S3 3 ゾーン（raw / processed / scripts / athena-results）
    ├── kinesis/        ← KDS + Firehose（変換 Lambda + 動的パーティショニング）
    ├── producer/       ← API Gateway REST → KDS 直接統合（Lambda ゼロ）
    ├── glue/           ← Glue Crawler + ETL Job（JSON → Parquet）
    ├── athena/         ← Athena Workgroup + Named Queries
    └── observability/  ← CloudWatch Dashboard + Alarms
```

---

## 設計原則

1. **VPC なし** — Kinesis / Firehose / Glue / Athena はフルマネージド。ネットワーク設計不要。
2. **Lambda は変換目的のみ** — Firehose 変換 Lambda 1 つだけ。インジェストは API GW 直接統合。
3. **S3 3 ゾーン** — raw（JSON）→ processed（Parquet）→ curated（集計）の責務分離。
4. **コスト制御** — Athena workgroup に 1 GB/query の scan limit。Glue G.1X × 2 workers。

---

## タグ戦略（全リソース必須）

```hcl
tags = {
  Environment = "dev"
  Project     = "streaming-analytics-sandbox"
  Owner       = "your-name"
  CostCenter  = "personal"
}
```

provider の `default_tags` で一括付与。モジュール呼び出し側で `tags =` は不要。

---

## モジュール間依存関係

```
data-lake
  └──▶ kinesis  (raw_bucket_arn)
  └──▶ glue     (raw_bucket_id, processed_bucket_id, scripts_bucket_id)
  └──▶ athena   (athena_results_bucket_arn, processed_bucket_id)
kinesis
  └──▶ producer (kinesis_stream_name, kinesis_stream_arn)
全モジュール ──▶ observability
```

---

## イベントデータモデル

```json
{
  "event_id":   "uuid",
  "event_type": "page_view | add_to_cart | purchase | search",
  "user_id":    "usr_xxx",
  "tenant_id":  "tenant-a | tenant-b",
  "timestamp":  "2024-01-15T10:30:00Z",
  "payload": {
    "product_id": "prod_xxx",
    "amount":     1500.0,
    "query":      "terraform tutorial"
  },
  "ingested_at": "(Firehose 変換 Lambda が付与)"
}
```

---

## S3 パス設計（Hive スタイル）

| ゾーン | パス | フォーマット |
|-------|------|------------|
| raw | `events/event_type={type}/year={y}/month={m}/day={d}/hour={h}/` | JSON（NDJSON） |
| processed | `events/event_type={type}/year={y}/month={m}/day={d}/hour={h}/` | Parquet（SNAPPY） |

Glue Crawler が `event_type`, `year`, `month`, `day`, `hour` をパーティションとして自動認識する。

---

## Firehose 動的パーティショニングの仕組み

```
KDS → Firehose
  [Processing]
    1. Lambda transform  → ingested_at 付与・バリデーション
    2. MetadataExtraction (JQ: {event_type:.event_type})
    3. AppendDelimiterToRecord (\n)
  [Delivery]
    prefix: events/event_type=!{partitionKeyFromQuery:event_type}/year=.../...
    → S3 raw zone（NDJSON）
```

---

## 構築スケジュール

| Week | モジュール |
|------|-----------|
| 1 | data-lake（S3 3 ゾーン + ライフサイクル） |
| 2 | kinesis（KDS + Firehose + 変換 Lambda） |
| 3 | producer（API Gateway → KDS 直接統合） |
| 4 | glue（Crawler + ETL Job: JSON → Parquet） |
| 5 | athena（Workgroup + Named Queries） |
| 6 | observability + GitHub Actions CI/CD |

---

## VPC エンドポイント

このプロジェクトは VPC を持たない。すべてのサービスはパブリックエンドポイント経由でアクセスする。
セキュリティは IAM 最小権限 + S3 パブリックアクセスブロック + Kinesis SSE で担保する。

---

## Glue ETL スクリプト

`modules/glue/scripts/etl_raw_to_processed.py`
- 入力: Glue Catalog（raw zone の JSON）
- 出力: S3 processed zone（Parquet、SNAPPY 圧縮）
- パーティション列: `event_type`, `year`, `month`, `day`, `hour`
- `aws_s3_object` で S3 scripts バケットにアップロードされる
