# オブザーバビリティモジュール
# X-Ray グループ・サンプリングルール・CloudWatch ダッシュボード・アラーム・
# Log Insights クエリ・Lambda Insights を一元管理する。
#
# 設計方針:
#   - 全アラームは SNS 経由でメール通知（alarm_actions / ok_actions に sns_topic_arn）
#   - ダッシュボード JSON は jsonencode() で管理し、Lambda 関数名の動的生成に for 式を使用
#   - Lambda Insights IAM ポリシーは for_each で全ロールに一括アタッチ
#   - X-Ray サンプリングレートは環境変数で制御（本番 10% / 開発 100%）

# ── データソース ─────────────────────────────────────────────────────

# 現在のリージョン: ダッシュボードウィジェットの region プロパティで動的参照する。
# ハードコードを避けることでリージョン移行時の変更箇所を最小化する。
data "aws_region" "current" {}

# Lambda Insights レイヤー ARN（arm64）: AWS 公式 SSM パスから取得する。
# バージョンを固定せず "latest" を使用することで、自動的に最新拡張機能が適用される。
# ※ Lambda 関数への実際のアタッチは environments/dev/main.tf で layers 変数経由で行う。
#    observability モジュールは ARN を output として公開するだけ（循環依存を防ぐため）。
data "aws_ssm_parameter" "lambda_insights_layer_arm64" {
  name = "/aws/service/lambda-insights/extension/arm64/latest"
}

# ── ローカル変数 ─────────────────────────────────────────────────────

locals {
  # SQS ARN からキュー名を抽出する。
  # ARN 形式: arn:aws:sqs:<region>:<account-id>:<queue-name>
  # regex("[^:]+$", arn) で末尾のコロン以降（キュー名）を取得する。
  ingest_dlq_name    = regex("[^:]+$", var.ingest_dlq_arn)
  transform_dlq_name = regex("[^:]+$", var.transform_dlq_arn)

  region = data.aws_region.current.name
}

# ── 1. X-Ray グループ ─────────────────────────────────────────────────

# X-Ray グループ: パイプライン主要サービスをグループ化してコンソールで絞り込み表示できるようにする。
# filter_expression の service() は POWERTOOLS_SERVICE_NAME 環境変数の値に一致する。
# lambda-function モジュールで POWERTOOLS_SERVICE_NAME = function_name に設定されるため
# 関数名をそのまま指定する。
resource "aws_xray_group" "pipeline" {
  group_name = "${var.project}-${var.environment}-pipeline"

  # ingestor と transformer の両サービスのトレースをグループ化する。
  # OR 演算子: どちらかのサービスを通過するトレースを全て含む。
  filter_expression = "service(\"${var.project}-${var.environment}-ingestor\") OR service(\"${var.project}-${var.environment}-transformer\")"

  # Insights: 異常なトレースパターン（エラー率の急増・レイテンシの外れ値）を自動検知する。
  # notifications_enabled = true で Insights の検知結果を EventBridge に発行する。
  insights_configuration {
    insights_enabled      = true
    notifications_enabled = true
  }

  tags = var.common_tags
}

# ── 2. X-Ray サンプリングルール ───────────────────────────────────────

# カスタムサンプリングルール: 環境ごとにサンプリング率を制御してコストを最適化する。
#
# priority 1000: デフォルトルール（priority 10000）より優先して評価される。
#   数値が小さいほど優先度が高い。1 は最高優先度（予約済み）のため 1000 を使用する。
#
# reservoir_size = 5: 1 秒あたりの最低保証サンプル数。
#   fixed_rate の確率サンプリングに加えて、最低 5 件/秒のトレースを保証する。
#   ゼロトラフィック時でも最低限のトレースを記録する。
#
# fixed_rate: 0.0〜1.0 の小数で指定する（例: 10% → 0.10）。
#   x_ray_sampling_rate を 100 で除算して変換する。
resource "aws_xray_sampling_rule" "pipeline" {
  rule_name      = "${var.project}-${var.environment}-pipeline-sampling"
  priority       = 1000
  reservoir_size = 5
  fixed_rate     = var.x_ray_sampling_rate / 100

  # 適用対象の条件: sep-<env>- プレフィックスを持つ全サービス（ingestor / transformer / aggregator / dlq-handler）
  url_path     = "*"
  host         = "*"
  http_method  = "*"
  service_type = "*"
  service_name = "${var.project}-${var.environment}-*"
  resource_arn = "*"
  version      = 1

  tags = var.common_tags
}

