# =============================================================================
# Lambdaモジュール - Orchestrator Lambda + DynamoDB（冪等性）
# FIS実験完了イベントを受け取りStep Functionsを起動するOrchestrator Lambdaと、
# 重複処理防止のためのDynamoDBテーブルを定義する。
# Lambda runtimeはPython 3.12 arm64に統一する（CLAUDE.md設計方針）。
# =============================================================================

# ------------------------------------------------------------
# Lambda関数パッケージ生成
# main.pyのみを含むzipを生成する。
# aws-lambda-powertoolsはAWS提供の公式Lambdaレイヤーを使用する。
# ------------------------------------------------------------
data "archive_file" "fis_event_handler" {
  type        = "zip"
  source_file = "${path.module}/../../../lambda/fis-event-handler/main.py"
  output_path = "${path.module}/fis-event-handler.zip"
}

# ------------------------------------------------------------
# CloudWatch Logs ロググループ
# Lambda関数のログ保持期間を明示的に設定する（デフォルトは無期限）。
# ------------------------------------------------------------
resource "aws_cloudwatch_log_group" "fis_event_handler" {
  name              = "/aws/lambda/${var.project}-fis-event-handler-${var.environment}"
  retention_in_days = 30

  tags = var.tags
}

# ------------------------------------------------------------
# Orchestrator Lambda 実行IAMロール
# 最小権限の原則に従い、必要なリソースのみにアクセスを制限する。
# Lambda実行ロールへのiam:PutRolePolicyは付与しない（禁止パターン）。
# ------------------------------------------------------------
resource "aws_iam_role" "fis_event_handler" {
  name = "${var.project}-fis-event-handler-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "fis_event_handler" {
  name = "${var.project}-fis-event-handler-policy-${var.environment}"
  role = aws_iam_role.fis_event_handler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # CloudWatch Logs: 構造化ログの書き込み（Powertoolsが使用）
        Sid    = "CloudWatchLogsWrite"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.fis_event_handler.arn}:*"
      },
      {
        # DynamoDB: 冪等性チェック用テーブルのみにアクセスを制限
        Sid    = "DynamoDBIdempotency"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem"
        ]
        Resource = aws_dynamodb_table.experiments.arn
      },
      {
        # Step Functions: ポストモーテムワークフローの起動のみ許可
        # Phase 3でstep_functions_arnが設定された場合のみ有効なポリシー
        Sid    = "StepFunctionsStartExecution"
        Effect = "Allow"
        Action = ["states:StartExecution"]
        Resource = var.step_functions_arn != "" ? var.step_functions_arn : "arn:aws:states:*:${var.aws_account_id}:stateMachine:${var.project}-postmortem-workflow-${var.environment}"
      },
      {
        # X-Ray: 分散トレーシングのセグメント送信（Powertoolsが使用）
        Sid    = "XRayTracing"
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords"
        ]
        Resource = "*"
      }
    ]
  })
}

# ------------------------------------------------------------
# DynamoDBテーブル: 実験処理の冪等性保証
# FIS実験IDをパーティションキーとし、同一実験の重複処理を防ぐ。
# TTLで7日後に自動削除してコストを抑制する。
# ------------------------------------------------------------
resource "aws_dynamodb_table" "experiments" {
  name         = "${var.project}-experiments-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "experiment_id"

  attribute {
    name = "experiment_id"
    type = "S"
  }

  # TTLで7日後に自動削除（Lambda側でUnixタイムスタンプを設定）
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  # 誤削除・誤更新からの復旧を可能にするPoint-in-Time Recovery
  point_in_time_recovery {
    enabled = true
  }

  tags = var.tags
}

# ------------------------------------------------------------
# AWS Lambda Powertools レイヤー
# arm64 Python 3.12用の公式レイヤーを使用する。
# アカウント017000801446はAWS公式のPowertoolsレイヤー配布アカウント。
# ------------------------------------------------------------
locals {
  powertools_layer_arn = "arn:aws:lambda:${var.region}:017000801446:layer:AWSLambdaPowertoolsPythonV2-Arm64:79"
}

