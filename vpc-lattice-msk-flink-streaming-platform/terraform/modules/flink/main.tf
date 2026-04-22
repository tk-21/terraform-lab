resource "aws_cloudwatch_log_group" "flink" {
  name              = "/aws/kinesis-analytics/${var.name_prefix}-flink-app"
  retention_in_days = 7
  tags              = var.tags
}

resource "aws_cloudwatch_log_stream" "flink" {
  name           = "flink-app-log-stream"
  log_group_name = aws_cloudwatch_log_group.flink.name
}

resource "aws_kinesisanalyticsv2_application" "main" {
  name                   = "${var.name_prefix}-flink-app"
  runtime_environment    = "FLINK-1_19"
  service_execution_role = var.flink_role_arn
  tags                   = var.tags

  application_configuration {
    application_code_configuration {
      code_content {
        s3_content_location {
          bucket_arn = var.flink_app_bucket_arn
          file_key   = "flink-app/streaming-job-1.0.0.jar"
        }
      }
      code_content_type = "ZIPFILE"
    }

    flink_application_configuration {
      checkpoint_configuration {
        configuration_type            = "CUSTOM"
        checkpointing_enabled         = true
        checkpoint_interval           = 60000
        min_pause_between_checkpoints = 5000
      }
      monitoring_configuration {
        configuration_type = "CUSTOM"
        log_level          = "INFO"
        metrics_level      = "APPLICATION"
      }
      parallelism_configuration {
        configuration_type   = "CUSTOM"
        parallelism          = 1
        parallelism_per_kpu  = 1
        auto_scaling_enabled = false
      }
    }

    vpc_configuration {
      subnet_ids         = var.private_subnet_ids
      security_group_ids = [var.sg_flink_id]
    }

    environment_properties {
      property_group {
        property_group_id = "FlinkApplicationProperties"
        property_map = {
          BOOTSTRAP_SERVERS  = var.msk_bootstrap_brokers
          OUTPUT_S3_PATH     = "s3a://${var.output_bucket_name}/events/"
          CHECKPOINT_S3_PATH = "s3a://${var.flink_app_bucket_name}/checkpoints/"
          KAFKA_TOPIC        = "streaming-events"
        }
      }
    }
  }

  cloudwatch_logging_options {
    log_stream_arn = aws_cloudwatch_log_stream.flink.arn
  }

  depends_on = [aws_cloudwatch_log_stream.flink]
}