# ── 3. Lambda Insights IAM ポリシーアタッチ ───────────────────────────

# Lambda Insights の有効化には CloudWatchLambdaInsightsExecutionRolePolicy が必要。
# この AWS マネージドポリシーは以下の権限を含む:
#   - cloudwatch:PutMetricData（Enhanced Monitoring メトリクスの書き込み）
#   - logs:CreateLogGroup / logs:PutLogEvents（Insights ログの書き込み）
#   - xray:PutTraceSegments / xray:PutTelemetryRecords（トレース送信）
#
# for_each で全 Lambda 実行ロールに一括アタッチする。
# ロール名は environments/dev/main.tf から module.<name>.role_name で渡される。
resource "aws_iam_role_policy_attachment" "lambda_insights" {
  for_each = toset(var.lambda_role_names)

  role       = each.value
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLambdaInsightsExecutionRolePolicy"
}

# ── 4. CloudWatch アラーム ────────────────────────────────────────────

# [CRITICAL] ingestor エラー率アラーム
#
# 監視意図: S3 PUT → ingestor Lambda のバリデーション失敗・DynamoDB 書き込みエラーを検知する。
# エラー率 = Errors / Invocations × 100 > 5% で発火する。
#
# IF() 式の目的: Invocations = 0 のとき（Lambda が起動していない期間）にゼロ除算で
#   NaN が発生するのを防ぎ、誤検知アラームを防止する。
#
# evaluate_low_sample_count_percentiles について:
#   本来はパーセンタイル統計（p50, p95 等）使用時のみ有効な設定。
#   サンプル数が統計的に有意でない期間にアラーム状態への遷移を抑制する。
#   本アラームは Sum 統計のメトリクスを metric math で計算するため直接影響しないが、
#   将来 extended_statistic に変更した際の安全ネットとして "ignore" を設定する。
resource "aws_cloudwatch_metric_alarm" "ingestor_error_rate" {
  alarm_name        = "${var.project}-${var.environment}-ingestor-errors"
  alarm_description = "[CRITICAL] ${var.project}-${var.environment}-ingestor のエラー率が 5% を超えています。CloudWatch Logs・X-Ray トレースで根本原因を確認し、runbook.md の「Lambda エラー対応」手順を実行してください。"

  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 5
  treat_missing_data  = "notBreaching"

  # パーセンタイル統計使用時にサンプル数不足でのアラーム発火を抑制する設定。
  # Sum/Average 等の統計では AWS 側で無視されるが、将来の変更に備えて統一設定する。
  evaluate_low_sample_count_percentiles = "ignore"

  # errors / invocations * 100 でエラー率（%）を計算する。
  # メトリクス ID は CloudWatch の命名制約: 先頭が英字・英数字とアンダースコアのみ使用可。
  metric_query {
    id          = "error_rate_in"
    expression  = "IF(invocations_in > 0, errors_in / invocations_in * 100, 0)"
    label       = "Error Rate (%)"
    return_data = true
  }

  metric_query {
    id = "errors_in"
    metric {
      namespace   = "AWS/Lambda"
      metric_name = "Errors"
      # FunctionName ディメンション: Lambda コンソールの関数名と一致する
      dimensions = { FunctionName = "${var.project}-${var.environment}-ingestor" }
      # 5 分（300 秒）集計ウィンドウ: 一時的なスパイクに反応せず安定したエラー率を評価する
      period = 300
      stat   = "Sum"
    }
  }

  metric_query {
    id = "invocations_in"
    metric {
      namespace   = "AWS/Lambda"
      metric_name = "Invocations"
      dimensions  = { FunctionName = "${var.project}-${var.environment}-ingestor" }
      period      = 300
      stat        = "Sum"
    }
  }

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]

  tags = var.common_tags
}

