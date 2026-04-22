# ✅Phase 4: オブザーバビリティ・Glue Data Catalog・CI/CD・README整備

## このフェーズの概要（Phase 1〜3 の続き）

Phase 1〜3 で以下が動作している前提：
- VPC / ネットワーク基盤
- MSK Serverless（Kafkaにデータ蓄積中）
- Lambda Producer（5分おきにデータ送信中）
- VPC Lattice（Service Network・Service稼働中）
- Managed Apache Flink（S3にParquetファイルを出力中）

このフェーズで作成するもの：
- CloudWatch Dashboard（全体監視）
- Glue Data Catalog（S3 ParquetをAthenaで検索可能に）
- GitHub Actions CI/CDパイプライン
- README.md（ポートフォリオ品質）
- アーキテクチャ図（Mermaid）

---

## タスク一覧

### 1. CloudWatch Dashboardの作成

`terraform/modules/observability/main.tf` を作成する。

```
# [1] CloudWatch Dashboard
# resource: aws_cloudwatch_dashboard
# dashboard_name: "${var.name_prefix}-streaming-dashboard"
#
# ウィジェット構成（JSON定義）:
#
# 行1: MSK メトリクス（2カラム）
#   - BytesInPerSec: Kafkaへの書き込みバイト数
#   - BytesOutPerSec: Kafkaからの読み込みバイト数
#   # 日本語コメント: MSK ServerlessはClientID別ではなくCluster単位のメトリクスのみ提供
#
# 行2: Lambda Producerメトリクス（3カラム）
#   - Invocations: 実行回数
#   - Errors: エラー回数
#   - Duration: 実行時間（P99）
#
# 行3: Flink メトリクス（2カラム）
#   - numRecordsInPerSecond: Kafkaからの読み込みレコード数/秒
#   - numRecordsOutPerSecond: S3への書き込みレコード数/秒
#   - lastCheckpointDuration: チェックポイント所要時間
#   # 日本語コメント: FlinkメトリクスはKinesis Analytics名前空間で確認
#
# 行4: VPC Lattice メトリクス（2カラム）
#   - RequestCount: リクエスト数
#   - HTTPCode_Target_5XX_Count: バックエンドエラー数
#
# [2] CloudWatch Alarm（Flink アプリ停止検知）
# resource: aws_cloudwatch_metric_alarm
# alarm_name: "${var.name_prefix}-flink-no-records"
# metric_name: "numRecordsInPerSecond"
# namespace: "AWS/KinesisAnalytics"
# comparison_operator: "LessThanThreshold"
# threshold: 0.1
# evaluation_periods: 3
# period: 300
# alarm_description: "Flinkアプリがメッセージを処理していない可能性があります"
# # 日本語コメント: 5分間でレコード数が0.1未満なら異常とみなす
```

---

### 2. Glue Data Catalog の作成

`terraform/modules/glue/main.tf` を作成する。

```
# [1] Glue Database
# resource: aws_glue_catalog_database
# name: "${var.name_prefix}_streaming_db"
# # 日本語コメント: Glue Data CatalogはAthenaのメタデータストアとして機能
# # S3のParquetファイルを仮想テーブルとして定義することでSQLクエリが可能に
#
# [2] Glue Table（service_metricsテーブル）
# resource: aws_glue_catalog_table
# name: "service_metrics"
# database_name: glue_database.name
# table_type: "EXTERNAL_TABLE"
# parameters:
#   classification: "parquet"
#   "parquet.compression": "SNAPPY"
#
# partition_keys:
#   - name: "year", type: "string"
#   - name: "month", type: "string"
#   - name: "day", type: "string"
#   - name: "hour", type: "string"
#
# storage_descriptor:
#   location: "s3://${var.output_bucket_name}/events/"
#   input_format: "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
#   output_format: "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"
#   ser_de_info:
#     serialization_library: "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
#   columns:
#     - name: "service_name", type: "string"
#     - name: "total_count", type: "bigint"
#     - name: "error_count", type: "bigint"
#     - name: "avg_latency_ms", type: "double"
#     - name: "window_start", type: "string"
#     - name: "window_end", type: "string"
#
# [3] Athena Workgroup
# resource: aws_athena_workgroup
# name: "${var.name_prefix}-workgroup"
# configuration:
#   result_configuration:
#     output_location: "s3://${var.output_bucket_name}/athena-results/"
#   engine_version:
#     selected_engine_version: "Athena engine version 3"
# # 日本語コメント: Athena engine v3はv2比でクエリ性能が向上しParquet読み込みが高速
```

