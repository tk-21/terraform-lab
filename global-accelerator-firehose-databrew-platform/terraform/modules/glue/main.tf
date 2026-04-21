# [1] Glue Database
resource "aws_glue_catalog_database" "main" {
  name = "${replace(var.name_prefix, "-", "_")}_db"
}

# [2] Glue Table - Raw logs (NDJSON)
resource "aws_glue_catalog_table" "raw_logs" {
  name          = "raw_logs"
  database_name = aws_glue_catalog_database.main.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification = "json"
    typeOfData     = "file"
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
    location      = "s3://${var.raw_bucket_name}/logs/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
      parameters = {
        paths = "request_id,timestamp,source_ip,source_region,method,path,status_code,latency_ms,user_agent,accelerator_ip,edge_location"
      }
    }

    columns {
      name = "request_id"
      type = "string"
    }
    columns {
      name = "timestamp"
      type = "string"
    }
    columns {
      name = "source_ip"
      type = "string"
    }
    columns {
      name = "source_region"
      type = "string"
    }
    columns {
      name = "method"
      type = "string"
    }
    columns {
      name = "path"
      type = "string"
    }
    columns {
      name = "status_code"
      type = "int"
    }
    columns {
      name = "latency_ms"
      type = "int"
    }
    columns {
      name = "user_agent"
      type = "string"
    }
    columns {
      name = "accelerator_ip"
      type = "string"
    }
    columns {
      name = "edge_location"
      type = "string"
    }
  }
}

# [3] Glue Table - Processed logs (Parquet)
resource "aws_glue_catalog_table" "processed_logs" {
  name          = "processed_logs"
  database_name = aws_glue_catalog_database.main.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification        = "parquet"
    "parquet.compression" = "SNAPPY"
  }

  storage_descriptor {
    location      = "s3://${var.processed_bucket_name}/processed/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    columns {
      name = "request_id"
      type = "string"
    }
    columns {
      name = "timestamp"
      type = "string"
    }
    columns {
      name = "source_ip"
      type = "string"
    }
    columns {
      name = "source_region"
      type = "string"
    }
    columns {
      name = "method"
      type = "string"
    }
    columns {
      name = "path"
      type = "string"
    }
    columns {
      name = "status_code"
      type = "int"
    }
    columns {
      name = "latency_ms"
      type = "int"
    }
    columns {
      name = "user_agent"
      type = "string"
    }
    columns {
      name = "accelerator_ip"
      type = "string"
    }
    columns {
      name = "edge_location"
      type = "string"
    }
    columns {
      name = "latency_category"
      type = "string"
    }
    columns {
      name = "is_error"
      type = "boolean"
    }
    columns {
      name = "processed_at"
      type = "timestamp"
    }
  }
}

# [4] Athena Workgroup
resource "aws_athena_workgroup" "main" {
  name = "${var.name_prefix}-workgroup"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = 1073741824

    result_configuration {
      output_location = "s3://${var.athena_bucket_name}/results/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }

    engine_version {
      selected_engine_version = "Athena engine version 3"
    }
  }
}