# [CRITICAL] transformer エラー率アラーム
#
# 監視意図: Kinesis → transformer Lambda のレコード変換失敗・DynamoDB BatchWriteItem エラーを検知する。
# transformer のエラーは Kinesis イテレータエイジの増加を引き起こすため、
# 本アラームと kinesis-iterator-age アラームを組み合わせて根本原因を特定する。
resource "aws_cloudwatch_metric_alarm" "transformer_error_rate" {
  alarm_name        = "${var.project}-${var.environment}-transformer-errors"
  alarm_description = "[CRITICAL] ${var.project}-${var.environment}-transformer のエラー率が 5% を超えています。transform DLQ の滞留状況および X-Ray トレースを確認してください。runbook.md の「Kinesis 遅延対応」を参照してください。"

  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 5
  treat_missing_data  = "notBreaching"

  evaluate_low_sample_count_percentiles = "ignore"

  metric_query {
    id          = "error_rate_tx"
    expression  = "IF(invocations_tx > 0, errors_tx / invocations_tx * 100, 0)"
    label       = "Error Rate (%)"
    return_data = true
  }

  metric_query {
    id = "errors_tx"
    metric {
      namespace   = "AWS/Lambda"
      metric_name = "Errors"
      dimensions  = { FunctionName = "${var.project}-${var.environment}-transformer" }
      period      = 300
      stat        = "Sum"
    }
  }

  metric_query {
    id = "invocations_tx"
    metric {
      namespace   = "AWS/Lambda"
      metric_name = "Invocations"
      dimensions  = { FunctionName = "${var.project}-${var.environment}-transformer" }
      period      = 300
      stat        = "Sum"
    }
  }

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]

  tags = var.common_tags
}

# [WARNING] ingest DLQ 滞留アラーム
#
# 監視意図: S3 → SQS → ingestor Lambda の処理失敗メッセージを即時検知する。
# DLQ に 1 件でも滞留した場合は dlq-handler が EventBridge 経由で自動起動するが、
# 同時に運用担当者への通知も行い、恒久エラー（バリデーション失敗など）の手動調査を促す。
#
# treat_missing_data = "notBreaching": DLQ が空の場合（メッセージなし）は OK 状態を維持する。
#   SQS メトリクスはメッセージが存在しない場合にデータポイントを送信しないため、
#   "missing" を "breaching" にすると誤検知が発生する。
resource "aws_cloudwatch_metric_alarm" "ingest_dlq_depth" {
  alarm_name        = "${var.project}-${var.environment}-ingest-dlq-depth"
  alarm_description = "[WARNING] ingest DLQ (${local.ingest_dlq_name}) にメッセージが滞留しています。dlq-handler が自動処理しますが、PERMANENT カテゴリの恒久エラーは手動調査が必要です。CloudWatch Logs で correlation_id を検索してください。"

  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  # 60 秒ごとに評価する（SQS メトリクスの最小粒度は 1 分）
  period    = 60
  statistic = "Sum"
  threshold = 1

  dimensions = {
    QueueName = local.ingest_dlq_name
  }

  treat_missing_data = "notBreaching"

  evaluate_low_sample_count_percentiles = "ignore"

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]

  tags = var.common_tags
}

# [WARNING] transform DLQ 滞留アラーム
#
# 監視意図: Kinesis ESM 失敗送信先の DLQ 滞留を検知する。
# maximum_retry_attempts（3回）を超えた Kinesis レコードがここに送信される。
# Kinesis レコードには元データが含まれるため、長期滞留による損失を防ぐ。
resource "aws_cloudwatch_metric_alarm" "transform_dlq_depth" {
  alarm_name        = "${var.project}-${var.environment}-transform-dlq-depth"
  alarm_description = "[WARNING] transform DLQ (${local.transform_dlq_name}) にメッセージが滞留しています。Kinesis レコードの変換に繰り返し失敗しています。X-Ray トレースで失敗レコードのパターンを確認してください。"

  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Sum"
  threshold           = 1

  dimensions = {
    QueueName = local.transform_dlq_name
  }

  treat_missing_data = "notBreaching"

  evaluate_low_sample_count_percentiles = "ignore"

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]

  tags = var.common_tags
}

