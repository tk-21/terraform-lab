locals {
  prefix = "${var.project}-${var.env}"

  common_tags = {
    Project     = var.project
    Environment = var.env
    ManagedBy   = "terraform"
  }

  # Lambda Powertools レイヤー ARN (us-east-1 / Python 3.12 / arm64)
  # WAF CloudFront メトリクスは us-east-1 にしか存在しないため
  # alert パイプライン全体を us-east-1 に配置する
  powertools_layer_arn = "arn:aws:lambda:us-east-1:017000801446:layer:AWSLambdaPowertoolsPythonV3-python312-arm64:${var.powertools_layer_version}"
}

data "aws_caller_identity" "current" {}

# =============================================================================
# Lambda 関数パッケージ (alert_notifier)
# =============================================================================

data "archive_file" "alert_notifier" {
  type        = "zip"
  source_file = "${path.module}/../../../lambda/alert_notifier/main.py"
  output_path = "${path.module}/.build/alert_notifier.zip"
}

# =============================================================================
# IAM ロール: alert_notifier Lambda 実行ロール
# =============================================================================

resource "aws_iam_role" "alert_lambda" {
  # IAM ロール名上限 64 文字以内
  name = "${local.prefix}-alert-notifier-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

# CloudWatch Logs への書き込み
resource "aws_iam_role_policy_attachment" "alert_lambda_logs" {
  role       = aws_iam_role.alert_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# X-Ray トレーシング
resource "aws_iam_role_policy_attachment" "alert_lambda_xray" {
  role       = aws_iam_role.alert_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# SSM Parameter Store: Chatwork トークン取得のみ許可
# ワイルドカード禁止 - プロジェクト・環境に紐づいた特定パスのみ
resource "aws_iam_role_policy" "alert_lambda_ssm" {
  name = "${local.prefix}-alert-ssm-policy"
  role = aws_iam_role.alert_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["ssm:GetParameter"]
      Resource = [
        "arn:aws:ssm:ap-northeast-1:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/${var.env}/chatwork-token"
      ]
    }]
  })
}

# =============================================================================
# Lambda 関数: alert_notifier
# =============================================================================
# このモジュールは providers = { aws = aws.use1 } で呼び出す。
# CloudFront スコープの WAF メトリクスは us-east-1 にしか存在しないため
# CloudWatch Alarm・EventBridge・Lambda すべてを us-east-1 に統一する。

resource "aws_lambda_function" "alert_notifier" {
  function_name    = "${local.prefix}-alert-notifier"
  runtime          = "python3.12"
  architectures    = ["arm64"] # Graviton2: コスト最適化
  handler          = "main.handler"
  role             = aws_iam_role.alert_lambda.arn
  filename         = data.archive_file.alert_notifier.output_path
  source_code_hash = data.archive_file.alert_notifier.output_base64sha256
  timeout          = 30
  memory_size      = 128

  # Lambda Powertools をレイヤーで提供
  layers = [local.powertools_layer_arn]

  environment {
    variables = {
      CHATWORK_TOKEN_PARAM    = "/${var.project}/${var.env}/chatwork-token"
      CHATWORK_ROOM_ID        = var.chatwork_room_id
      POWERTOOLS_LOG_LEVEL    = "INFO"
      POWERTOOLS_SERVICE_NAME = "waf-alert-notifier"
    }
  }

  tracing_config {
    mode = "Active" # X-Ray トレーシング有効
  }

  tags = local.common_tags
}

# EventBridge が Lambda を起動する権限
resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.alert_notifier.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.waf_alarm.arn
}

# =============================================================================
# CloudWatch Metric Alarm: WAF ブロック数監視
# =============================================================================
# CloudFront スコープの WAF メトリクスは us-east-1 にのみ存在する。
# CloudWatch Alarm の state change は EventBridge のデフォルトバスへ
# 自動的にルーティングされるため alarm_actions は不要。

resource "aws_cloudwatch_metric_alarm" "waf_block_high" {
  alarm_name          = "${local.prefix}-waf-block-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "BlockedRequests"
  namespace           = "AWS/WAFV2"
  period              = 300 # 5 分
  statistic           = "Sum"
  threshold           = var.waf_block_threshold

  dimensions = {
    Rule   = "ALL"
    WebACL = var.webacl_name
    # CloudFront スコープの WAF メトリクスは Region = us-east-1 が必須
    Region = "us-east-1"
  }

  alarm_description  = "WAF が ${var.waf_block_threshold} リクエスト以上を 5 分間でブロックした場合に Chatwork へ通知"
  treat_missing_data = "notBreaching"

  tags = local.common_tags
}

# =============================================================================
# EventBridge: WAF ブロック数アラーム → Lambda 起動
# =============================================================================
# CloudWatch Alarm の state change イベントはデフォルトバスへ自動配信される。
# alarm_actions に EventBridge rule ARN を指定する必要はない。

resource "aws_cloudwatch_event_rule" "waf_alarm" {
  name        = "${local.prefix}-waf-alarm-trigger"
  description = "WAF ブロック数アラームが ALARM 状態に遷移した際に alert_notifier Lambda を起動"

  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = ["${local.prefix}-waf-block-high"]
      state     = { value = ["ALARM"] }
    }
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "lambda" {
  rule = aws_cloudwatch_event_rule.waf_alarm.name
  arn  = aws_lambda_function.alert_notifier.arn
}