# ------------------------------------------------------------
# fis-event-handler Lambda関数
# EventBridgeからFISイベントを受信し、Step Functionsワークフローを起動する。
# Powertoolsで構造化ログとX-Rayトレーシングを有効化する。
# ------------------------------------------------------------
resource "aws_lambda_function" "fis_event_handler" {
  function_name = "${var.project}-fis-event-handler-${var.environment}"
  description   = "FIS実験完了イベントを受信してStep Functionsポストモーテムワークフローを起動するOrchestrator"
  role          = aws_iam_role.fis_event_handler.arn

  filename         = data.archive_file.fis_event_handler.output_path
  source_code_hash = data.archive_file.fis_event_handler.output_base64sha256

  runtime       = "python3.12"
  architectures = ["arm64"]
  handler       = "main.handler"
  timeout       = 30
  memory_size   = 256

  # Lambda Powertoolsレイヤーを使用（boto3はLambdaランタイムに含まれるため不要）
  layers = [local.powertools_layer_arn]

  # X-Rayトレーシングを有効化（Powertoolsのトレーサーが使用）
  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      DYNAMODB_TABLE_NAME = aws_dynamodb_table.experiments.name
      STEP_FUNCTIONS_ARN  = var.step_functions_arn
      # Powertools設定
      POWERTOOLS_SERVICE_NAME = "fis-event-handler"
      LOG_LEVEL               = "INFO"
    }
  }

  depends_on = [aws_cloudwatch_log_group.fis_event_handler]

  tags = var.tags
}

# ------------------------------------------------------------
# fis-event-handler 非同期呼び出し設定
# EventBridgeからの非同期呼び出し時のリトライを2回に制限する
# ------------------------------------------------------------
resource "aws_lambda_function_event_invoke_config" "fis_event_handler" {
  function_name          = aws_lambda_function.fis_event_handler.function_name
  maximum_retry_attempts = 2
}

# =============================================================================
# data-collector Lambda
# CloudWatch Logs/Metrics, CloudTrail, EKS Eventsを並列収集してStep Functionsへ返す。
# timeout=300はCloudTrail・K8s APIアクセスに時間がかかるため最大値を設定する。
# =============================================================================

data "archive_file" "data_collector" {
  type        = "zip"
  source_file = "${path.module}/../../../lambda/data-collector/main.py"
  output_path = "${path.module}/data-collector.zip"
}

resource "aws_cloudwatch_log_group" "data_collector" {
  name              = "/aws/lambda/${var.project}-data-collector-${var.environment}"
  retention_in_days = 30
  tags              = var.tags
}

resource "aws_iam_role" "data_collector" {
  name = "${var.project}-data-collector-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "data_collector" {
  name = "${var.project}-data-collector-policy-${var.environment}"
  role = aws_iam_role.data_collector.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogsWrite"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.data_collector.arn}:*"
      },
      {
        # EKSクラスターのPod/Nodeログをフィルタ収集する
        Sid    = "CloudWatchLogsRead"
        Effect = "Allow"
        Action = ["logs:FilterLogEvents", "logs:GetLogEvents", "logs:DescribeLogGroups", "logs:DescribeLogStreams"]
        Resource = "arn:aws:logs:${var.region}:${var.aws_account_id}:log-group:/aws/eks/*:*"
      },
      {
        # Container InsightsメトリクスをCPU/Memory収集する
        Sid    = "CloudWatchMetrics"
        Effect = "Allow"
        Action = ["cloudwatch:GetMetricStatistics", "cloudwatch:GetMetricData"]
        Resource = "*"
      },
      {
        # 実験期間中のEKS/EC2/FIS APIコール履歴を収集する
        Sid    = "CloudTrailRead"
        Effect = "Allow"
        Action = ["cloudtrail:LookupEvents"]
        Resource = "*"
      },
      {
        # K8s APIサーバーへのBearerトークン生成のためクラスター情報を取得する
        Sid    = "EKSDescribe"
        Effect = "Allow"
        Action = ["eks:DescribeCluster"]
        Resource = "arn:aws:eks:${var.region}:${var.aws_account_id}:cluster/${var.eks_cluster_name != "" ? var.eks_cluster_name : "*"}"
      },
      {
        Sid    = "XRayTracing"
        Effect = "Allow"
        Action = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_lambda_function" "data_collector" {
  function_name = "${var.project}-data-collector-${var.environment}"
  description   = "FIS実験関連データ（CWLogs/Metrics/CloudTrail/K8sEvents）を並列収集してbedrock-analyzerへ渡す"
  role          = aws_iam_role.data_collector.arn

  filename         = data.archive_file.data_collector.output_path
  source_code_hash = data.archive_file.data_collector.output_base64sha256

  runtime       = "python3.12"
  architectures = ["arm64"]
  handler       = "main.handler"
  timeout       = 300
  memory_size   = 512

  layers = [local.powertools_layer_arn]

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      CLUSTER_NAME            = var.eks_cluster_name
      EKS_CLUSTER_ENDPOINT    = var.eks_cluster_endpoint
      PROJECT_NAME            = var.project
      ENVIRONMENT             = var.environment
      AWS_ACCOUNT_ID          = var.aws_account_id
      POWERTOOLS_SERVICE_NAME = "data-collector"
      LOG_LEVEL               = "INFO"
    }
  }

  depends_on = [aws_cloudwatch_log_group.data_collector]

  tags = var.tags
}

