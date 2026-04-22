# Glue Data CatalogはAthenaのメタデータストアとして機能
# S3のParquetファイルを仮想テーブルとして定義することでSQLクエリが可能に
resource "aws_glue_catalog_database" "streaming" {
  name        = "${var.name_prefix}_streaming_db"
  description = "Streaming platform events database"
}

resource "aws_glue_catalog_table" "service_metrics" {
  name          = "service_metrics"
  database_name = aws_glue_catalog_database.streaming.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification        = "parquet"
    "parquet.compression" = "SNAPPY"
  }

  partition_keys {
    name = "year"
    type = "string"
  }
  partition_keys {
    name = "month"
    type = "string"
  }
  partition_keys {
    name = "day"
    type = "string"
  }
  partition_keys {
    name = "hour"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${var.output_bucket_name}/events/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    columns {
      name = "service_name"
      type = "string"
    }
    columns {
      name = "total_count"
      type = "bigint"
    }
    columns {
      name = "error_count"
      type = "bigint"
    }
    columns {
      name = "avg_latency_ms"
      type = "double"
    }
    columns {
      name = "window_start"
      type = "string"
    }
    columns {
      name = "window_end"
      type = "string"
    }
  }
}

# Athena engine v3はv2比でクエリ性能が向上しParquet読み込みが高速
resource "aws_athena_workgroup" "streaming" {
  name = "${var.name_prefix}-workgroup"

  configuration {
    result_configuration {
      output_location = "s3://${var.output_bucket_name}/athena-results/"
    }
    engine_version {
      selected_engine_version = "Athena engine version 3"
    }
  }

  tags = var.tags
}
