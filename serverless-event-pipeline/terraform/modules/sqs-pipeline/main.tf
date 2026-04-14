# SQS + Lambda ESM モジュール（DLQ 付き）
#
# S3 PUT → SQS キュー → Lambda ESM の構成を一括管理する。
# SQS の可視性タイムアウトは Lambda タイムアウトの6倍に設定する。
# Lambda がタイムアウトした場合にメッセージが再処理対象になるまでの猶予時間。
# 参照: https://docs.aws.amazon.com/lambda/latest/dg/with-sqs.html

# ── ローカル変数 ──────────────────────────────────────────────

locals {
  queue_name  = "${var.project}-${var.environment}-${var.pipeline_name}-queue"
  dlq_name    = "${var.project}-${var.environment}-${var.pipeline_name}-dlq"
  bucket_name = "${var.project}-${var.environment}-raw-input-${var.account_id}"

  # SQS 可視性タイムアウト = Lambda タイムアウト × 6
  # Lambda がメッセージ処理中に再度キューから取得されるのを防ぐ。
  visibility_timeout_seconds = var.lambda_timeout * 6

  # KMS 設定: カスタムキー指定の有無で SSE 方式を切り替える
  use_customer_kms = var.kms_key_arn != ""
}

# ── SQS DLQ ──────────────────────────────────────────────────

# デッドレターキュー: 処理失敗メッセージの最終保管場所。
# dlq_max_receive_count 回を超えたメッセージはここへ転送される。
# DLQ のメッセージは dlq-handler Lambda または手動で調査・再処理する。
resource "aws_sqs_queue" "dlq" {
  name = local.dlq_name

  # DLQ はメッセージを長期保持して調査できるようにする（最大 14 日）
  message_retention_seconds = 1209600 # 14日

  # SSE 設定: カスタム KMS 未指定の場合は SQS マネージド SSE（追加費用なし）を使用する
  sqs_managed_sse_enabled = local.use_customer_kms ? null : true
  kms_master_key_id       = local.use_customer_kms ? var.kms_key_arn : null

  tags = var.common_tags
}

# ── SQS メインキュー ──────────────────────────────────────────

# S3 PUT イベントを受信してバッファリングし、Lambda が処理するまでメッセージを保持する。
# 可視性タイムアウトを Lambda タイムアウトの 6 倍に設定することで、
# Lambda がタイムアウトした場合もメッセージが他のワーカーに再割り当てされるまでの
# 十分な猶予時間を確保する。
resource "aws_sqs_queue" "main" {
  name = local.queue_name

  # 可視性タイムアウト: Lambda タイムアウト × 6（AWS 推奨値）
  visibility_timeout_seconds = local.visibility_timeout_seconds
  message_retention_seconds  = var.message_retention_seconds

  # DLQ へのリドライブポリシー:
  # maxReceiveCount 回を超えて処理失敗したメッセージを DLQ へ転送する。
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.dlq_max_receive_count
  })

  sqs_managed_sse_enabled = local.use_customer_kms ? null : true
  kms_master_key_id       = local.use_customer_kms ? var.kms_key_arn : null

  tags = var.common_tags
}

# ── SQS キューポリシー（S3 → SQS SendMessage 許可）───────────

# S3 イベント通知が SQS へメッセージを送信できるようにするリソースポリシー。
# aws:SourceArn 条件でバケットを限定し、混乱した代理（Confused Deputy）攻撃を防ぐ。
# aws:SourceAccount 条件でアカウントも限定して二重防御する。
#
# 注意: Lambda の SQS ポーリング権限は IAM ロールで付与するため、ここには含めない。
#       同一アカウント内の Lambda ESM は IAM ポリシーのみで権限制御できる。
resource "aws_sqs_queue_policy" "s3_to_sqs" {
  queue_url = aws_sqs_queue.main.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowS3SendMessage"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.main.arn
        Condition = {
          # S3 バケット ARN でメッセージ送信元を限定する（他バケットからの誤送信を防ぐ）
          ArnLike = {
            "aws:SourceArn" = aws_s3_bucket.raw_input.arn
          }
          # アカウント ID でさらに限定する（クロスアカウントの混乱した代理攻撃対策）
          StringEquals = {
            "aws:SourceAccount" = var.account_id
          }
        }
      }
    ]
  })
}

# ── S3 バケット（raw input）────────────────────────────────────

# Lambda の入力ファイル（JSON / CSV）を受け取る生データバケット。
# PUT イベントを SQS へ通知することで Lambda の非同期処理をトリガーする。
# バケット名に account_id を含めてグローバル一意性を確保する（CLAUDE.md 命名規則準拠）。
resource "aws_s3_bucket" "raw_input" {
  bucket = local.bucket_name

  # 誤削除防止: terraform destroy 時にオブジェクトが残っている場合はエラーにする
  # 本番環境では force_destroy = false（デフォルト）を維持すること
  force_destroy = var.environment != "prod"

  tags = var.common_tags
}

