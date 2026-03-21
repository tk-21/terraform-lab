data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"
  region      = data.aws_region.current.name
  account_id  = data.aws_caller_identity.current.account_id
}

# ---------------------------------------------------------------------------
# Kinesis Data Streams
# ---------------------------------------------------------------------------

resource "aws_kinesis_stream" "events" {
  name             = "${local.name_prefix}-events"
  shard_count      = var.kinesis_shard_count
  retention_period = 24 # hours

  # Server-side encryption
  encryption_type = "KMS"
  kms_key_id      = "alias/aws/kinesis"

  stream_mode_details {
    stream_mode = "PROVISIONED"
  }
}

# ---------------------------------------------------------------------------
# Firehose Transformation Lambda
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "transform_lambda" {
  name              = "/aws/lambda/${local.name_prefix}-firehose-transform"
  retention_in_days = 30
}

resource "aws_iam_role" "transform_lambda" {
  name = "${local.name_prefix}-firehose-transform-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "transform_lambda_logs" {
  name = "cloudwatch-logs"
  role = aws_iam_role.transform_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      Resource = "${aws_cloudwatch_log_group.transform_lambda.arn}:*"
    }]
  })
}

data "archive_file" "transform" {
  type        = "zip"
  source_file = "${path.module}/src/transform.py"
  output_path = "${path.module}/transform.zip"
}

resource "aws_lambda_function" "transform" {
  function_name    = "${local.name_prefix}-firehose-transform"
  role             = aws_iam_role.transform_lambda.arn
  filename         = data.archive_file.transform.output_path
  source_code_hash = data.archive_file.transform.output_base64sha256
  handler          = "transform.lambda_handler"
  runtime          = "python3.12"
  timeout          = 60   # Firehose Lambda max: 3 min; use 60 for safety
  memory_size      = 128

  logging_config {
    log_group  = aws_cloudwatch_log_group.transform_lambda.name
    log_format = "Text"
  }
}

# ---------------------------------------------------------------------------
# Firehose IAM Role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "firehose" {
  name = "${local.name_prefix}-firehose-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "sts:ExternalId" = local.account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "firehose" {
  name = "firehose-permissions"
  role = aws_iam_role.firehose.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # KDS 読み取り
      {
        Effect = "Allow"
        Action = [
          "kinesis:GetRecords",
          "kinesis:GetShardIterator",
          "kinesis:DescribeStream",
          "kinesis:ListShards",
          "kinesis:SubscribeToShard"
        ]
        Resource = aws_kinesis_stream.events.arn
      },
      # KDS の KMS キー使用
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "arn:aws:kms:${local.region}:${local.account_id}:key/alias/aws/kinesis"
      },
      # S3 raw ゾーン書き込み
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:AbortMultipartUpload",
          "s3:GetBucketLocation"
        ]
        Resource = [
          var.raw_bucket_arn,
          "${var.raw_bucket_arn}/*"
        ]
      },
      # Lambda 変換 呼び出し
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction", "lambda:GetFunctionConfiguration"]
        Resource = aws_lambda_function.transform.arn
      },
      # CloudWatch Logs
      {
        Effect = "Allow"
        Action = [
          "logs:PutLogEvents",
          "logs:CreateLogGroup",
          "logs:CreateLogStream"
        ]
        Resource = "${aws_cloudwatch_log_group.firehose.arn}:*"
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Amazon Data Firehose  (KDS → 変換 Lambda → S3 raw 動的パーティショニング)
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "firehose" {
  name              = "/aws/kinesisfirehose/${local.name_prefix}-events"
  retention_in_days = 30
}

resource "aws_kinesis_firehose_delivery_stream" "events" {
  name        = "${local.name_prefix}-events"
  destination = "extended_s3"

  # ソース: Kinesis Data Streams
  kinesis_source_configuration {
    kinesis_stream_arn = aws_kinesis_stream.events.arn
    role_arn           = aws_iam_role.firehose.arn
  }

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose.arn
    bucket_arn = var.raw_bucket_arn

    # 動的パーティショニング: event_type を S3 パスに埋め込む
    # 例: events/event_type=page_view/year=2024/month=01/day=15/hour=10/
    prefix              = "events/event_type=!{partitionKeyFromQuery:event_type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/"
    error_output_prefix = "errors/!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"

    # バッファリング: 64 MB または 60 秒（先着優先）
    buffering_size     = var.firehose_buffer_size_mb
    buffering_interval = var.firehose_buffer_interval_seconds

    # Glue ETL で Parquet に変換するため、raw は非圧縮 JSON のまま
    compression_format = "UNCOMPRESSED"

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = "S3Delivery"
    }

    # 動的パーティショニング有効化
    dynamic_partitioning_configuration {
      enabled        = true
      retry_duration = 300 # 秒: パーティションキー解決失敗時のリトライ
    }

    processing_configuration {
      enabled = true

      # Step 1: Lambda 変換（ingested_at 付与・バリデーション）
      processors {
        type = "Lambda"
        parameters {
          parameter_name  = "LambdaArn"
          parameter_value = "${aws_lambda_function.transform.arn}:$LATEST"
        }
        parameters {
          parameter_name  = "BufferSizeInMBs"
          parameter_value = "1"
        }
        parameters {
          parameter_name  = "BufferIntervalInSeconds"
          parameter_value = "60"
        }
      }

      # Step 2: JQ で event_type を抽出してパーティションキーにする
      processors {
        type = "MetadataExtraction"
        parameters {
          parameter_name  = "JsonParsingEngine"
          parameter_value = "JQ-1.6"
        }
        parameters {
          parameter_name  = "MetadataExtractionQuery"
          parameter_value = "{event_type:.event_type}"
        }
      }

      # Step 3: 改行区切り（NDJSON として S3 に書き込む）
      processors {
        type = "AppendDelimiterToRecord"
      }
    }
  }

  depends_on = [aws_iam_role_policy.firehose]
}
