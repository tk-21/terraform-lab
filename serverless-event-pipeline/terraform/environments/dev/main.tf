# dev 環境のルートモジュール
# 各モジュールをここで組み合わせる。
#
# モジュール依存関係:
#   module.ingestor (lambda-function)
#       ↑ lambda_alias_arn を参照
#   module.sqs_pipeline_ingest (sqs-pipeline)
#       ↑ queue_arn・raw_input_bucket_arn を参照
#   aws_iam_policy.ingestor
#       ↑ role_name を参照
#   aws_iam_role_policy_attachment.ingestor
#
# 循環依存を避けるため module.ingestor は module.sqs_pipeline_ingest に依存しない。
# ingestor の環境変数で参照するバケット名は規則から直接計算する。

# ── データソース ──────────────────────────────────────────────

# Lambda Insights レイヤー ARN を SSM から直接取得する。
# observability モジュールも同じ SSM パスを参照するが、循環依存を防ぐために
# environments/dev/ でも独立したデータソースとして定義する:
#   module.observability → lambda_role_names（Lambda モジュールの出力）
#   Lambda モジュール    → layers（この data source の出力）
# この設計で依存方向が Lambda → observability の一方向になり、循環しない。
data "aws_ssm_parameter" "lambda_insights_layer_arn" {
  name = "/aws/service/lambda-insights/extension/arm64/latest"
}

# ── ローカル変数 ──────────────────────────────────────────────

locals {
  # Lambda デプロイアーティファクト用 S3 バケット
  # bootstrap.sh で事前作成される（sep-artifacts-<account_id>）。
  artifacts_bucket = "${var.project}-artifacts-${var.account_id}"

  # DynamoDB テーブル命名規則（dynamodb モジュールで作成予定）
  # モジュール参照を避け直接計算することで module.ingestor の依存関係を単純に保つ。
  events_table_name = "${var.project}-${var.environment}-events"
  events_table_arn  = "arn:aws:dynamodb:ap-northeast-1:${var.account_id}:table/${local.events_table_name}"

  # ingestor が参照する S3 バケット名: sqs-pipeline モジュールの命名規則と一致させる
  # module.sqs_pipeline_ingest.raw_input_bucket_name を参照すると循環依存になるため直接計算する
  raw_input_bucket_name = "${var.project}-${var.environment}-raw-input-${var.account_id}"
}

# ── アラート用 SNS トピック ──────────────────────────────────

# DLQ メッセージ数アラームの通知先。CloudWatch Alarm → SNS → Email の経路。
# observability モジュール実装後はそちらに移管する想定。
resource "aws_sns_topic" "alerts" {
  name = "${var.project}-${var.environment}-alerts"

  tags = local.common_tags
}

# メールアドレスへのサブスクリプション: 初回は確認メールが届き承認が必要
resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ── ingestor Lambda ──────────────────────────────────────────

# S3 PUT イベントを受信して DynamoDB へ書き込む Lambda 関数。
# lambda-function モジュールにより arm64 / X-Ray / Powertools / live エイリアスを標準装備する。
#
# source_dir を src/ にすることで shared/ モジュールも zip に含め、
# "from shared.models import ..." のインポートが Lambda 実行環境で解決できるようにする。
module "ingestor" {
  source = "../../modules/lambda-function"

  function_name = "${var.project}-${var.environment}-ingestor"

  # ハンドラパス: zip の root が src/ になるため ingestor サブパッケージを明示する
  handler = "ingestor.handler.lambda_handler"

  # src/ 全体を zip 化: shared/ モジュールを各 Lambda zip に含めるための設計。
  # Powertools・pydantic・boto3 は Lambda Layer またはランタイムで提供されるため
  # requirements.txt のインストールは不要。
  source_dir = abspath("${path.root}/../../../src")
  s3_bucket  = local.artifacts_bucket

  environment = var.environment
  project     = var.project

  timeout     = 30
  memory_size = 256