# [WARNING] Kinesis イテレータエイジアラーム
#
# 監視意図: Kinesis ストリームのコンシューマーラグ（処理遅延）を検知する。
# GetRecords.IteratorAgeMilliseconds = レコードが Kinesis に書き込まれてから
#   Lambda に届くまでの経過時間（ミリ秒）。
# 60,000ms（60秒）超過: transformer が Kinesis の書き込み速度に追いついていない。
#
# kinesis-pipeline モジュール内にも同様のアラームが存在するが、
# 本アラームは observability モジュールで一元管理する版（名前が異なるため重複しない）。
# kinesis-pipeline モジュール側のアラーム: sep-dev-events-stream-iterator-age-alarm
# observability モジュール側のアラーム: sep-dev-kinesis-iterator-age
#
# statistic = "Maximum": 複数シャードのうち最も遅延しているシャードを検知する。
#   "Average" では遅延シャードが希釈されて検知漏れが発生するため使用しない。
resource "aws_cloudwatch_metric_alarm" "kinesis_iterator_age" {
  alarm_name        = "${var.project}-${var.environment}-kinesis-iterator-age"
  alarm_description = "[WARNING] Kinesis ストリーム (${var.kinesis_stream_name}) のイテレータエイジが 60 秒を超えています。transformer Lambda の処理速度不足・DynamoDB スロットリング・Lambda 同時実行上限を確認してください。"

  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "GetRecords.IteratorAgeMilliseconds"
  namespace           = "AWS/Kinesis"
  period              = 60
  # Maximum: 全シャードの中で最も遅延しているシャードの値を評価する
  statistic = "Maximum"
  # 60秒（60,000ms）を超えたらアラーム発火: CLAUDE.md エラーハンドリング戦略準拠
  threshold = 60000

  dimensions = {
    StreamName = var.kinesis_stream_name
  }

  # ストリームへの書き込みがない期間はデータポイントが発行されないため notBreaching を設定する
  treat_missing_data = "notBreaching"

  evaluate_low_sample_count_percentiles = "ignore"

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]

  tags = var.common_tags
}

# [WARNING] Lambda スロットルアラーム
#
# 監視意図: 全 Lambda 関数のスロットル合計が 5 分間で 10 回を超えた場合に検知する。
# スロットリング原因:
#   1. reserved_concurrent_executions の上限到達
#   2. アカウントレベルの同時実行制限（デフォルト 1000）到達
#   3. ダウンストリーム（DynamoDB など）のスロットリングによる Lambda 処理遅延
#
# SUM(METRICS("thr_")) で "thr_" プレフィックスを持つ全メトリクスクエリを合算する。
# dynamic ブロックで var.lambda_function_names の全関数を動的に追加できる。
# CloudWatch metric math の制約: メトリクスクエリ数の上限は 10。
#   関数 4 本: 1（expression）+ 4（metrics）= 5 クエリ ✓
resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  alarm_name        = "${var.project}-${var.environment}-lambda-throttles"
  alarm_description = "[WARNING] Lambda スロットル回数が 5 分間で 10 回を超えました。reserved_concurrent_executions の設定またはアカウント同時実行制限（Service Quotas）を確認してください。"

  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 10
  treat_missing_data  = "notBreaching"

  evaluate_low_sample_count_percentiles = "ignore"

  # SUM(METRICS("thr_")): "thr_" で始まる全メトリクスクエリ ID を合算する。
  # 関数の追加・削除に対して expression を変更せず対応できる拡張可能な設計。
  metric_query {
    id          = "total_throttles"
    expression  = "SUM(METRICS(\"thr_\"))"
    label       = "Total Throttles (All Functions)"
    return_data = true
  }

  # dynamic ブロック: var.lambda_function_names の全関数に対してメトリクスクエリを生成する。
  # mq.key: "fn0", "fn1", ... でユニークな ID を生成する。
  # mq.value: Lambda 関数名（FunctionName ディメンション値）。
  dynamic "metric_query" {
    for_each = { for idx, fn in var.lambda_function_names : "fn${idx}" => fn }
    iterator = mq
    content {
      # ID: "thr_fn0", "thr_fn1", ... → SUM(METRICS("thr_")) で合算される
      id = "thr_${mq.key}"
      metric {
        namespace   = "AWS/Lambda"
        metric_name = "Throttles"
        dimensions  = { FunctionName = mq.value }
        period      = 300
        stat        = "Sum"
      }
    }
  }

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]

  tags = var.common_tags
}

