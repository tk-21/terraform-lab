# ✅Phase 3: Glue DataBrew + Glue Data Catalog + Athena の構築

## このフェーズの概要（Phase 1〜2 の続き）

Phase 1〜2 で以下が存在する前提：
- S3 Raw バケットに Firehose 経由で NDJSON ログが蓄積されている
  パス例: `s3://gaf-raw-{account}/logs/year=2026/month=04/day=19/hour=10/`
- S3 Processed バケットが空の状態で存在している
- IAMロール（gaf-databrew-role）が作成済み

このフェーズで作成するもの：
- AWS Glue DataBrew Dataset（Raw S3を参照）
- AWS Glue DataBrew Recipe（ETL変換定義）
- AWS Glue DataBrew Project（Dataset + Recipe の紐付け）
- AWS Glue DataBrew Job（スケジュール実行 → Processed S3 に Parquet出力）
- AWS Glue Data Catalog（Database + Table 定義）
- Amazon Athena Workgroup

---

## タスク一覧

### 1. Glue DataBrew モジュール

`terraform/modules/databrew/main.tf` を作成する。

```
# ★ Glue DataBrew の Terraform リソース名は以下の通り（混同注意）:
#   aws_databrew_dataset
#   aws_databrew_recipe
#   aws_databrew_project
#   aws_databrew_job
#   aws_databrew_schedule

# [1] DataBrew Dataset（Raw S3を参照）
# resource: aws_databrew_dataset
# name: "${var.name_prefix}-raw-dataset"
# format: "JSON"
# format_options:
#   json:
#     multi_line: false
#     # 日本語コメント: multi_line=falseはNDJSON（改行区切りJSON）を示す
#     # Firehoseが出力するNDJSON形式に合わせる
# input:
#   s3_input_definition:
#     bucket: var.raw_bucket_name
#     key: "logs/"
#     # 日本語コメント: keyにプレフィックスを指定することで
#     # 全パーティション配下のファイルをDatasetとして扱う

# [2] DataBrew Recipe（ETL変換ルール定義）
# resource: aws_databrew_recipe
# name: "${var.name_prefix}-recipe"
#
# steps（以下の変換を順番に定義）:
#
# Step 1: status_code カラムを INTEGER 型に変換
#   action:
#     operation: "CAST"
#     parameters:
#       sourceColumn: "status_code"
#       dataType: "INTEGER"
#
# Step 2: latency_ms カラムを INTEGER 型に変換
#   action:
#     operation: "CAST"
#     parameters:
#       sourceColumn: "latency_ms"
#       dataType: "INTEGER"
#
# Step 3: NULL値を含む行を削除（request_id が null のレコードは不正データ）
#   action:
#     operation: "DELETE_ROWS_WITH_NULL_IN_COLUMN"
#     parameters:
#       sourceColumn: "request_id"
#
# Step 4: latency_category カラムを追加（条件分岐で値を設定）
#   action:
#     operation: "COLUMN_VALUE_IS_IN_RANGE"（条件付きカラム追加）
#   # ★ DataBrew の Terraform では CASE_WHEN 相当の操作を
#   # CREATE_COLUMN + CASE_WHEN_CONDITIONS で表現する
#   # 以下のロジック:
#   #   latency_ms < 100  → "fast"
#   #   latency_ms < 500  → "normal"
#   #   それ以外          → "slow"
#   # # 日本語コメント: DataBrewのノーコードETLをTerraformでコード化することで
#   # # GUI操作なしに同じ変換を再現可能にする（IaC化のメリット）
#   action:
#     operation: "CREATE_COLUMN"
#     parameters:
#       newColumnName: "latency_category"
#       columnDataType: "STRING"
#       expression: "if(:latency_ms < 100, 'fast', if(:latency_ms < 500, 'normal', 'slow'))"
#
# Step 5: is_error カラムを追加（status_code >= 400 なら true）
#   action:
#     operation: "CREATE_COLUMN"
#     parameters:
#       newColumnName: "is_error"
#       columnDataType: "BOOLEAN"
#       expression: "if(:status_code >= 400, true, false)"
#
# Step 6: processed_at カラムを追加（現在時刻）
#   action:
#     operation: "CREATE_COLUMN"
#     parameters:
#       newColumnName: "processed_at"
#       columnDataType: "DATETIME"
#       expression: "now()"
#       # 日本語コメント: DataBrewジョブ実行時刻をメタデータとして付与
#       # どのバッチで処理されたかの追跡に使用

# [3] DataBrew Project（Dataset + Recipe の紐付け）
# resource: aws_databrew_project
# name: "${var.name_prefix}-databrew-project"
# dataset_name: databrew_dataset.name
# recipe_name: databrew_recipe.name
# role_arn: var.databrew_role_arn
# sample:
#   size: 500
#   type: "FIRST_N"
#   # 日本語コメント: Projectのサンプルは開発・プレビュー用
#   # 実際の全件処理はJobが担当

# [4] DataBrew Job（バッチ変換実行）
# resource: aws_databrew_job
# name: "${var.name_prefix}-job"
# type: "RECIPE"
# dataset_name: databrew_dataset.name
# recipe:
#   name: databrew_recipe.name
# role_arn: var.databrew_role_arn
#
# output:
#   - location:
#       bucket: var.processed_bucket_name
#       key: "processed/"
#     format: "PARQUET"
#     format_options:
#       parquet:
#         row_count: 1000000  # 最大100万行/ファイル
#     compression: "SNAPPY"
#     overwrite: true
#     # 日本語コメント: SNAPPY圧縮はParquetの標準的な圧縮方式
#     # Gzipより展開が速くAthenaのクエリパフォーマンスが向上
#
# max_capacity: 5（DataBrew DPU数。コスト：$1/DPU時）
# max_retries: 1
# timeout: 2880（48時間。ハンズオン規模では数分で完了）
#
# log_subscription: "ENABLE"
# # 日本語コメント: ジョブログを有効化してCloudWatch Logsで実行詳細を確認可能に

# [5] DataBrew Schedule（1時間ごとに自動実行）
# resource: aws_databrew_schedule
# name: "${var.name_prefix}-schedule"
# cron_expression: "cron(0 * * * ? *)"  # 毎時0分
# job_names: [databrew_job.name]
# # 日本語コメント: Firehoseが1時間分のデータをS3に蓄積した後に処理するスケジュール
```

