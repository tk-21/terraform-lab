# Kinesis Data Streams + Lambda ESM モジュール
# シャード数・リテンション期間・バッチサイズを変数化する。
#
# アーキテクチャ:
#   Kinesis Data Streams
#     ↓ ESM（Lambda イベントソースマッピング）
#   transformer Lambda（sep-<env>-transformer）
#     ↓ BatchWriteItem
#   DynamoDB（sep-<env>-events）
#     ↓ 失敗時
#   SQS DLQ（sep-<env>-transform-dlq）

# ── ローカル変数 ──────────────────────────────────────────────

locals {
  stream_name = "${var.project}-${var.environment}-events-stream"
  dlq_name    = "${var.project}-${var.environment}-transform-dlq"
  kms_alias   = "alias/${var.project}-${var.environment}-kinesis"
}

# ── 1. KMS カスタマーマネージドキー ──────────────────────────

# Kinesis ストリームの保存データ暗号化に使用するカスタム KMS キー。
# AWS マネージドキー（alias/aws/kinesis）ではなくカスタムキーを使用することで、
# キーポリシーの詳細制御・クロスアカウント共有・自動ローテーションが可能になる。
resource "aws_kms_key" "kinesis" {
  description             = "sep ${var.environment} Kinesis Data Streams 暗号化キー"
  deletion_window_in_days = 7

  # 自動ローテーション: 365 日ごとにキーマテリアルを自動更新する。
  # 既存の暗号化データは古いキーマテリアルで引き続き復号可能（キーローテーション履歴を保持）。
  enable_key_rotation = true

  tags = var.common_tags
}

resource "aws_kms_alias" "kinesis" {
  name          = local.kms_alias
  target_key_id = aws_kms_key.kinesis.key_id
}

# ── 2. Kinesis Data Streams ───────────────────────────────────

# イベントデータを受け取るメインストリーム。
#
# シャードの仕組み:
#   - 1 シャード = 1 MB/秒 の書き込み + 2 MB/秒 の読み取り（GetRecords）
#   - ESM は各シャードに対して独立したイテレータを保持する
#   - シャード内のレコードは順序保証される（シャード間は順序保証されない）
#   - dev は 1 シャードで十分。prod は負荷に応じて 2+ に増やす（CLAUDE.md コスト管理参照）
resource "aws_kinesis_stream" "events" {
  name             = local.stream_name
  shard_count      = var.shard_count
  retention_period = var.retention_hours

  # KMS カスタマーマネージドキーで保存データを暗号化する。
  # KINESIS_MANAGED を使用するとキーの制御ができないため KMS を選択する。
  encryption_type = "KMS"
  kms_key_id      = aws_kms_key.kinesis.id

  # ストリームモード: PROVISIONED（シャード数を明示的に管理）
  # ON_DEMAND は自動スケールするが、コスト予測が難しいため PROVISIONED を推奨。
  stream_mode_details {
    stream_mode = "PROVISIONED"
  }

  tags = var.common_tags
}

# ── 3. SQS DLQ（ESM 失敗送信先）─────────────────────────────

# Kinesis ESM の失敗送信先（on_failure destination）として使用する SQS キュー。
# Lambda が maximum_retry_attempts 回を超えてもエラーになったレコードは
# このキューに転送され、dlq-handler Lambda または手動で調査・再処理できる。
#
# SQS vs SNS vs EventBridge as destination:
#   SQS を選択: dlq-handler Lambda が直接ポーリングできる・メッセージを永続保持できる
#   SNS はサブスクライバがないとメッセージが消失するリスクがある
resource "aws_sqs_queue" "dlq" {
  name = local.dlq_name

  # 最大 14 日間メッセージを保持して障害調査の時間を確保する
  message_retention_seconds = 1209600 # 14日

  # SQS マネージド SSE: 追加コストなしで保存データを暗号化する。
  # Kinesis ESM からの失敗レコードも暗号化保存される。
  sqs_managed_sse_enabled = true

  tags = var.common_tags
}

# DLQ リソースポリシー: Kinesis ESM（Lambda サービス）が DLQ に SendMessage できるようにする。
# Lambda 実行ロールに sqs:SendMessage を付与するだけでは不十分な場合があるため、
# リソースポリシーでも明示的に許可する。
resource "aws_sqs_queue_policy" "dlq_lambda_esm" {
  queue_url = aws_sqs_queue.dlq.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowLambdaESMSendMessage"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.dlq.arn
        Condition = {
          # ESM から送信されるメッセージの送信元 Lambda ARN に限定する（混乱した代理攻撃対策）
          ArnLike = {
            "aws:SourceArn" = var.lambda_alias_arn
          }
        }
      }
    ]
  })
}

# ── 4. Lambda イベントソースマッピング（Kinesis → Lambda）────