# バージョニング: オブジェクトの上書き・削除を追跡し、誤操作からの復旧を可能にする
resource "aws_s3_bucket_versioning" "raw_input" {
  bucket = aws_s3_bucket.raw_input.id

  versioning_configuration {
    status = "Enabled"
  }
}

# サーバーサイド暗号化: 保存データを KMS で暗号化する。
# bucket_key_enabled = true で KMS API 呼び出し回数を削減してコストを最適化する。
resource "aws_s3_bucket_server_side_encryption_configuration" "raw_input" {
  bucket = aws_s3_bucket.raw_input.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
      # カスタム KMS キー未指定の場合は AWS マネージドキー（alias/aws/s3）を使用する
      kms_master_key_id = local.use_customer_kms ? var.kms_key_arn : null
    }
    # Bucket Key: S3 オブジェクトごとの KMS 呼び出しを削減し最大 99% のコスト削減
    bucket_key_enabled = true
  }
}

# パブリックアクセスブロック: 生データバケットへの意図しない公開を防ぐ
resource "aws_s3_bucket_public_access_block" "raw_input" {
  bucket = aws_s3_bucket.raw_input.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── S3 イベント通知（PUT → SQS）─────────────────────────────

# S3 オブジェクト作成時に SQS へ通知を送信する。
# depends_on で SQS キューポリシーの適用を確実に待ってから通知を設定する。
# （ポリシー未設定の状態で通知を有効化すると S3 側でエラーになる）
#
# 注意: 1 つの S3 バケットに対して aws_s3_bucket_notification は 1 リソースのみ作成可能。
#       複数の通知先が必要な場合は同一リソース内の queue ブロックを追加すること。
resource "aws_s3_bucket_notification" "raw_input" {
  bucket = aws_s3_bucket.raw_input.id

  queue {
    queue_arn = aws_sqs_queue.main.arn

    # ObjectCreated: PUT・POST・COPY・CompleteMultipartUpload をまとめてキャッチする
    events = ["s3:ObjectCreated:*"]

    # フィルター未指定の場合は全オブジェクトが対象になる
    filter_prefix = var.notification_filter_prefix != "" ? var.notification_filter_prefix : null
    filter_suffix = var.notification_filter_suffix != "" ? var.notification_filter_suffix : null
  }

  depends_on = [
    # SQS キューポリシーが適用されてから S3 通知を設定する
    # これがないと S3 が SendMessage を試みた際にポリシー未設定でエラーになる
    aws_sqs_queue_policy.s3_to_sqs,
    # パブリックアクセスブロックが設定されてからバケット通知を設定する
    aws_s3_bucket_public_access_block.raw_input,
  ]
}

# ── CloudWatch アラーム（DLQ メッセージ数）───────────────────

# DLQ にメッセージが 1 件以上滞留した場合にアラームを発火する。
# CLAUDE.md エラーハンドリング戦略: DLQ メッセージ数 >= 1 で SNS → Email/Chatwork 通知。
resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  alarm_name          = "${local.dlq_name}-messages-alarm"
  alarm_description   = "DLQ (${local.dlq_name}) にメッセージが滞留しています。dlq-handler Lambda または手動での調査が必要です。"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"

  # 60 秒ごとに評価する（SQS メトリクスは最低 1 分粒度）
  period    = 60
  statistic = "Sum"
  threshold = 1

  dimensions = {
    QueueName = aws_sqs_queue.dlq.name
  }

  # treat_missing_data = "notBreaching": データがない場合（キュー空）はアラーム状態にしない
  treat_missing_data = "notBreaching"

  alarm_actions = var.alarm_action_arns
  ok_actions    = var.alarm_action_arns

  tags = var.common_tags
}

# ── Lambda イベントソースマッピング（SQS → Lambda）─────────────

# SQS キューと Lambda エイリアスを接続するイベントソースマッピング（ESM）。
# Lambda サービスが SQS をポーリングし、メッセージが届いたら Lambda を起動する。
#
# bisect_batch_on_function_error = true:
#   Lambda が例外を throw した場合（ReportBatchItemFailures 以外のエラー）に
#   バッチを半分に分割して再試行する。問題のあるメッセージを絞り込める。
#
# function_response_types = ["ReportBatchItemFailures"]:
#   Lambda が {"batchItemFailures": [...]} を返すことで失敗したメッセージのみ再試行する。
#   Powertools の BatchProcessor と組み合わせて使用する。
resource "aws_lambda_event_source_mapping" "sqs_to_lambda" {
  event_source_arn = aws_sqs_queue.main.arn

  # エイリアス ARN を指定することでカナリアデプロイ時のトラフィック制御が透過的に行える
  function_name = var.lambda_alias_arn

  batch_size = var.batch_size

  # バッチ内の一部失敗時は分割して再試行（問題メッセージの特定を容易にする）
  bisect_batch_on_function_error = true

  # Powertools BatchProcessor の部分失敗レスポンス形式に対応する
  function_response_types = ["ReportBatchItemFailures"]
}