---

### 2. Glue Data Catalog + Athena モジュール

`terraform/modules/glue/main.tf` を作成する。

```
# [1] Glue Database
# resource: aws_glue_catalog_database
# name: "${var.name_prefix}_db"
# # 日本語コメント: Athenaはこのデータベースを参照してSQLクエリを実行する

# [2] Glue Table（Raw層：NDJSON）
# resource: aws_glue_catalog_table
# name: "raw_logs"
# database_name: glue_database.name
# table_type: "EXTERNAL_TABLE"
# parameters:
#   classification: "json"
#   typeOfData: "file"
# partition_keys:
#   - name: "year",  type: "string"
#   - name: "month", type: "string"
#   - name: "day",   type: "string"
#   - name: "hour",  type: "string"
# storage_descriptor:
#   location: "s3://${var.raw_bucket_name}/logs/"
#   input_format:  "org.apache.hadoop.mapred.TextInputFormat"
#   output_format: "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"
#   ser_de_info:
#     serialization_library: "org.openx.data.jsonserde.JsonSerDe"
#     parameters:
#       paths: "request_id,timestamp,source_ip,source_region,method,path,status_code,latency_ms,user_agent,accelerator_ip,edge_location"
#   columns:
#     - name: "request_id",     type: "string"
#     - name: "timestamp",      type: "string"
#     - name: "source_ip",      type: "string"
#     - name: "source_region",  type: "string"
#     - name: "method",         type: "string"
#     - name: "path",           type: "string"
#     - name: "status_code",    type: "int"
#     - name: "latency_ms",     type: "int"
#     - name: "user_agent",     type: "string"
#     - name: "accelerator_ip", type: "string"
#     - name: "edge_location",  type: "string"
# # 日本語コメント: Raw層のテーブルはパーティション付きでNDJSONを直接参照
# # MSCK REPAIR TABLE または Partition Projection でパーティション認識が必要

# [3] Glue Table（Processed層：Parquet）
# resource: aws_glue_catalog_table
# name: "processed_logs"
# database_name: glue_database.name
# table_type: "EXTERNAL_TABLE"
# parameters:
#   classification: "parquet"
#   "parquet.compression": "SNAPPY"
# storage_descriptor:
#   location: "s3://${var.processed_bucket_name}/processed/"
#   input_format:  "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
#   output_format: "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"
#   ser_de_info:
#     serialization_library: "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
#   columns（raw_logs全カラム + DataBrew追加カラム）:
#     - 上記Raw logsの全カラム
#     - name: "latency_category", type: "string"
#     - name: "is_error",         type: "boolean"
#     - name: "processed_at",     type: "timestamp"
# # 日本語コメント: Parquet形式はカラムナーストレージのため
# # 特定カラムのみスキャンするAthenaクエリのコストを大幅削減

# [4] Athena Workgroup
# resource: aws_athena_workgroup
# name: "${var.name_prefix}-workgroup"
# configuration:
#   enforce_workgroup_configuration: true
#   result_configuration:
#     output_location: "s3://${var.athena_bucket_name}/results/"
#     encryption_configuration:
#       encryption_option: "SSE_S3"
#   engine_version:
#     selected_engine_version: "Athena engine version 3"
#   bytes_scanned_cutoff_per_query: 1073741824  # 1GB上限（コスト保護）
#   # 日本語コメント: クエリごとのスキャン上限を1GBに設定してコスト暴走を防止
#   # Athenaは$5/TB課金のため上限設定は本番環境でも推奨
# publish_cloudwatch_metrics_enabled: true
```

