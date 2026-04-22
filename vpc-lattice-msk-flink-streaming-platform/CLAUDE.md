# vpc-lattice-msk-flink-streaming-platform

## プロジェクト概要

VPC Lattice + Amazon MSK + Amazon Managed Service for Apache Flink を組み合わせた
リアルタイムストリーミング基盤のTerraformハンズオンプロジェクト。

Lambda Producerがダミーデータ（構造化JSONログ）を生成してMSK Kafkaトピックに送信し、
VPC Lattice経由でサービス間通信を制御しながら、Apache Flinkがリアルタイム集計して
S3にParquet形式で保存する。

---

## ディレクトリ構造

```
vpc-lattice-msk-flink-streaming-platform/
├── CLAUDE.md
├── README.md
├── terraform/
│   ├── main.tf                    # Provider設定・backend
│   ├── variables.tf               # 変数定義
│   ├── outputs.tf                 # 出力値
│   ├── locals.tf                  # ローカル値・共通タグ
│   ├── modules/
│   │   ├── networking/            # VPC・サブネット・SG
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   ├── vpc_lattice/           # VPC Lattice Service Network・Service・Association
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   ├── msk/                   # MSK Serverless クラスター・トピック設定
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   ├── flink/                 # Managed Service for Apache Flink アプリ
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   ├── lambda_producer/       # ダミーデータ生成Lambda
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   ├── outputs.tf
│   │   │   └── src/
│   │   │       └── producer.py
│   │   └── s3/                    # 出力先S3バケット
│   │       ├── main.tf
│   │       ├── variables.tf
│   │       └── outputs.tf
├── flink-app/
│   ├── pom.xml                    # Maven設定（Flink Java アプリ）
│   └── src/main/java/
│       └── com/example/streaming/
│           └── StreamingJob.java  # Flink ジョブ本体
└── scripts/
    ├── build_flink_app.sh         # Flinkアプリビルド・S3アップロード
    └── test_producer.sh           # Lambda手動呼び出しテスト
```

---

## 命名規則

| リソース種別 | 命名パターン | 例 |
|---|---|---|
| VPC | `{project}-vpc` | `streaming-vpc` |
| MSK Cluster | `{project}-msk-cluster` | `streaming-msk-cluster` |
| MSK Topic | `{project}-events` | `streaming-events` |
| VPC Lattice Service Network | `{project}-service-network` | `streaming-service-network` |
| VPC Lattice Service | `{project}-msk-service` | `streaming-msk-service` |
| Flink App | `{project}-flink-app` | `streaming-flink-app` |
| Lambda | `{project}-producer` | `streaming-producer` |
| S3 Bucket | `{project}-output-{account_id}` | `streaming-output-123456789012` |
| IAM Role | `{project}-{service}-role` | `streaming-flink-role` |

---

## タグ戦略

全リソースに以下のタグを付与：

```hcl
locals {
  common_tags = {
    Project     = "vpc-lattice-msk-flink-streaming-platform"
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "takuya"
    CostCenter  = "portfolio"
  }
}
```

---

## 設計方針

### VPC Lattice の役割
- MSK Serviceを VPC Lattice Service として登録
- Service NetworkをVPCにアソシエーション
- Lambda ProducerはVPC Lattice経由でMSKエンドポイントに接続
- L7レベルのアクセスポリシーでKafka通信を制御
- 将来的なマルチVPC/マルチアカウント拡張を想定した設計

### MSK 設計
- **MSK Serverless** を使用（ブローカー管理不要、コスト効率）
- トピック: `streaming-events`（パーティション3）
- IAM認証（SASL/IAM）を使用
- クライアント: Lambda Producer（書き込み）、Flink（読み込み）

### Flink アプリ設計
- **Parallelism**: 1（コスト最適化）
- Source: MSK Kafkaトピック（Flink Kafka Connector）
- 処理: 60秒タンブリングウィンドウで`service_name`別にイベント集計
- Sink: S3（Parquet形式、時刻パーティション）
- チェックポイント: 60秒間隔、S3バックエンド

### Lambda Producer 設計
- Python 3.12 / arm64
- AWS Lambda Powertools（ログ構造化）
- 1回の呼び出しで100件のダミーイベントを生成してKafkaに送信
- EventBridge Schedulerで5分おきに自動実行
- ダミーデータスキーマ:
  ```json
  {
    "event_id": "uuid",
    "timestamp": "ISO8601",
    "service_name": "auth|api|payment|notification",
    "action": "login|request|charge|send",
    "user_id": "u_XXXX",
    "latency_ms": 10-500,
    "status": "success|error|timeout",
    "region": "ap-northeast-1"
  }
  ```

### S3 出力設計
- バケット: バージョニング有効、暗号化（SSE-S3）
- パス: `s3://streaming-output-{account}/events/year=YYYY/month=MM/day=DD/hour=HH/`
- フォーマット: Parquet（Snappy圧縮）
- Athena対応: Glue Data Catalogへの自動登録は Phase 4 で実施

---

## コスト見積もり

| サービス | 月額概算 |
|---|---|
| MSK Serverless | $0（無料枠）〜 $10 |
| Managed Flink | $0.11/KPU時 × 1KPU = ~$8 |
| Lambda Producer | ほぼ $0 |
| S3 | < $1 |
| VPC Lattice | $0.025/万リクエスト |
| **合計** | **~$20/月** |

---

## 禁止パターン

- MSK ブローカー認証に PLAINTEXT は使わない（IAM認証を使用）
- Flink アプリに IAM アクセスキーをハードコードしない（IRSA / IAM Role使用）
- S3バケットのパブリックアクセスを有効にしない
- MSK クラスターをパブリックサブネットに配置しない
- `terraform apply` 前に `terraform plan` の出力を必ず確認する

---

## 実行環境

- **Region**: ap-northeast-1（東京）
- **Terraform**: >= 1.6
- **Provider**: hashicorp/aws >= 5.0
- **Python**: 3.12（Lambda）
- **Java**: 17（Flink アプリ）
- **Flink Runtime**: 1.19

---

## CI/CD

- GitHub Actions + OIDC認証（アクセスキー不使用）
- `terraform fmt` → `terraform validate` → `terraform plan` の自動実行
- Flinkアプリは `mvn package` でビルドしてS3にアップロード