---

### 3. GitHub Actions CI/CDパイプラインの作成

`.github/workflows/terraform.yml` を作成する。

```yaml
# パイプライン要件:
#
# トリガー:
#   - push to main ブランチ
#   - pull_request to main ブランチ
#
# 環境変数:
#   AWS_REGION: ap-northeast-1
#   TF_VERSION: 1.6.6
#
# jobs:
#
# [1] terraform-check（PR・pushで実行）
#   runs-on: ubuntu-latest
#   steps:
#     - uses: actions/checkout@v4
#     - uses: aws-actions/configure-aws-credentials@v4
#       with:
#         role-to-assume: ${{ secrets.AWS_ROLE_ARN }}  # OIDC認証
#         aws-region: ${{ env.AWS_REGION }}
#         # 日本語コメント: GitHub ActionsはOIDCトークンで一時クレデンシャスを取得
#         # アクセスキーをSecretsに保存する方式は採用しない（セキュリティリスク）
#     - uses: hashicorp/setup-terraform@v3
#       with:
#         terraform_version: ${{ env.TF_VERSION }}
#     - name: Terraform Format Check
#       run: terraform -chdir=terraform fmt -check -recursive
#     - name: Terraform Init
#       run: terraform -chdir=terraform init -backend=false
#     - name: Terraform Validate
#       run: terraform -chdir=terraform validate
#
# [2] terraform-plan（PRのみ）
#   needs: terraform-check
#   if: github.event_name == 'pull_request'
#   steps:
#     - (checkoutとcredentials設定は同様)
#     - name: Terraform Plan
#       run: |
#         terraform -chdir=terraform init
#         terraform -chdir=terraform plan \
#           -var="aws_account_id=${{ secrets.AWS_ACCOUNT_ID }}" \
#           -no-color \
#           -out=tfplan
#     - name: Post Plan to PR
#       uses: actions/github-script@v7
#       # planの結果をPRコメントに自動投稿
#
# permissions:
#   id-token: write  # OIDC必須
#   contents: read
#   pull-requests: write  # PRコメント投稿用
```

---

### 4. README.md の作成（ポートフォリオ品質）

`README.md` を作成する。以下の構成で日本語・英語併記で記載すること。