---

### 3. DataBrew の「ノーコードETL」をどう学ぶか（READMEへの追記指示）

README.md の「Architecture Decisions」セクションに以下を追記すること。

```markdown
## Glue DataBrew を採用した理由

### DataBrew の位置づけ
| ツール | 向いているユースケース |
|---|---|
| Glue ETL (PySpark) | 大規模データ・複雑な変換ロジック |
| **Glue DataBrew** | **スキーマ探索・プロファイリング・中規模クレンジング** |
| Lambda | 軽量リアルタイム変換 |

### DataBrew の差別化ポイント
- **Data Profile**: カラムごとの統計（null率・ユニーク数・分布）を自動生成
- **Recipe**: 変換ステップをGUIで定義 → TerraformでIaC化可能
- **240以上の変換**: 型変換・文字列操作・日付フォーマット等が組み込み済み

### Terraform で DataBrew をコード化する意味
GUIで作ったレシピをコードで再現することで：
1. 環境ごとの再現性（dev/stg/prodで同一変換を保証）
2. レシピ変更のコードレビュー（Gitで差分管理）
3. CI/CDパイプラインへの組み込み
```

---

### 4. サンプルAthenaクエリ（README.mdへの追記指示）

```sql
-- サービスパス別のエラー率を集計
SELECT
  path,
  COUNT(*) AS total_requests,
  SUM(CASE WHEN is_error THEN 1 ELSE 0 END) AS error_count,
  ROUND(100.0 * SUM(CASE WHEN is_error THEN 1 ELSE 0 END) / COUNT(*), 2) AS error_rate_pct,
  ROUND(AVG(latency_ms), 1) AS avg_latency_ms,
  MAX(latency_ms) AS max_latency_ms
FROM gaf_db.processed_logs
WHERE year = '2026' AND month = '04'
GROUP BY path
ORDER BY error_rate_pct DESC;

-- エッジロケーション別のトラフィック分布
SELECT
  edge_location,
  source_region,
  COUNT(*) AS request_count,
  ROUND(AVG(latency_ms), 1) AS avg_latency_ms
FROM gaf_db.processed_logs
GROUP BY edge_location, source_region
ORDER BY request_count DESC;

-- latency_category 別の割合
SELECT
  latency_category,
  COUNT(*) AS count,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS percentage
FROM gaf_db.processed_logs
GROUP BY latency_category;
```

---

## 完了条件

- [ ] DataBrew Dataset が S3 Raw バケットを正常に参照できる
- [ ] DataBrew Recipe に6ステップが定義されている
- [ ] DataBrew Job を手動実行（`bash scripts/run_databrew_job.sh`）して成功する
- [ ] S3 Processed バケットに Parquet ファイルが出力される
- [ ] Glue Data Catalog に `gaf_db.raw_logs` と `gaf_db.processed_logs` が登録される
- [ ] Athena Workgroup からサンプルクエリが実行でき結果が返る
- [ ] DataBrew Schedule が登録され翌時間に自動実行される予定になっている

---

## scripts/run_databrew_job.sh

```bash
#!/bin/bash
# DataBrewジョブを手動実行するスクリプト
# 使い方: bash scripts/run_databrew_job.sh
#
# 処理:
# 1. aws databrew start-job-run --name gaf-dev-job
# 2. Job Run IDを取得して表示
# 3. ポーリングで完了を待つ（30秒おきにステータス確認）
# 4. 完了したらS3 Processedバケットの出力ファイルを表示
#
# aws databrew describe-job-run --name gaf-dev-job --run-id $RUN_ID
```