# Kinesis シャードと Lambda エイリアスを接続する ESM。
# Lambda サービスが各シャードのイテレータを管理し、レコードが届いたら Lambda を起動する。
#
# イテレータの仕組み:
#   - LATEST: ESM 作成後に追加された新しいレコードのみを処理する（既存レコードは無視）
#   - TRIM_HORIZON: ストリームに保存されている全レコードから処理を開始する
#   - AT_TIMESTAMP: 指定した時刻以降のレコードから処理を開始する
#   dev 環境では LATEST を使用して過去データの再処理を避ける。
#
# bisect_batch_on_function_error:
#   Lambda が例外で終了した場合（ReportBatchItemFailures 以外）、
#   バッチを二分割して問題レコードを絞り込む。これにより毒メッセージによる
#   無限ループを防ぎながら、正常なレコードのチェックポイントを進められる。
resource "aws_lambda_event_source_mapping" "kinesis_to_lambda" {
  event_source_arn  = aws_kinesis_stream.events.arn
  function_name     = var.lambda_alias_arn
  starting_position = "LATEST"

  # バッチ設定: 最大 batch_size 件または maximum_batching_window 秒経過で Lambda を起動する
  batch_size                         = var.batch_size
  maximum_batching_window_in_seconds = var.maximum_batching_window_in_seconds

  # 失敗時の再試行: 最大 maximum_retry_attempts 回リトライ後に失敗送信先へ転送する
  maximum_retry_attempts = var.maximum_retry_attempts

  # バッチ分割: Lambda 全体のエラー時にバッチを半分に分割して再試行する
  bisect_batch_on_function_error = true

  # 失敗送信先: 全リトライ失敗後のレコードを SQS DLQ へ転送する
  # 転送されるメッセージには失敗理由・シャード ID・シーケンス番号が含まれる
  destination_config {
    on_failure {
      destination_arn = aws_sqs_queue.dlq.arn
    }
  }

  # DLQ ポリシーが適用されてから ESM を作成する
  depends_on = [aws_sqs_queue_policy.dlq_lambda_esm]
}

# ── 5. CloudWatch アラーム（イテレータエイジ）────────────────

# GetRecords.IteratorAgeMilliseconds: 最新のレコードが Kinesis に投入されてから
# Lambda に届くまでの経過時間。この値が大きい場合、Lambda の処理がストリームに
# 追いついていない（コンシューマーラグ）ことを示す。
#
# 原因の可能性:
#   - Lambda のタイムアウトやエラーによる再処理
#   - バッチサイズ・並列処理数の不足
#   - DynamoDB スロットリングによる Lambda 処理遅延
resource "aws_cloudwatch_metric_alarm" "iterator_age" {
  alarm_name        = "${local.stream_name}-iterator-age-alarm"
  alarm_description = "Kinesis イテレータエイジが ${var.iterator_age_threshold_ms}ms を超えました。transformer Lambda の処理遅延またはスロットリングが発生している可能性があります。runbook.md の「Kinesis 遅延対応」を参照してください。"

  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "GetRecords.IteratorAgeMilliseconds"
  namespace           = "AWS/Kinesis"

  # 60 秒ごとに評価する（Kinesis メトリクスの最小粒度は 1 分）
  period    = 60
  statistic = "Maximum"

  # Maximum を使用: 複数シャードのうち最も遅延しているシャードを検知する。
  # Average を使用すると遅延シャードが他のシャードに希釈されて検知漏れが発生する。
  threshold = var.iterator_age_threshold_ms

  dimensions = {
    StreamName = aws_kinesis_stream.events.name
  }

  # データがない場合（ストリームへの書き込みがない）はアラーム状態にしない
  treat_missing_data = "notBreaching"

  alarm_actions = var.alarm_action_arns
  ok_actions    = var.alarm_action_arns

  tags = var.common_tags
}

# ── 6. IAM ポリシー（transformer Lambda 最小権限）────────────

# CLAUDE.md 禁止事項: Lambda 実行ロールへの「*」リソース指定は禁止。
# 各権限を必要なリソース ARN に限定して付与する。
resource "aws_iam_policy" "transformer" {
  name        = "${var.project}-${var.environment}-transformer-policy"
  description = "sep-${var.environment}-transformer Lambda の最小権限ポリシー（Kinesis + DynamoDB + KMS + SQS）"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Kinesis レコード読み取り権限
        # GetRecords: レコードの取得
        # GetShardIterator: シャードイテレータの取得（どのレコードから読むかを指定するポインタ）
        # DescribeStream / DescribeStreamSummary: ESM がストリームのシャード構成を確認するために使用
        # ListShards: ESM がシャード一覧を取得してイテレータを管理するために使用
        # ListStreams: ESM の内部動作に必要
        Sid    = "KinesisReadRecords"
        Effect = "Allow"
        Action = [
          "kinesis:GetRecords",
          "kinesis:GetShardIterator",
          "kinesis:DescribeStream",
          "kinesis:DescribeStreamSummary",
          "kinesis:ListShards",
          "kinesis:ListStreams",
        ]
        Resource = aws_kinesis_stream.events.arn
      },
      {
        # DynamoDB BatchWriteItem: 変換後レコードの一括書き込みのみ許可
        # BatchWriteItem は PutItem / DeleteItem の複合操作だが、ここでは書き込みのみを意図する
        # 読み取り権限（GetItem / Query）は transformer には不要なため付与しない
        Sid      = "DynamoDBBatchWrite"
        Effect   = "Allow"
        Action   = ["dynamodb:BatchWriteItem"]
        Resource = var.dynamodb_table_arn
      },
      {
        # SQS DLQ への送信: ESM が失敗レコードを DLQ へ転送するために必要
        # Lambda 実行ロールに sqs:SendMessage を付与しないと、
        # ESM の destination_config の on_failure が機能しない
        Sid      = "SQSSendToDLQ"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.dlq.arn
      },
      {
        # KMS 復号化: Kinesis ストリームの暗号化レコードを Lambda が読み取るために必要
        # kms:GenerateDataKey は Lambda ESM が Kinesis ストリームに書き込む際に使用（不要かもしれないが安全のため付与）
        Sid    = "KMSDecryptKinesis"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
        ]
        Resource = aws_kms_key.kinesis.arn
      },
    ]
  })

  tags = var.common_tags
}

# transformer Lambda 実行ロールに IAM ポリシーをアタッチする。
resource "aws_iam_role_policy_attachment" "transformer" {
  role       = var.lambda_role_name
  policy_arn = aws_iam_policy.transformer.arn
}