# [INFO] コールドスタート率アラーム
#
# 監視意図: コールドスタート率 > 30% は Lambda の起動レイテンシが高く
#   ユーザー体験に影響する可能性を示す。
# Powertools が出力するカスタムメトリクス ColdStart を使用する（CLAUDE.md 参照）:
#   namespace: ServerlessEventPipeline（Metrics クラスで設定）
#   metric_name: ColdStart（capture_cold_start_metric=True で自動出力）
#   dimension: function_name=<POWERTOOLS_SERVICE_NAME> = Lambda 関数名
#
# 対策: Provisioned Concurrency の有効化・Lambda パッケージサイズの削減
#
# メトリクスクエリ数: 1（expression）+ N（ColdStart）+ N（Invocations）= 1 + 2N
#   関数 4 本の場合: 1 + 8 = 9 クエリ ≤ 10（CloudWatch 上限） ✓
#
# IF(SUM(METRICS("inv_")) > 0, ...) で Invocations = 0 期間のゼロ除算を防ぐ。
# SUM(METRICS("cs_")) と SUM(METRICS("inv_")) を expression に直接インライン化することで
# 中間クエリを削減し、合計クエリ数を上限内に収める。
resource "aws_cloudwatch_metric_alarm" "cold_start_rate" {
  alarm_name        = "${var.project}-${var.environment}-cold-start-rate"
  alarm_description = "[INFO] コールドスタート率が 30% を超えています。Provisioned Concurrency の導入または Lambda デプロイパッケージの軽量化（依存関係の削減・Layer 分離）を検討してください。"

  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 30
  treat_missing_data  = "notBreaching"

  evaluate_low_sample_count_percentiles = "ignore"

  # IF() で Invocations ゼロ期間の誤検知を防ぎつつ、
  # METRICS("prefix") で動的に全関数を合算する。
  metric_query {
    id          = "cold_start_rate_pct"
    expression  = "IF(SUM(METRICS(\"inv_\")) > 0, SUM(METRICS(\"cs_\")) / SUM(METRICS(\"inv_\")) * 100, 0)"
    label       = "Cold Start Rate (%)"
    return_data = true
  }

  # "cs_fn0", "cs_fn1", ... → SUM(METRICS("cs_")) で合算される
  dynamic "metric_query" {
    for_each = { for idx, fn in var.lambda_function_names : "fn${idx}" => fn }
    iterator = mq
    content {
      id = "cs_${mq.key}"
      metric {
        # Powertools カスタムメトリクス namespace（CLAUDE.md: namespace="ServerlessEventPipeline"）
        namespace   = "ServerlessEventPipeline"
        metric_name = "ColdStart"
        # function_name ディメンション: POWERTOOLS_SERVICE_NAME の値と一致する
        # lambda-function モジュールで POWERTOOLS_SERVICE_NAME = function_name に設定される
        dimensions = {
          function_name = mq.value
          service       = mq.value
        }
        period = 300
        stat   = "Sum"
      }
    }
  }

  # "inv_fn0", "inv_fn1", ... → SUM(METRICS("inv_")) で合算される
  dynamic "metric_query" {
    for_each = { for idx, fn in var.lambda_function_names : "fn${idx}" => fn }
    iterator = mq
    content {
      id = "inv_${mq.key}"
      metric {
        namespace   = "AWS/Lambda"
        metric_name = "Invocations"
        dimensions  = { FunctionName = mq.value }
        period      = 300
        stat        = "Sum"
      }
    }
  }

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]

  tags = var.common_tags
}

# ── 5. CloudWatch ダッシュボード ──────────────────────────────────────