resource "aws_lambda_function_event_invoke_config" "data_collector" {
  function_name          = aws_lambda_function.data_collector.function_name
  maximum_retry_attempts = 2
}

# =============================================================================
# bedrock-analyzer Lambda
# 収集データをBedrock Claude Sonnet 3.5に渡してポストモーテムを生成する。
# timeout=120はBedrock推論時間（max_tokens=4096）を考慮した値。
# =============================================================================

data "archive_file" "bedrock_analyzer" {
  type        = "zip"
  source_file = "${path.module}/../../../lambda/bedrock-analyzer/main.py"
  output_path = "${path.module}/bedrock-analyzer.zip"
}

resource "aws_cloudwatch_log_group" "bedrock_analyzer" {
  name              = "/aws/lambda/${var.project}-bedrock-analyzer-${var.environment}"
  retention_in_days = 30
  tags              = var.tags
}

resource "aws_iam_role" "bedrock_analyzer" {
  name = "${var.project}-bedrock-analyzer-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "bedrock_analyzer" {
  name = "${var.project}-bedrock-analyzer-policy-${var.environment}"
  role = aws_iam_role.bedrock_analyzer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogsWrite"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.bedrock_analyzer.arn}:*"
      },
      {
        # Claude Sonnet 3.5のみに限定してポストモーテム生成コストを制御する
        Sid    = "BedrockInvokeModel"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel"]
        Resource = "arn:aws:bedrock:${var.region}::foundation-model/anthropic.claude-3-5-sonnet-20241022-v2:0"
      },
      {
        Sid    = "XRayTracing"
        Effect = "Allow"
        Action = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_lambda_function" "bedrock_analyzer" {
  function_name = "${var.project}-bedrock-analyzer-${var.environment}"
  description   = "収集データをBedrock Claude Sonnet 3.5に渡してポストモーテムを生成し6項目バリデーション"
  role          = aws_iam_role.bedrock_analyzer.arn

  filename         = data.archive_file.bedrock_analyzer.output_path
  source_code_hash = data.archive_file.bedrock_analyzer.output_base64sha256

  runtime       = "python3.12"
  architectures = ["arm64"]
  handler       = "main.handler"
  timeout       = 120
  memory_size   = 512

  layers = [local.powertools_layer_arn]

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      BEDROCK_MODEL_ID        = "anthropic.claude-3-5-sonnet-20241022-v2:0"
      PROJECT_NAME            = var.project
      ENVIRONMENT             = var.environment
      AWS_ACCOUNT_ID          = var.aws_account_id
      POWERTOOLS_SERVICE_NAME = "bedrock-analyzer"
      LOG_LEVEL               = "INFO"
    }
  }

  depends_on = [aws_cloudwatch_log_group.bedrock_analyzer]

  tags = var.tags
}

resource "aws_lambda_function_event_invoke_config" "bedrock_analyzer" {
  function_name          = aws_lambda_function.bedrock_analyzer.function_name
  maximum_retry_attempts = 2
}

# =============================================================================
# report-formatter Lambda
# ポストモーテムJSONをHTMLレポートに変換してS3に保存しpresigned URLを生成する。
# =============================================================================

data "archive_file" "report_formatter" {
  type        = "zip"
  source_file = "${path.module}/../../../lambda/report-formatter/main.py"
  output_path = "${path.module}/report-formatter.zip"
}

resource "aws_cloudwatch_log_group" "report_formatter" {
  name              = "/aws/lambda/${var.project}-report-formatter-${var.environment}"
  retention_in_days = 30
  tags              = var.tags
}