  # Lambda Insights レイヤー: Enhanced Monitoring メトリクス（メモリ・CPU・レイテンシ）を有効化する。
  # lambda-function モジュールの all_layers = concat([powertools_arn], var.layers) に追記される。
  layers = [data.aws_ssm_parameter.lambda_insights_layer_arn.value]

  environment_variables = {
    # DynamoDB テーブル名: ハードコードせず環境変数から取得する（CLAUDE.md 禁止事項準拠）
    EVENTS_TABLE_NAME = local.events_table_name

    # S3 バケット名: 循環依存を避けるため sqs-pipeline モジュール出力ではなく
    # 命名規則から直接計算した値を使用する
    RAW_INPUT_BUCKET = local.raw_input_bucket_name
  }

  common_tags = local.common_tags
}

# ── SQS パイプライン（S3 PUT → SQS → Lambda ESM）─────────────

# module.ingestor の alias_arn を渡すことで ESM をエイリアスに接続する。
# カナリアデプロイ時は live エイリアスの routing_config を変更するだけで
# ESM のトラフィック制御が透過的に行える。
module "sqs_pipeline_ingest" {
  source = "../../modules/sqs-pipeline"

  project       = var.project
  environment   = var.environment
  account_id    = var.account_id
  pipeline_name = "ingest"

  # ingestor Lambda の live エイリアス ARN を ESM のターゲットとして指定する
  lambda_alias_arn = module.ingestor.alias_arn
  lambda_timeout   = 30

  batch_size            = 10
  dlq_max_receive_count = 3

  # DLQ アラーム発火時に alerts SNS トピックへ通知する
  alarm_action_arns = [aws_sns_topic.alerts.arn]

  common_tags = local.common_tags
}

# ── transformer Lambda ───────────────────────────────────────

# Kinesis Data Streams からイベントを受け取り、変換後に DynamoDB へ書き込む Lambda 関数。
# kinesis-pipeline モジュールに lambda_alias_arn と lambda_role_name を渡すことで
# ESM 接続と IAM ポリシーアタッチが完結する。
module "transformer" {
  source = "../../modules/lambda-function"

  function_name = "${var.project}-${var.environment}-transformer"

  # ハンドラパス: zip の root が src/ になるため transformer サブパッケージを明示する
  handler = "transformer.handler.lambda_handler"

  # src/ 全体を zip 化: shared/ モジュールを各 Lambda zip に含めるための設計。
  source_dir = abspath("${path.root}/../../../src")
  s3_bucket  = local.artifacts_bucket

  environment = var.environment
  project     = var.project

  # Kinesis バッチサイズ 100 件を処理するために ingestor より長いタイムアウトを設定する
  timeout     = 60
  memory_size = 256

  layers = [data.aws_ssm_parameter.lambda_insights_layer_arn.value]

  environment_variables = {
    # DynamoDB テーブル名: ハードコードせず環境変数から取得する（CLAUDE.md 禁止事項準拠）
    EVENTS_TABLE_NAME = local.events_table_name
  }

  common_tags = local.common_tags
}

# ── Kinesis パイプライン（Kinesis Data Streams → Lambda ESM）──

# transformer Lambda の live エイリアス ARN を ESM のターゲットとして指定する。
# モジュール内で IAM ポリシー（Kinesis + DynamoDB + KMS 権限）も作成・アタッチされる。
module "kinesis_pipeline" {
  source = "../../modules/kinesis-pipeline"

  project     = var.project
  environment = var.environment

  # dev: 1 シャード・24 時間保持（CLAUDE.md コスト管理: 月額 $5 以下目標）
  shard_count     = 1
  retention_hours = 24

  lambda_alias_arn = module.transformer.alias_arn
  lambda_role_name = module.transformer.role_name

  # DynamoDB テーブル ARN: IAM ポリシーの BatchWriteItem リソース指定に使用する
  dynamodb_table_arn = local.events_table_arn

  # ESM バッチ設定
  batch_size                         = 100
  maximum_batching_window_in_seconds = 5
  maximum_retry_attempts             = 3

  # イテレータエイジアラーム: 60 秒を超えたら alerts SNS トピックへ通知する
  iterator_age_threshold_ms = 60000
  alarm_action_arns         = [aws_sns_topic.alerts.arn]

