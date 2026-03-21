locals {
  name_prefix = "${var.project}-${var.environment}"
  # Glue Crawler が raw/events/ を走査して作成するテーブル名
  raw_table_name = "events"
}

# ---------------------------------------------------------------------------
# IAM Role for Glue (Crawler + ETL Job 共用)
# ---------------------------------------------------------------------------

resource "aws_iam_role" "glue" {
  name = "${local.name_prefix}-glue-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# AWSGlueServiceRole: Glue が必要とする最低限の権限（CloudWatch Logs, Glue Catalog 操作など）
resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# S3 アクセス権限（raw 読み取り、processed 書き込み、scripts 読み取り）
resource "aws_iam_role_policy" "glue_s3" {
  name = "s3-access"
  role = aws_iam_role.glue.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # raw zone: Crawler + ETL Job が読み取る
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          var.raw_bucket_arn,
          "${var.raw_bucket_arn}/*"
        ]
      },
      # processed zone: ETL Job が書き込む
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:AbortMultipartUpload"
        ]
        Resource = [
          var.processed_bucket_arn,
          "${var.processed_bucket_arn}/*"
        ]
      },
      # scripts zone: ETL Job がスクリプトを読む
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          var.scripts_bucket_arn,
          "${var.scripts_bucket_arn}/*"
        ]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Glue Catalog Database
# ---------------------------------------------------------------------------

resource "aws_glue_catalog_database" "this" {
  name        = replace("${local.name_prefix}-db", "-", "_")
  description = "Data lake catalog for ${var.project} ${var.environment}"
}

# ---------------------------------------------------------------------------
# Glue Crawler: raw/ を走査してスキーマを Catalog に登録
# ---------------------------------------------------------------------------

resource "aws_glue_crawler" "raw" {
  name          = "${local.name_prefix}-raw-crawler"
  role          = aws_iam_role.glue.arn
  database_name = aws_glue_catalog_database.this.name
  description   = "Crawls raw zone NDJSON to discover schema and partitions"

  s3_target {
    path = "s3://${var.raw_bucket_id}/events/"
  }

  # スキーマ変更時の挙動: 新しいカラム追加は許可、削除は保持
  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }

  # 再クロール: 変更があった S3 オブジェクトのみ処理（差分クロール）
  recrawl_policy {
    recrawl_behavior = "CRAWL_EVERYTHING"
  }

  configuration = jsonencode({
    Version = 1.0
    CrawlerOutput = {
      Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
    }
  })
}

# ---------------------------------------------------------------------------
# ETL スクリプトを S3 にアップロード
# ---------------------------------------------------------------------------

resource "aws_s3_object" "etl_script" {
  bucket = var.scripts_bucket_id
  key    = "glue/etl_raw_to_processed.py"
  source = "${path.module}/scripts/etl_raw_to_processed.py"
  etag   = filemd5("${path.module}/scripts/etl_raw_to_processed.py")
}

# ---------------------------------------------------------------------------
# Glue ETL Job: JSON → Parquet 変換
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "glue_job" {
  name              = "/aws/glue/jobs/${local.name_prefix}-etl"
  retention_in_days = 30
}

resource "aws_glue_job" "etl" {
  name         = "${local.name_prefix}-etl-raw-to-processed"
  role_arn     = aws_iam_role.glue.arn
  description  = "Convert raw NDJSON to Parquet in processed zone"
  glue_version = "4.0"

  command {
    name            = "glueetl"
    script_location = "s3://${var.scripts_bucket_id}/glue/etl_raw_to_processed.py"
    python_version  = "3"
  }

  # ワーカー設定: G.1X × 2 が最小構成（1 DPU = 4 vCPU、16 GB RAM）
  worker_type       = "G.1X"
  number_of_workers = 2
  timeout           = 60 # 分

  default_arguments = {
    "--job-language"                     = "python"
    "--enable-metrics"                   = ""
    "--enable-continuous-cloudwatch-log" = "true"
    "--continuous-log-logGroup"          = aws_cloudwatch_log_group.glue_job.name
    "--enable-spark-ui"                  = "false" # コスト削減
    "--TempDir"                          = "s3://${var.scripts_bucket_id}/glue-temp/"
    "--source_bucket"                    = var.raw_bucket_id
    "--target_bucket"                    = var.processed_bucket_id
    "--database_name"                    = aws_glue_catalog_database.this.name
    "--table_name"                       = local.raw_table_name
  }

  execution_property {
    max_concurrent_runs = 1
  }
}
