resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/kinesisfirehose/${var.name_prefix}-delivery-stream"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_stream" "this" {
  name           = "S3Delivery"
  log_group_name = aws_cloudwatch_log_group.this.name
}

resource "aws_kinesis_firehose_delivery_stream" "this" {
  name        = "${var.name_prefix}-delivery-stream"
  destination = "extended_s3"

  depends_on = [aws_cloudwatch_log_group.this, aws_cloudwatch_log_stream.this]

  server_side_encryption {
    enabled  = true
    key_type = "AWS_OWNED_CMK"
  }

  extended_s3_configuration {
    role_arn            = var.firehose_role_arn
    bucket_arn          = var.raw_bucket_arn
    prefix              = "logs/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/"
    error_output_prefix = "errors/year=!{timestamp:yyyy}/month=!{timestamp:MM}/!{firehose:error-output-type}/"
    buffering_size      = 5
    buffering_interval  = 60
    compression_format  = "UNCOMPRESSED"

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = "/aws/kinesisfirehose/${var.name_prefix}-delivery-stream"
      log_stream_name = "S3Delivery"
    }
  }
}
