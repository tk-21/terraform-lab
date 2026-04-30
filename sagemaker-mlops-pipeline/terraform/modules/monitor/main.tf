# =====================
# Data Quality Monitor
# =====================
resource "aws_sagemaker_data_quality_job_definition" "main" {
  name     = "${local.prefix}-data-quality-monitor"
  role_arn = var.pipeline_role_arn

  data_quality_app_specification {
    # AWS提供のビルトインモニタリングコンテナ
    image_uri = "156387875391.dkr.ecr.ap-northeast-1.amazonaws.com/sagemaker-model-monitor-analyzer"
  }

  # ベースライン生成スクリプト実行後にURIを設定する。空の場合はベースラインなしで起動
  dynamic "data_quality_baseline_config" {
    for_each = var.data_quality_baseline_uri != "" ? [1] : []
    content {
      constraints_resource {
        s3_uri = "${var.data_quality_baseline_uri}/constraints.json"
      }
      statistics_resource {
        s3_uri = "${var.data_quality_baseline_uri}/statistics.json"
      }
    }
  }

  data_quality_job_input {
    endpoint_input {
      endpoint_name = var.endpoint_name
      local_path    = "/opt/ml/processing/input/endpoint"
      # 日本語コメント: 推論リクエストデータをキャプチャするためにEndpoint Data Captureが必要
      s3_input_mode             = "File"
      s3_data_distribution_type = "FullyReplicated"
    }
  }

  data_quality_job_output_config {
    monitoring_outputs {
      s3_output {
        local_path     = "/opt/ml/processing/output"
        s3_uri         = "s3://${var.artifacts_bucket_name}/monitor/data-quality/output"
        s3_upload_mode = "EndOfJob"
      }
    }
  }

  job_resources {
    cluster_config {
      instance_count    = 1
      instance_type     = "ml.m5.large"
      volume_size_in_gb = 20
    }
  }

  tags = local.common_tags
}

# Data Quality Monitorスケジュール（1時間ごと）
resource "aws_sagemaker_monitoring_schedule" "data_quality" {
  name = "${local.prefix}-data-quality-schedule"

  monitoring_schedule_config {
    monitoring_job_definition_name = aws_sagemaker_data_quality_job_definition.main.name
    monitoring_type                = "DataQuality"

    schedule_config {
      # 日本語コメント: 1時間ごとに実行。コスト最適化のため最小間隔を使用
      schedule_expression = "cron(0 * ? * * *)"
    }
  }

  tags = local.common_tags
}

# =====================
# Model Quality Monitor
# =====================
resource "aws_sagemaker_model_quality_job_definition" "main" {
  name     = "${local.prefix}-model-quality-monitor"
  role_arn = var.pipeline_role_arn

  model_quality_app_specification {
    image_uri    = "156387875391.dkr.ecr.ap-northeast-1.amazonaws.com/sagemaker-model-monitor-analyzer"
    problem_type = "BinaryClassification"
  }

  # ベースライン生成スクリプト実行後にURIを設定する
  dynamic "model_quality_baseline_config" {
    for_each = var.model_quality_baseline_uri != "" ? [1] : []
    content {
      constraints_resource {
        s3_uri = "${var.model_quality_baseline_uri}/constraints.json"
      }
    }
  }

  model_quality_job_input {
    endpoint_input {
      endpoint_name                   = var.endpoint_name
      local_path                      = "/opt/ml/processing/input/endpoint"
      inference_attribute             = "prediction"
      probability_attribute           = "probability"
      probability_threshold_attribute = 0.5
    }
    ground_truth_s3_input {
      # 日本語コメント: 実際の正解ラベルは別システムから定期的にS3に格納される前提
      s3_uri = "s3://${var.data_bucket_name}/ground-truth/"
    }
  }

  model_quality_job_output_config {
    monitoring_outputs {
      s3_output {
        local_path     = "/opt/ml/processing/output"
        s3_uri         = "s3://${var.artifacts_bucket_name}/monitor/model-quality/output"
        s3_upload_mode = "EndOfJob"
      }
    }
  }

  job_resources {
    cluster_config {
      instance_count    = 1
      instance_type     = "ml.m5.large"
      volume_size_in_gb = 20
    }
  }

  tags = local.common_tags
}

resource "aws_sagemaker_monitoring_schedule" "model_quality" {
  name = "${local.prefix}-model-quality-schedule"

  monitoring_schedule_config {
    monitoring_job_definition_name = aws_sagemaker_model_quality_job_definition.main.name
    monitoring_type                = "ModelQuality"

    schedule_config {
      schedule_expression = "cron(0 * ? * * *)"
    }
  }

  tags = local.common_tags
}

# =====================
# Endpoint Data Capture（推論データ収集）
# =====================
# 日本語コメント: Data Quality MonitorがEndpointへの入力データを収集するために必要
# endpoint_model_nameが指定された場合のみ作成する
resource "aws_sagemaker_endpoint_configuration" "with_data_capture" {
  count = var.endpoint_model_name != "" ? 1 : 0
  name  = "${local.prefix}-endpoint-config-with-capture"

  production_variants {
    variant_name           = "primary"
    model_name             = var.endpoint_model_name
    initial_instance_count = 1
    instance_type          = var.endpoint_instance_type
    initial_variant_weight = 1.0
  }

  data_capture_config {
    enable_capture              = true
    initial_sampling_percentage = 100 # 日本語コメント: テスト環境では全件キャプチャ。本番は10-20%推奨
    destination_s3_uri          = "s3://${var.artifacts_bucket_name}/monitor/data-capture"

    capture_options {
      capture_mode = "Input" # 推論リクエストをキャプチャ
    }
    capture_options {
      capture_mode = "Output" # 推論レスポンスをキャプチャ
    }

    capture_content_type_header {
      json_content_types = ["application/json"]
      csv_content_types  = ["text/csv"]
    }
  }

  tags = local.common_tags
}

# =====================
# drift_handler Lambda
# =====================
data "archive_file" "drift_handler" {
  type        = "zip"
  source_file = "${path.root}/../lambda/drift_handler/handler.py"
  output_path = "${path.module}/drift_handler.zip"
}

resource "aws_lambda_function" "drift_handler" {
  function_name = "${local.prefix}-drift-handler"
  role          = aws_iam_role.drift_handler.arn
  runtime       = "python3.12"
  handler       = "handler.handler"
  architectures = ["arm64"]
  timeout       = 60

  filename         = data.archive_file.drift_handler.output_path
  source_code_hash = data.archive_file.drift_handler.output_base64sha256

  layers = [
    "arn:aws:lambda:${local.region}:017000801446:layer:AWSLambdaPowertoolsPythonV2-Arm64:${var.powertools_layer_version}"
  ]

  environment {
    variables = {
      POWERTOOLS_SERVICE_NAME = "drift-handler"
      LOG_LEVEL               = "INFO"
    }
  }

  tags = local.common_tags
}

resource "aws_lambda_permission" "sns_drift_handler" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.drift_handler.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.monitor_alerts.arn
}