# ダッシュボード構成（上から順に配置）:
#   Row  0 ( y=0,  h=2): タイトルテキスト
#   Row  1 ( y=2,  h=6): Lambda Invocations (L) | Lambda Errors (R)
#   Row  2 ( y=8,  h=6): Lambda Duration p50/p95 (L) | Lambda Throttles (R)
#   Row  3 ( y=14, h=6): Lambda ConcurrentExecutions (全幅)
#   Row  4 ( y=20, h=6): カスタムメトリクス ProcessedRecords・ValidationErrors 等（全幅）
#   Row  5 ( y=26, h=6): Kinesis IteratorAge (L) | Kinesis PutRecords (R)
#   Row  6 ( y=32, h=6): DLQ ApproximateNumberOfMessagesVisible（全幅）
#   Row  7 ( y=38, h=3): X-Ray サービスマップへのリンク（テキストウィジェット）
resource "aws_cloudwatch_dashboard" "pipeline" {
  dashboard_name = "${var.project}-${var.environment}-pipeline-dashboard"

  dashboard_body = jsonencode({
    widgets = [

      # ─── ヘッダー ───────────────────────────────────────────────
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 2
        properties = {
          markdown = "# Serverless Event Pipeline — ${upper(var.environment)} Dashboard\nリアルタイム監視: Lambda・Kinesis・DLQ・カスタムメトリクス・X-Ray"
        }
      },

      # ─── Lambda Invocations ────────────────────────────────────
      # 各関数の起動回数を 1 分粒度で表示する。
      # スパイク・急落どちらもアノマリーの可能性があるため時系列で視覚化する。
      {
        type   = "metric"
        x      = 0
        y      = 2
        width  = 12
        height = 6
        properties = {
          title  = "Lambda Invocations（関数別・1分粒度）"
          view   = "timeSeries"
          region = local.region
          period = 60
          stat   = "Sum"
          metrics = [
            for fn in var.lambda_function_names :
            ["AWS/Lambda", "Invocations", "FunctionName", fn, { label = fn }]
          ]
          yAxis = { left = { min = 0 } }
        }
      },

      # ─── Lambda Errors ─────────────────────────────────────────
      # エラー数を関数別に表示する。
      # CloudWatch Alarm（ingestor-errors / transformer-errors）の根拠となる生データ。
      {
        type   = "metric"
        x      = 12
        y      = 2
        width  = 12
        height = 6
        properties = {
          title  = "Lambda Errors（関数別・1分粒度）"
          view   = "timeSeries"
          region = local.region
          period = 60
          stat   = "Sum"
          metrics = [
            for fn in var.lambda_function_names :
            ["AWS/Lambda", "Errors", "FunctionName", fn, { label = fn }]
          ]
          yAxis = { left = { min = 0 } }
        }
      },

      # ─── Lambda Duration ───────────────────────────────────────
      # p50（中央値）と p95（95パーセンタイル）を並べて表示する。
      # p50 は一般的なパフォーマンス・p95 はテールレイテンシ（SLO 目標値）を示す。
      # flatten で各関数につき 2 エントリ（p50・p95）を生成する。
      {
        type   = "metric"
        x      = 0
        y      = 8
        width  = 12
        height = 6
        properties = {
          title  = "Lambda Duration p50 / p95（ms）"
          view   = "timeSeries"
          region = local.region
          period = 60
          metrics = flatten([
            for fn in var.lambda_function_names : [
              ["AWS/Lambda", "Duration", "FunctionName", fn, { stat = "p50", label = "${fn} p50" }],
              ["AWS/Lambda", "Duration", "FunctionName", fn, { stat = "p95", label = "${fn} p95" }],
            ]
          ])
          yAxis = { left = { min = 0, label = "ms" } }
        }
      },

      # ─── Lambda Throttles ──────────────────────────────────────
      # スロットル発生回数を表示する。
      # Lambda 同時実行数制限またはダウンストリームのバックプレッシャーが原因であることが多い。
      {
        type   = "metric"
        x      = 12
        y      = 8
        width  = 12
        height = 6
        properties = {
          title  = "Lambda Throttles（関数別）"
          view   = "timeSeries"
          region = local.region
          period = 60
          stat   = "Sum"
          metrics = [
            for fn in var.lambda_function_names :
            ["AWS/Lambda", "Throttles", "FunctionName", fn, { label = fn }]
          ]
          yAxis = { left = { min = 0 } }
        }
      },

      # ─── Lambda ConcurrentExecutions ───────────────────────────
      # アカウント全体の同時実行数と関数別同時実行数を並べて表示する。
      # アカウント上限（デフォルト 1000）に近づいていないかを監視する。
      {
        type   = "metric"
        x      = 0
        y      = 14
        width  = 24
        height = 6
        properties = {
          title  = "Lambda ConcurrentExecutions（アカウント全体 + 関数別）"
          view   = "timeSeries"
          region = local.region
          period = 60
          metrics = flatten([
            # アカウント全体の同時実行数（ディメンションなし）
            [["AWS/Lambda", "ConcurrentExecutions", { stat = "Maximum", label = "Account Total (Max)" }]],
            # 関数別の同時実行数
            [for fn in var.lambda_function_names :
              ["AWS/Lambda", "ConcurrentExecutions", "FunctionName", fn, { stat = "Maximum", label = fn }]
            ],
          ])
          yAxis = { left = { min = 0 } }
        }
      },

      # ─── カスタムメトリクス ─────────────────────────────────────
      # Powertools が出力する ServerlessEventPipeline 名前空間のカスタムメトリクスを表示する。
      # 各 Lambda ハンドラが metrics.add_metric() で記録したビジネス指標。
      # service ディメンション = POWERTOOLS_SERVICE_NAME = Lambda 関数名。
      {
        type   = "metric"
        x      = 0
        y      = 20
        width  = 24
        height = 6
        properties = {
          title  = "カスタムメトリクス（ProcessedRecords・ValidationErrors・TransformedRecords・AggregatedEvents）"
          view   = "timeSeries"
          region = local.region
          period = 60
          stat   = "Sum"
          metrics = [
            # ingestor: バリデーション通過後の正常処理件数
            ["ServerlessEventPipeline", "ProcessedRecords",
              "service", "${var.project}-${var.environment}-ingestor",
              { label = "ProcessedRecords (ingestor)" }],
            # ingestor: バリデーション失敗件数（スキーマ不正・必須フィールド欠落など）
            ["ServerlessEventPipeline", "ValidationErrors",
              "service", "${var.project}-${var.environment}-ingestor",
              { label = "ValidationErrors (ingestor)" }],
            # transformer: 変換完了件数
            ["ServerlessEventPipeline", "TransformedRecords",
              "service", "${var.project}-${var.environment}-transformer",
              { label = "TransformedRecords (transformer)" }],
            # aggregator: DynamoDB Streams から集計したイベント件数
            ["ServerlessEventPipeline", "AggregatedEvents",
              "service", "${var.project}-${var.environment}-aggregator",
              { label = "AggregatedEvents (aggregator)" }],
          ]
          yAxis = { left = { min = 0 } }
        }
      },

      # ─── Kinesis GetRecords.IteratorAgeMilliseconds ─────────────
      # コンシューマーラグ（処理遅延）をミリ秒単位で表示する。
      # Maximum を使用: 全シャードの中で最も遅れているシャードの値を可視化する。
      # 60,000ms（60秒）超過でアラーム発火（kinesis-iterator-age アラーム参照）。
      {
        type   = "metric"
        x      = 0
        y      = 26
        width  = 12
        height = 6
        properties = {
          title  = "Kinesis IteratorAge (ms) — コンシューマーラグ"
          view   = "timeSeries"
          region = local.region
          period = 60
          stat   = "Maximum"
          metrics = [
            ["AWS/Kinesis", "GetRecords.IteratorAgeMilliseconds",
              "StreamName", var.kinesis_stream_name,
              { label = "IteratorAge (Max ms)" }]
          ]
          annotations = {
            horizontal = [
              # アラーム閾値ラインを表示して視覚的に閾値を明示する
              { value = 60000, label = "Alarm Threshold (60s)", color = "#ff7f0e" }
            ]
          }
          yAxis = { left = { min = 0, label = "ms" } }
        }
      },

      # ─── Kinesis PutRecords.Success ─────────────────────────────
      # プロデューサーからの書き込み成功件数を表示する。
      # IncomingRecords と比較することで書き込み成功率を確認できる。
      {
        type   = "metric"
        x      = 12
        y      = 26
        width  = 12
        height = 6
        properties = {
          title  = "Kinesis PutRecords.Success / IncomingRecords"
          view   = "timeSeries"
          region = local.region
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/Kinesis", "PutRecords.Success",
              "StreamName", var.kinesis_stream_name,
              { label = "PutRecords.Success" }],
            ["AWS/Kinesis", "IncomingRecords",
              "StreamName", var.kinesis_stream_name,
              { label = "IncomingRecords", stat = "Sum" }],
          ]
          yAxis = { left = { min = 0 } }
        }
      },

      # ─── DLQ ApproximateNumberOfMessagesVisible ─────────────────
      # 全 DLQ の滞留メッセージ数をリアルタイムで表示する。
      # 0 以外の値が表示された場合は即時調査が必要（アラームも同時に発火する）。
      {
        type   = "metric"
        x      = 0
        y      = 32
        width  = 24
        height = 6
        properties = {
          title  = "DLQ メッセージ数（ApproximateNumberOfMessagesVisible）"
          view   = "timeSeries"
          region = local.region
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible",
              "QueueName", local.ingest_dlq_name,
              { label = "ingest DLQ (${local.ingest_dlq_name})", color = "#d62728" }],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible",
              "QueueName", local.transform_dlq_name,
              { label = "transform DLQ (${local.transform_dlq_name})", color = "#ff7f0e" }],
          ]
          annotations = {
            horizontal = [
              { value = 1, label = "Alarm Threshold", color = "#d62728", fill = "above" }
            ]
          }
          yAxis = { left = { min = 0 } }
        }
      },

      # ─── X-Ray サービスマップリンク ──────────────────────────────
      # CloudWatch ダッシュボードには X-Ray サービスマップをネイティブ埋め込む機能がないため、
      # テキストウィジェットでコンソール参照先を案内する。
      {
        type   = "text"
        x      = 0
        y      = 38
        width  = 24
        height = 3
        properties = {
          markdown = "## X-Ray トレーシング\n**サービスマップ・トレース詳細は CloudWatch コンソール → X-Ray traces → Service map** から確認してください。\nグループ `${var.project}-${var.environment}-pipeline` でフィルタリングすると ingestor・transformer のトレースに絞り込めます。"
        }
      },
    ]
  })
}