```markdown
# vpc-lattice-msk-flink-streaming-platform

> Real-time streaming platform using VPC Lattice × Amazon MSK × Apache Flink on AWS

## Architecture

[Mermaidアーキテクチャ図を挿入]
flowchart LR
  subgraph Producer["Lambda Producer (arm64)"]
    LP[Dummy Event Generator\n100 events/5min]
  end
  subgraph VPCLattice["VPC Lattice"]
    SN[Service Network\nIAM Auth Policy]
    SVC[MSK Service\nTCP Listener :9098]
  end
  subgraph MSK["Amazon MSK Serverless"]
    T[Topic: streaming-events\nSASL/IAM Auth]
  end
  subgraph Flink["Managed Apache Flink 1.19"]
    F[StreamingJob\n60s Tumbling Window\nParallelism=1]
  end
  subgraph Storage["S3 Output"]
    S3[Parquet + Snappy\nyear/month/day/hour パーティション]
    GC[Glue Data Catalog\nAthena Queryable]
  end

  LP -->|EventBridge Scheduler 5min| SN
  SN --> SVC --> T
  T -->|Kafka Consumer| F
  F -->|FileSink| S3
  S3 --> GC

## 主要コンポーネント

### VPC Lattice
- Service Networkを介したL7アクセス制御
- IAM Auth Policyで「どのロールがどのサービスに接続できるか」を宣言
- 将来のマルチアカウント展開をAWS RAM経由でゼロ変更対応

### Amazon MSK Serverless
- ブローカー管理不要のフルマネージドKafka
- SASL/IAM認証でアクセスキー不使用
- ポート9098 (TLS) のみ開放

### Managed Service for Apache Flink
- Parallelism=1でコスト最適化（約$8/月）
- 60秒タンブリングウィンドウで service_name 別に集計
- EXACTLY_ONCEセマンティクスで正確な集計を保証

## Getting Started

### Prerequisites
- Terraform >= 1.6
- Java 17（Flinkアプリビルド用）
- AWS CLI v2

### Deploy

\`\`\`bash
# 1. Flinkアプリをビルド
bash scripts/build_flink_app.sh YOUR_FLINK_APP_BUCKET

# 2. インフラをデプロイ
cd terraform
terraform init
terraform apply -var="aws_account_id=YOUR_ACCOUNT_ID"

# 3. Flinkアプリを起動
aws kinesisanalyticsv2 start-application \
  --application-name streaming-flink-app \
  --region ap-northeast-1
\`\`\`

### Verify

\`\`\`bash
# S3にParquetが出力されているか確認（約6分後）
aws s3 ls s3://streaming-output-YOUR_ACCOUNT/events/ --recursive

# Athenaでクエリ
# SELECT service_name, SUM(total_count), AVG(avg_latency_ms)
# FROM streaming_db.service_metrics
# WHERE year='2026' AND month='04'
# GROUP BY service_name
\`\`\`

## Cost Estimate
| Service | Monthly Cost |
|---|---|
| MSK Serverless | ~$5 |
| Managed Flink (1 KPU) | ~$8 |
| Lambda Producer | < $1 |
| S3 | < $1 |
| VPC Lattice | < $1 |
| **Total** | **~$15/month** |

## Architecture Decisions

### なぜVPC LatticeをMSK接続に使うのか
[Phase 3のREADME追記内容を再掲]

## Cleanup
\`\`\`bash
# Flinkアプリを停止してから destroy
aws kinesisanalyticsv2 stop-application --application-name streaming-flink-app
cd terraform && terraform destroy -var="aws_account_id=YOUR_ACCOUNT_ID"
\`\`\`
```

---

### 5. outputs.tf の完成

`terraform/outputs.tf` に全フェーズ分のoutputを集約する。

```hcl
# 出力すべき値:
# - vpc_id
# - msk_bootstrap_brokers_sasl_iam
# - flink_app_name
# - vpc_lattice_service_network_arn
# - output_bucket_name
# - glue_database_name
# - athena_workgroup_name
# - cloudwatch_dashboard_url（マネコンURLを動的生成）
```

---

## 完了条件

- [ ] CloudWatch Dashboardでリアルタイムメトリクスが表示される
- [ ] Glue Data CatalogにテーブルがREADY状態で登録される
- [ ] AthenaでSELECT文が実行できS3のParquetデータが取得できる
- [ ] GitHub ActionsのOIDCが設定され、PRでterraform planが自動実行される
- [ ] README.mdにMermaidアーキテクチャ図が含まれる
- [ ] `terraform output` で全主要リソースのARN・名前が確認できる
- [ ] `terraform destroy` で全リソースがクリーンアップできる

---

## ポートフォリオ完成後のZenn記事構成（参考）

```
タイトル: 「VPC Lattice × MSK Serverless × Managed Flink で作るリアルタイムストリーミング基盤」

章構成:
1. なぜこの組み合わせなのか（従来方式との比較）
2. VPC Latticeの仕組み（Service Network・Service・Auth Policy）
3. MSK ServerlessとIAM認証の設定方法
4. Flink アプリの実装（Kafka Source → Window集計 → S3 Parquet Sink）
5. Terraform モジュール設計のポイント
6. コスト実績（実際の請求額）
7. 今後の拡張案（マルチAZ・イベント時刻ベースウォーターマーク等）
```