resource "aws_iam_role" "report_formatter" {
  name = "${var.project}-report-formatter-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "report_formatter" {
  name = "${var.project}-report-formatter-policy-${var.environment}"
  role = aws_iam_role.report_formatter.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogsWrite"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.report_formatter.arn}:*"
      },
      {
        # reportsバケットのみにアクセスを制限（他バケットへのアクセス禁止）
        Sid    = "S3ReportsAccess"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject"]
        Resource = var.s3_bucket_arn != "" ? "${var.s3_bucket_arn}/*" : "arn:aws:s3:::${var.project}-reports-${var.aws_account_id}-${var.environment}/*"
      },
      {
        Sid    = "XRayTracing"
        Effect = "Allow"
        Action = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_lambda_function" "report_formatter" {
  function_name = "${var.project}-report-formatter-${var.environment}"
  description   = "ポストモーテムJSONをHTMLレポートに変換してS3保存・presigned URL生成"
  role          = aws_iam_role.report_formatter.arn

  filename         = data.archive_file.report_formatter.output_path
  source_code_hash = data.archive_file.report_formatter.output_base64sha256

  runtime       = "python3.12"
  architectures = ["arm64"]
  handler       = "main.handler"
  timeout       = 60
  memory_size   = 512

  layers = [local.powertools_layer_arn]

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      S3_BUCKET_NAME          = var.s3_bucket_name
      PROJECT_NAME            = var.project
      ENVIRONMENT             = var.environment
      AWS_ACCOUNT_ID          = var.aws_account_id
      POWERTOOLS_SERVICE_NAME = "report-formatter"
      LOG_LEVEL               = "INFO"
    }
  }

  depends_on = [aws_cloudwatch_log_group.report_formatter]

  tags = var.tags
}

resource "aws_lambda_function_event_invoke_config" "report_formatter" {
  function_name          = aws_lambda_function.report_formatter.function_name
  maximum_retry_attempts = 2
}

# =============================================================================
# Secrets Manager: Chatwork APIキー管理
# api_key と room_id を1シークレットで管理する。
# 実際の値はterraform apply後にコンソールから手動設定する。
# 7日間の削除保護を設定して誤削除を防止する。
# =============================================================================

resource "aws_secretsmanager_secret" "chatwork_api_key" {
  name                    = "${var.project}/chatwork-api-key-${var.environment}"
  description             = "Chatwork APIキーとルームID。キー: api_key, room_id"
  recovery_window_in_days = 7

  tags = var.tags
}

# =============================================================================
# notifier Lambda
# ポストモーテムレポートのpresigned URLをChatwork APIで通知する。
# APIキーはSecrets Managerから取得する（ハードコード禁止）。
# =============================================================================

data "archive_file" "notifier" {
  type        = "zip"
  source_file = "${path.module}/../../../lambda/notifier/main.py"
  output_path = "${path.module}/notifier.zip"
}

resource "aws_cloudwatch_log_group" "notifier" {
  name              = "/aws/lambda/${var.project}-notifier-${var.environment}"
  retention_in_days = 30
  tags              = var.tags
}

resource "aws_iam_role" "notifier" {
  name = "${var.project}-notifier-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "notifier" {
  name = "${var.project}-notifier-policy-${var.environment}"
  role = aws_iam_role.notifier.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogsWrite"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.notifier.arn}:*"
      },
      {
        # Chatwork APIキーのみSecrets Managerから取得（他シークレットへのアクセス禁止）
        Sid    = "SecretsManagerGetChatworkKey"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.chatwork_api_key.arn
      },
      {
        Sid    = "XRayTracing"
        Effect = "Allow"
        Action = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_lambda_function" "notifier" {
  function_name = "${var.project}-notifier-${var.environment}"
  description   = "ポストモーテムレポートのpresigned URLをChatwork APIで通知する"
  role          = aws_iam_role.notifier.arn

  filename         = data.archive_file.notifier.output_path
  source_code_hash = data.archive_file.notifier.output_base64sha256

  runtime       = "python3.12"
  architectures = ["arm64"]
  handler       = "main.handler"
  timeout       = 30
  memory_size   = 256

  layers = [local.powertools_layer_arn]

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      # room_idはapi_keyと同じシークレットに格納（Secrets Manager経由で取得）
      PROJECT_NAME            = var.project
      ENVIRONMENT             = var.environment
      AWS_ACCOUNT_ID          = var.aws_account_id
      POWERTOOLS_SERVICE_NAME = "notifier"
      LOG_LEVEL               = "INFO"
    }
  }

  depends_on = [aws_cloudwatch_log_group.notifier]

  tags = var.tags
}

resource "aws_lambda_function_event_invoke_config" "notifier" {
  function_name          = aws_lambda_function.notifier.function_name
  maximum_retry_attempts = 2
}