# ── 6. CloudWatch Log Insights 保存済みクエリ ─────────────────────────

# エラーログ抽出クエリ
# 使用シーン: アラーム発火後の初動調査。correlation_id でトレースとの紐付けを行う。
# Powertools の構造化ログ形式（level・message・correlation_id フィールド）に依存する。
resource "aws_cloudwatch_query_definition" "error_logs" {
  name = "${var.project}/${var.environment}/error-log-extraction"

  query_string = <<-EOT
    fields @timestamp, level, message, correlation_id, error
    | filter level = "ERROR"
    | sort @timestamp desc
    | limit 100
  EOT

  # 全 Lambda ロググループをデフォルト検索対象に設定する。
  # Log Insights の実行時に追加・変更が可能。
  log_group_names = var.log_group_names
}

# 処理レイテンシ集計クエリ
# 使用シーン: SLO 違反の調査・Lambda タイムアウト閾値の見直し。
# Powertools ログの duration_ms フィールド（ハンドラ処理時間）を集計する。
# pct(duration_ms, 95) で p95 レイテンシを計算し、テールレイテンシを把握する。
resource "aws_cloudwatch_query_definition" "processing_latency" {
  name = "${var.project}/${var.environment}/processing-latency-aggregation"

  query_string = <<-EOT
    fields @timestamp, service, duration_ms
    | filter ispresent(duration_ms)
    | stats avg(duration_ms), max(duration_ms), pct(duration_ms, 95) by service
  EOT

  log_group_names = var.log_group_names
}

# DLQ 失敗トレースクエリ
# 使用シーン: DLQ アラーム発火後の失敗メッセージの原因分析。
# dlq-handler Lambda が記録する failure_reason・failure_category フィールドを検索する。
# correlation_id を使って X-Ray トレースと紐付け、元のリクエストまで追跡できる。
resource "aws_cloudwatch_query_definition" "dlq_failure_trace" {
  name = "${var.project}/${var.environment}/dlq-failure-trace"

  query_string = <<-EOT
    fields @timestamp, correlation_id, failure_reason, failure_category
    | filter ispresent(failure_reason)
    | sort @timestamp desc
  EOT

  log_group_names = var.log_group_names
}