  common_tags = local.common_tags
}

# ── ingestor IAM ポリシー（最小権限）────────────────────────

# CLAUDE.md 禁止事項: Lambda 実行ロールへの「*」リソース指定は禁止。
# 各権限を必要なリソース ARN に限定して付与する。
#
# 循環依存の解消:
#   aws_iam_policy.ingestor は module.sqs_pipeline_ingest の outputs を参照する。
#   module.sqs_pipeline_ingest は module.ingestor.alias_arn を参照する。
#   module.ingestor はどちらにも依存しない。
#   → 依存関係が一方向になり循環しない。
resource "aws_iam_policy" "ingestor" {
  name        = "${var.project}-${var.environment}-ingestor-policy"
  description = "sep-${var.environment}-ingestor Lambda の最小権限ポリシー"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # S3 GetObject: raw-input バケットのオブジェクトのみ読み取り可能
        Sid      = "S3GetRawInput"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${module.sqs_pipeline_ingest.raw_input_bucket_arn}/*"
      },
      {
        # SQS ポーリング: Lambda ESM が SQS をポーリングするために必要な最小権限
        # GetQueueAttributes: バッチサイズ・可視性タイムアウトの検証に使用
        Sid    = "SQSConsumeIngestQueue"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
        ]
        Resource = module.sqs_pipeline_ingest.queue_arn
      },
      {
        # DynamoDB PutItem: events テーブルへの書き込みのみ許可
        # 読み取り（GetItem・Query）は不要なため付与しない
        Sid      = "DynamoDBPutEvents"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = local.events_table_arn
      },
      {
        # SSM GetParameter: Powertools レイヤー ARN など Lambda 設定パラメータの参照
        # パスを /${project}/${environment}/lambda/* に限定する
        Sid    = "SSMGetLambdaParameters"
        Effect = "Allow"
        Action = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:ap-northeast-1:${var.account_id}:parameter/${var.project}/${var.environment}/lambda/*"
      },
    ]
  })

  tags = local.common_tags
}

# ingestor Lambda 実行ロールに IAM ポリシーをアタッチする。
# lambda-function モジュールが作成したロール名を outputs.role_name から参照する。
resource "aws_iam_role_policy_attachment" "ingestor" {
  role       = module.ingestor.role_name
  policy_arn = aws_iam_policy.ingestor.arn
}

# ── DynamoDB テーブル ─────────────────────────────────────────────

# sep-dev-events（イベント書き込み先・Streams 有効）と
# sep-dev-aggregations（集計結果書き込み先）の2テーブルを作成する。
#
# dev 環境では PITR を無効化してコストを管理する。
# 本番では enable_pitr = true を指定すること（prod/main.tf 参照）。
module "dynamodb" {
  source = "../../modules/dynamodb"

  project     = var.project
  environment = var.environment
  enable_pitr = false

  common_tags = local.common_tags
}

# ── aggregator Lambda ────────────────────────────────────────────

# DynamoDB Streams（sep-dev-events）をトリガーに起動し、
# entity_id + 日付でグループ化した集計値を sep-dev-aggregations へ書き込む。
module "aggregator" {
  source = "../../modules/lambda-function"

  function_name = "${var.project}-${var.environment}-aggregator"

  # ハンドラパス: zip の root が src/ になるため aggregator サブパッケージを明示する
  handler = "aggregator.handler.lambda_handler"

  # src/ 全体を zip 化: shared/ モジュールを含めるための設計
  source_dir = abspath("${path.root}/../../../src")
  s3_bucket  = local.artifacts_bucket

  environment = var.environment
  project     = var.project

  # DynamoDB Streams のバッチ 50 件 × 集計処理を余裕を持って処理するタイムアウト
  timeout     = 60
  memory_size = 256

  layers = [data.aws_ssm_parameter.lambda_insights_layer_arn.value]

  environment_variables = {
    # 集計書き込み先テーブル名: ハードコードせず環境変数から取得する（CLAUDE.md 禁止事項準拠）
    AGGREGATIONS_TABLE_NAME = module.dynamodb.aggregations_table_name
  }

  common_tags = local.common_tags
}

# ── aggregator DynamoDB Streams イベントソースマッピング ────────────

# DynamoDB Streams は Kinesis と同様のポーリング型トリガー。
# Lambda ESM が Streams シャードをポーリングしてバッチとして Lambda に渡す。
#
# bisect_on_function_error = true の動作:
#   Lambda がエラーをスローした場合、ESM がバッチを二分して個別に再試行する。
#   毒矢レコード（poison pill）がバッチ全体を詰まらせることを防ぎ、
#   正常なレコードへの影響を最小化する。
#
# maximum_retry_attempts = 3:
#   全リトライ失敗後はバッチを破棄する。DynamoDB Streams は SQS DLQ と異なり
#   ESM の destination_config（SQS / SNS）に失敗レコードを転送できる。
#   本実装では監視でカバーし、設定をシンプルに保つ。
#
# filter_criteria で REMOVE を ESM レベルで排除する:
#   Lambda 側でもスキップするが、ESM フィルタリングで不要な Lambda 起動を削減する。
resource "aws_lambda_event_source_mapping" "aggregator_streams" {
  event_source_arn  = module.dynamodb.events_stream_arn
  function_name     = module.aggregator.alias_arn
  starting_position = "TRIM_HORIZON"

  # バッチサイズ: 最大 50 件をまとめて Lambda に渡す
  batch_size = 50

  # バッチウィンドウ: 最大 5 秒待機してバッチをまとめる。
  # ピーク時の Lambda 起動回数を削減しコストを最適化する。
  maximum_batching_window_in_seconds = 5

  # 毒矢レコード対策: バッチを二分して問題レコードを特定する
  bisect_on_function_error = true

  # 全リトライ失敗後にバッチを破棄する（-1 は無制限リトライ）
  maximum_retry_attempts = 3

  # ESM レベルで REMOVE イベントを除外し、不要な Lambda 起動を防ぐ。
  # Lambda 側でも REMOVE をスキップするが二重防護として設定する。
  filter_criteria {
    filter {
      pattern = jsonencode({
        eventName = ["INSERT", "MODIFY"]
      })
    }
  }

  # IAM ポリシーアタッチ後に ESM を作成する。
  # 権限が存在しない状態で ESM が起動すると Streams 読み取りエラーが発生するため。
  depends_on = [
    aws_iam_role_policy_attachment.aggregator,
  ]
}

# ── aggregator IAM ポリシー（最小権限）────────────────────────────

# CLAUDE.md 禁止事項: Lambda 実行ロールへの「*」リソース指定は禁止。
# DynamoDB Streams の読み取りは events テーブルの stream ARN のみに限定する。
# UpdateItem は aggregations テーブルのみに限定する。
resource "aws_iam_policy" "aggregator" {
  name        = "${var.project}-${var.environment}-aggregator-policy"
  description = "sep-${var.environment}-aggregator Lambda の最小権限ポリシー"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # DynamoDB Streams 読み取り: ESM が Streams をポーリングするために必要な権限。
        # DescribeStream: シャード情報の取得（ESM の初期化時に使用）
        # GetRecords: シャードからレコードを取得
        # GetShardIterator: シャードの読み取り開始位置を取得
        # ListStreams: ESM がストリームの存在を確認するために使用
        Sid    = "DynamoDBStreamsRead"
        Effect = "Allow"
        Action = [
          "dynamodb:DescribeStream",
          "dynamodb:GetRecords",
          "dynamodb:GetShardIterator",
          "dynamodb:ListStreams",
        ]
        Resource = module.dynamodb.events_stream_arn
      },
      {
        # aggregations テーブルへのアトミック加算。
        # UpdateItem のみを許可（PutItem・DeleteItem・GetItem は不要）。
        # ADD 式は項目が存在しない場合の upsert も UpdateItem で行うため
        # PutItem の権限は不要。
        Sid      = "DynamoDBUpdateAggregations"
        Effect   = "Allow"
        Action   = ["dynamodb:UpdateItem"]
        Resource = module.dynamodb.aggregations_table_arn
      },
      {
        # SSM GetParameter: Powertools レイヤー ARN など Lambda 設定パラメータの参照
        Sid    = "SSMGetLambdaParameters"
        Effect = "Allow"
        Action = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:ap-northeast-1:${var.account_id}:parameter/${var.project}/${var.environment}/lambda/*"
      },
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "aggregator" {
  role       = module.aggregator.role_name
  policy_arn = aws_iam_policy.aggregator.arn
}

# ── S3 dead-letter-archive バケット ────────────────────────────────

# 恒久エラー（PERMANENT）・分類不能（UNKNOWN）メッセージの永続保存先。
# gzip 圧縮 JSON を prefix: <category>/<date>/<message_id>.json.gz で格納する。
# 調査・監査目的のため長期保持し、コスト最適化のために段階的にストレージクラスを変更する。
resource "aws_s3_bucket" "dead_letter_archive" {
  bucket = "${var.project}-${var.environment}-dead-letter-archive-${var.account_id}"

  # dev 環境では terraform destroy 時にバケットを空にして削除できるようにする
  force_destroy = var.environment != "prod"

  tags = local.common_tags
}

# パブリックアクセスブロック: 失敗メッセージは機密情報を含む可能性があるため公開禁止
resource "aws_s3_bucket_public_access_block" "dead_letter_archive" {
  bucket = aws_s3_bucket.dead_letter_archive.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# サーバーサイド暗号化: 失敗メッセージのデータを保護する
resource "aws_s3_bucket_server_side_encryption_configuration" "dead_letter_archive" {
  bucket = aws_s3_bucket.dead_letter_archive.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# ライフサイクルルール: 長期保存コストの最適化
#   - 90 日後: GLACIER に移行（アクセス頻度が低い長期保存）
#   - 365 日後: 完全削除（監査保持期間終了）
#
# GLACIER 移行の根拠:
#   dlq-handler が S3 に保存した後、通常は手動調査時のみアクセスする。
#   90 日以内に調査する必要があるが、それ以降は法的・監査目的のみとなるため
#   コストの低い GLACIER への移行で月額コストを削減する。
resource "aws_s3_bucket_lifecycle_configuration" "dead_letter_archive" {
  bucket = aws_s3_bucket.dead_letter_archive.id

  rule {
    id     = "archive-to-glacier-and-expire"
    status = "Enabled"

    # 全プレフィックス（permanent/ と unknown/ の両方）に適用する
    filter {
      prefix = ""
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 365
    }
  }
}

# ── SNS トピック（sep-dev-pipeline-alerts）─────────────────────────

# dlq-handler からのアラート受信専用トピック。
# - UNKNOWN カテゴリ検出時の即時アラート
# - 処理完了サマリー通知
#
# 既存の sep-dev-alerts（CloudWatch Alarm 通知用）とは役割を分離し、
# dlq-handler による能動的な通知を独立して管理できるようにする。
resource "aws_sns_topic" "pipeline_alerts" {
  name = "${var.project}-${var.environment}-pipeline-alerts"

  tags = local.common_tags
}

# Email サブスクリプション: 初回 terraform apply 後に確認メールが届き承認が必要
resource "aws_sns_topic_subscription" "pipeline_alerts_email" {
  topic_arn = aws_sns_topic.pipeline_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ── dlq-handler Lambda ────────────────────────────────────────────

# DLQ に滞留した失敗メッセージを分類・再処理する Lambda。
# EventBridge Scheduler（5 分ごと）または CloudWatch Alarm 経由で起動する。
#
# タイムアウト設定の根拠:
#   最大 100 件 × DLQ 数のメッセージを処理する想定。
#   1 件あたり平均 0.5 秒として 100 件 × 0.5 秒 = 50 秒。
#   余裕を持って 60 秒に設定する。
module "dlq_handler" {
  source = "../../modules/lambda-function"

  function_name = "${var.project}-${var.environment}-dlq-handler"

  # ハンドラパス: zip の root が src/ になるため dlq_handler サブパッケージを明示する
  handler = "dlq_handler.handler.lambda_handler"

  # src/ 全体を zip 化: shared/ モジュールを含めるための設計
  source_dir = abspath("${path.root}/../../../src")
  s3_bucket  = local.artifacts_bucket

  environment = var.environment
  project     = var.project

  # DLQ 処理は SQS API 呼び出し・S3 書き込み・SNS 送信が含まれるため余裕を持たせる
  timeout     = 60
  memory_size = 256

  layers = [data.aws_ssm_parameter.lambda_insights_layer_arn.value]

  environment_variables = {
    # DLQ URL → 元のキュー URL のマッピング（JSON 文字列）
    # 現時点では sqs_pipeline_ingest のみだが、複数 DLQ に拡張しやすい形式にする
    DLQ_QUEUE_MAPPING = jsonencode({
      (module.sqs_pipeline_ingest.dlq_url) = module.sqs_pipeline_ingest.queue_url
    })

    # 恒久エラー・不明エラーのアーカイブ先 S3 バケット（ハードコード禁止）
    DEAD_LETTER_ARCHIVE_BUCKET = aws_s3_bucket.dead_letter_archive.bucket

    # UNKNOWN アラート・処理サマリーの送信先 SNS トピック ARN（ハードコード禁止）
    ALERTS_SNS_TOPIC_ARN = aws_sns_topic.pipeline_alerts.arn
  }

  common_tags = local.common_tags
}

# ── dlq-handler IAM ポリシー（最小権限）────────────────────────────

# CLAUDE.md 禁止事項: Lambda 実行ロールへの「*」リソース指定は禁止。
# 各権限を必要なリソース ARN に厳密に限定する。
#
# 必要な権限:
#   - SQS: DLQ の ReceiveMessage/DeleteMessage + 元キューへの SendMessage
#   - S3:  dead-letter-archive バケットへの PutObject のみ
#   - SNS: pipeline-alerts トピックへの Publish のみ
#   - CloudWatch: GetMetricStatistics（7 日間累計取得用）
resource "aws_iam_policy" "dlq_handler" {
  name        = "${var.project}-${var.environment}-dlq-handler-policy"
  description = "sep-${var.environment}-dlq-handler Lambda の最小権限ポリシー"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # SQS DLQ 読み取り・削除: 全 DLQ に対して ReceiveMessage と DeleteMessage を許可する。
        # GetQueueAttributes: メッセージ数などのキュー属性取得（CloudWatch アラーム連携）
        Sid    = "SQSDlqDrain"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
        ]
        # 現時点では ingest DLQ のみ。複数 DLQ が追加された場合はここに ARN を追加する。
        Resource = [
          module.sqs_pipeline_ingest.dlq_arn,
        ]
      },
      {
        # SQS 元キューへの再エンキュー: TRANSIENT エラーのメッセージを再処理させる。
        # SendMessage のみ許可（ReceiveMessage や DeleteMessage は不要）。
        Sid    = "SQSSourceQueueSend"
        Effect = "Allow"
        Action = ["sqs:SendMessage"]
        Resource = [
          module.sqs_pipeline_ingest.queue_arn,
        ]
      },
      {
        # S3 PutObject: dead-letter-archive バケットへの書き込みのみ許可する。
        # GetObject・DeleteObject・ListBucket などは不要（書き込み専用）。
        Sid      = "S3PutDeadLetterArchive"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.dead_letter_archive.arn}/*"
      },
      {
        # SNS Publish: pipeline-alerts トピックへの通知のみ許可する。
        # 他のトピックや Subscribe・Unsubscribe などは不要。
        Sid      = "SNSPublishPipelineAlerts"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.pipeline_alerts.arn
      },
      {
        # CloudWatch GetMetricStatistics: DLQ の 7 日間累計件数を取得する。
        # リソース指定不可の API のため "Resource": "*" が必須（AWS の制約）。
        # 読み取り専用の API であり書き込み権限は含まない。
        Sid      = "CloudWatchGetMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:GetMetricStatistics"]
        Resource = "*"
      },
      {
        # SSM GetParameter: Powertools レイヤー ARN 取得
        Sid    = "SSMGetLambdaParameters"
        Effect = "Allow"
        Action = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:ap-northeast-1:${var.account_id}:parameter/${var.project}/${var.environment}/lambda/*"
      },
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "dlq_handler" {
  role       = module.dlq_handler.role_name
  policy_arn = aws_iam_policy.dlq_handler.arn
}

# ── EventBridge Scheduler（5 分ごと定期実行）──────────────────────

# dlq-handler を 5 分ごとに起動して DLQ を定期的にドレインする。
# CloudWatch Alarm 起動の補完として機能し、アラームが発火しなかった場合でも
# メッセージが長期間滞留しないことを保証する。
#
# flexible_time_window = OFF の理由:
#   DLQ の再処理はなるべく予定時刻に近いタイミングで行いたいため、
#   フレキシブルウィンドウ（実行タイミングのランダム化）を無効にする。

# EventBridge Scheduler が Lambda を呼び出すための IAM ロール
resource "aws_iam_role" "scheduler_dlq_handler" {
  name = "${var.project}-${var.environment}-scheduler-dlq-handler-role"

  # EventBridge Scheduler サービスプリンシパルのみが AssumeRole できる
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "scheduler.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          # このアカウントの Scheduler のみに限定する（混乱した代理攻撃対策）
          StringEquals = {
            "aws:SourceAccount" = var.account_id
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

# Scheduler が dlq-handler の live エイリアスを呼び出す権限
resource "aws_iam_role_policy" "scheduler_dlq_handler_invoke" {
  name = "${var.project}-${var.environment}-scheduler-dlq-handler-invoke"
  role = aws_iam_role.scheduler_dlq_handler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = [
          module.dlq_handler.alias_arn,
          # エイリアスの関数 ARN も許可する（Scheduler は ARN を直接検証する場合がある）
          "${module.dlq_handler.function_arn}:live",
        ]
      }
    ]
  })
}

resource "aws_scheduler_schedule" "dlq_handler" {
  name        = "${var.project}-${var.environment}-dlq-handler-schedule"
  description = "DLQ を 5 分ごとに監視・ドレインする定期スケジュール"

  # フレキシブルウィンドウ無効: 予定時刻に正確に実行する
  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = "rate(5 minutes)"
  schedule_expression_timezone = "UTC"

  target {
    arn      = module.dlq_handler.alias_arn
    role_arn = aws_iam_role.scheduler_dlq_handler.arn

    # Scheduler が Lambda 呼び出し失敗時にリトライする設定
    retry_policy {
      maximum_event_age_in_seconds = 300  # 5 分以内に配信できなければ破棄
      maximum_retry_attempts       = 1    # 1 回リトライ（次の定期実行で再処理されるため多くは不要）
    }
  }

  # IAM ポリシーアタッチ後にスケジュールを作成する
  depends_on = [aws_iam_role_policy.scheduler_dlq_handler_invoke]
}

# Lambda リソースポリシー: EventBridge Scheduler からの呼び出しを許可する
resource "aws_lambda_permission" "dlq_handler_scheduler" {
  statement_id  = "AllowEventBridgeSchedulerInvoke"
  action        = "lambda:InvokeFunction"
  function_name = module.dlq_handler.function_name
  qualifier     = "live"  # live エイリアスを対象とする
  principal     = "scheduler.amazonaws.com"
  source_arn    = aws_scheduler_schedule.dlq_handler.arn
}

# ── EventBridge ルール（CloudWatch Alarm → dlq-handler）────────────

# DLQ の CloudWatch Alarm が ALARM 状態に遷移した際に
# dlq-handler Lambda を即時起動するための EventBridge ルール。
#
# EventBridge ネイティブの Alarm State Change イベント:
#   CloudWatch はアラーム状態変化を自動的に EventBridge デフォルトバスに発行する。
#   SNS アクションとは独立して動作し、Lambda を直接トリガーできる。
#
# CloudWatch Alarm 通知（SNS）との使い分け:
#   - SNS アクション → メール通知（人間への通知）
#   - EventBridge ルール → Lambda 自動処理（機械的な対応）
resource "aws_cloudwatch_event_rule" "dlq_alarm_trigger" {
  name        = "${var.project}-${var.environment}-dlq-alarm-trigger"
  description = "DLQ の CloudWatch Alarm が ALARM 状態になった際に dlq-handler を起動する"

  # CloudWatch Alarm の状態変化イベントをキャッチする
  # 対象: sep-dev- prefix を持つ全アラームの ALARM 状態移行
  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    detail = {
      state = {
        value = ["ALARM"]
      }
      # sep-dev-*-messages-alarm にマッチする（DLQ アラーム命名規則に準拠）
      alarmName = [{ prefix = "${var.project}-${var.environment}-" }]
    }
  })

  tags = local.common_tags
}

# EventBridge ターゲット: dlq-handler Lambda の live エイリアスを呼び出す
resource "aws_cloudwatch_event_target" "dlq_alarm_trigger_lambda" {
  rule      = aws_cloudwatch_event_rule.dlq_alarm_trigger.name
  target_id = "DlqHandlerLambda"
  arn       = module.dlq_handler.alias_arn
}

# Lambda リソースポリシー: EventBridge ルールからの呼び出しを許可する
resource "aws_lambda_permission" "dlq_handler_eventbridge" {
  statement_id  = "AllowEventBridgeAlarmTrigger"
  action        = "lambda:InvokeFunction"
  function_name = module.dlq_handler.function_name
  qualifier     = "live"
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.dlq_alarm_trigger.arn
}

# ── オブザーバビリティ基盤 ────────────────────────────────────────────

# X-Ray グループ・サンプリングルール・CloudWatch ダッシュボード・アラーム×7・
# Log Insights 保存済みクエリ×3・Lambda Insights IAM を一元管理するモジュール。
#
# 依存関係の設計:
#   module.observability は全 Lambda モジュールの後に定義する。
#   lambda_function_names・lambda_role_names・log_group_names に各モジュールの
#   output を渡すことで依存が明確になる。
#
#   Lambda モジュールへの Lambda Insights レイヤーアタッチは
#   data.aws_ssm_parameter.lambda_insights_layer_arn で循環依存を回避している。
module "observability" {
  source = "../../modules/observability"

  environment = var.environment
  project     = var.project

  # アラーム・OK 通知先: 既存の sep-dev-alerts SNS トピックを共有する
  sns_topic_arn = aws_sns_topic.alerts.arn

  # ダッシュボード・スロットル・コールドスタートアラームの対象関数（名前順）
  lambda_function_names = [
    module.ingestor.function_name,
    module.transformer.function_name,
    module.aggregator.function_name,
    module.dlq_handler.function_name,
  ]

  # Lambda Insights IAM ポリシーアタッチ対象のロール名
  lambda_role_names = [
    module.ingestor.role_name,
    module.transformer.role_name,
    module.aggregator.role_name,
    module.dlq_handler.role_name,
  ]

  # DLQ ARN: sqs-pipeline（ingest DLQ）と kinesis-pipeline（transform DLQ）から参照する
  ingest_dlq_arn    = module.sqs_pipeline_ingest.dlq_arn
  transform_dlq_arn = module.kinesis_pipeline.dlq_arn

  # Kinesis ストリーム名: イテレータエイジアラームおよびダッシュボードで使用する
  kinesis_stream_name = module.kinesis_pipeline.stream_name

  # Log Insights クエリのデフォルト対象ロググループ: 全 Lambda ログを対象にする
  log_group_names = [
    module.ingestor.log_group_name,
    module.transformer.log_group_name,
    module.aggregator.log_group_name,
    module.dlq_handler.log_group_name,
  ]

  # dev 環境: 全トレースを記録して問題追跡を容易にする（コストより可視性を優先）
  # prod 環境: x_ray_sampling_rate = 10 に変更してコストを最適化する
  x_ray_sampling_rate = 100

  common_tags = local.common_tags
}
