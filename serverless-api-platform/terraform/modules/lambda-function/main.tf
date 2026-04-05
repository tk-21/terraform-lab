# terraform/modules/lambda-function/main.tf
#
# 全 Lambda 関数で再利用する共通モジュール。
# ソースコードの zip 化 → S3 アップロード → Lambda デプロイ → IAM ロール作成 を一括で行う。
#
# IAM ロールの使い分け:
#   - execution_role_arn を指定: 外部で作成したロールを使用（module "iam" との連携）
#   - execution_role_arn を省略: モジュール内でロールを自動作成（スタンドアロン利用）

locals {
  # デプロイパッケージのローカル出力先（terraform plan/apply 実行ディレクトリ基準）
  zip_output_path = "${path.root}/dist/${var.function_name}.zip"

  # S3 オブジェクトキー: 関数名 + ハッシュでユニーク性を保証
  # ハッシュを含めることで同名の古い zip が誤って参照されるのを防ぐ
  s3_key = "lambda/${var.function_name}/${data.archive_file.lambda_zip.output_base64sha256}.zip"

  # 外部ロールが指定された場合はそれを使用。未指定の場合はモジュール内で作成したロールを使用。
  # module "iam" で一元管理する場合は execution_role_arn を渡すこと。
  effective_role_arn = var.execution_role_arn != null ? var.execution_role_arn : aws_iam_role.this[0].arn
}

# ============================================================
# 1. デプロイパッケージ（zip）の生成
# ============================================================
# source_dir 配下のファイルをすべて zip に圧縮する。
# output_base64sha256 で変更検知: zip が変わった時だけ S3 アップロードと
# Lambda 更新が走る。変更がない場合は terraform apply をスキップできる。
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = local.zip_output_path
}

# ============================================================
# 2. デプロイパッケージを S3 にアップロード
# ============================================================
# Lambda の deployment package を S3 経由にする理由:
# - ローカル filename 直接指定（~50MB 上限）より S3 経由の方が大きなパッケージに対応
# - CI/CD パイプラインでビルド成果物を S3 に保存→ Terraform が S3 キーを参照する構成と親和性が高い
# - source_code_hash で変更がない場合は S3 アップロード・Lambda 更新をスキップする
resource "aws_s3_object" "lambda_zip" {
  bucket = var.deployment_bucket_name
  key    = local.s3_key
  source = data.archive_file.lambda_zip.output_path

  # ファイルハッシュが変わった場合のみ S3 オブジェクトを更新する
  source_hash = data.archive_file.lambda_zip.output_base64sha256
}

# ============================================================
# 3. IAM 実行ロール（最小権限）— execution_role_arn 未指定の場合のみ作成
# ============================================================
resource "aws_iam_role" "this" {
  # execution_role_arn が指定された場合は内部ロールを作成しない
  count = var.execution_role_arn == null ? 1 : 0

  name        = "${var.function_name}-role"
  description = "Lambda 実行ロール for ${var.function_name}"

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

# CloudWatch Logs への書き込み権限（最小権限: 自関数のロググループのみ）
# AWS 管理ポリシー AWSLambdaBasicExecutionRole は全ロググループへの権限を持つため使用しない。
resource "aws_iam_role_policy" "logs" {
  count = var.execution_role_arn == null ? 1 : 0

  name = "${var.function_name}-logs-policy"
  role = aws_iam_role.this[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
      ]
      # 自関数のロググループのみに限定（ワイルドカード禁止）
      Resource = "${aws_cloudwatch_log_group.this.arn}:*"
    }]
  })
}

# X-Ray トレーシング権限
# AWS 管理ポリシーを使用（X-Ray の権限範囲は固定で追加リスクなし）
resource "aws_iam_role_policy_attachment" "xray" {
  count = var.execution_role_arn == null ? 1 : 0

  role       = aws_iam_role.this[0].name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# 関数固有の追加権限（DynamoDB・S3 など）
# additional_policy_statements が空の場合はリソースを作成しない
# execution_role_arn を指定した場合は外部ロール側で権限管理するため作成しない
resource "aws_iam_role_policy" "additional" {
  count = length(var.additional_policy_statements) > 0 && var.execution_role_arn == null ? 1 : 0

  name = "${var.function_name}-additional-policy"
  role = aws_iam_role.this[0].id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [
      for stmt in var.additional_policy_statements : {
        Effect   = stmt.effect
        Action   = stmt.actions
        Resource = stmt.resources
      }
    ]
  })
}

# ============================================================
# 4. CloudWatch Logs グループ
# ============================================================
# Lambda より先にロググループを作成することで:
# - 保持期間を Terraform で管理できる（Lambda 任せにすると無期限になる）
# - ロール作成時の循環参照を防ぐ
resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

# ============================================================
# 5. Lambda 関数
# ============================================================
resource "aws_lambda_function" "this" {
  function_name = var.function_name
  description   = var.description
  role          = local.effective_role_arn

  # デプロイパッケージは S3 経由
  s3_bucket        = var.deployment_bucket_name
  s3_key           = aws_s3_object.lambda_zip.key
  # source_code_hash: zip の内容が変わった時だけ Lambda を更新する。
  # S3 キーが変わっても hash が同じなら Lambda 更新をスキップできる。
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  handler       = var.handler
  runtime       = var.runtime
  architectures = var.architectures

  # ============================================================
  # タイムアウト設定（25秒の理由）
  # ============================================================
  # API Gateway REST API の統合タイムアウト上限は 29 秒（変更不可）。
  # Lambda のタイムアウトを 25 秒（< 29 秒）に設定することで、
  # 処理が長引いた場合に API GW 側が先にタイムアウトする前に
  # Lambda がエラーをキャッチして structured error response を返せる。
  # API GW がタイムアウトすると 504 Gateway Timeout が返り、
  # Lambda のエラーハンドリングが機能しない。
  timeout     = var.timeout
  memory_size = var.memory_size

  # ============================================================
  # 予約済み同時実行数（暴走防止）
  # ============================================================
  # デフォルト 10 の意図: variables.tf のコメント参照。
  # -1 を指定すると予約なし（アカウント上限まで自動スケール）。
  reserved_concurrent_executions = var.reserved_concurrent_executions

  # ============================================================
  # 環境変数（Powertools を自動付与）
  # ============================================================
  # merge() の順序: 呼び出し元の environment_variables が後に来るため
  # 呼び出し元の値でモジュール提供のデフォルトを上書きできる。
  # ただし POWERTOOLS_* は原則モジュールが管理する値を優先すること。
  environment {
    variables = merge(
      {
        # AWS Lambda Powertools 必須設定
        # structured log の service フィールドに使用される
        POWERTOOLS_SERVICE_NAME = var.function_name

        # CloudWatch Metrics のカスタム名前空間
        # ダッシュボード・アラームで参照する
        POWERTOOLS_METRICS_NAMESPACE = "ServerlessApiPlatform"

        # ログレベル（DEBUG / INFO / WARNING / ERROR / CRITICAL）
        LOG_LEVEL = var.log_level
      },
      # 呼び出し元の変数はデフォルトを上書きできる
      var.environment_variables,
    )
  }

  # ============================================================
  # CloudWatch Logs 構造化ログ設定
  # ============================================================
  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.this.name
  }

  # ============================================================
  # X-Ray アクティブトレーシング
  # ============================================================
  # Lambda Powertools の @tracer.capture_lambda_handler デコレーターと連携し、
  # サービスマップ上で各 Lambda の実行時間・エラー率を可視化できる。
  tracing_config {
    mode = "Active"
  }

  # ロール・ロググループが先に存在することを保証する
  depends_on = [
    aws_iam_role_policy.logs,
    aws_cloudwatch_log_group.this,
  ]

  tags = var.tags
}

# ============================================================
# 6. Provisioned Concurrency（prod のみ）
# ============================================================
# コールドスタートを排除し、レイテンシを安定させる。
# Lambda が常時ウォームな状態を維持するためコストが発生する。
# dev では provisioned_concurrency = 0（デフォルト）を維持すること。
resource "aws_lambda_provisioned_concurrency_config" "this" {
  count = var.provisioned_concurrency > 0 ? 1 : 0

  function_name = aws_lambda_function.this.function_name
  # $LATEST ではなくエイリアス or バージョンに設定する必要があるため
  # Terraform の aws_lambda_function は公開済みバージョンを参照する
  qualifier                          = aws_lambda_function.this.version
  provisioned_concurrent_executions = var.provisioned_concurrency
}

# ============================================================
# 7. DynamoDB Streams イベントソースマッピング
# ============================================================
# event_source_arn が指定された場合のみ作成する（stream-processor 専用）。
resource "aws_lambda_event_source_mapping" "dynamodb_stream" {
  count = var.event_source_arn != null ? 1 : 0

  event_source_arn = var.event_source_arn
  function_name    = aws_lambda_function.this.arn

  # TRIM_HORIZON: ストリームの最初（最古）から処理する。
  # stream-processor の初回デプロイ時にすべての既存変更を処理するために設定する。
  # LATEST にするとデプロイ以前の変更が監査ログに残らないため TRIM_HORIZON が適切。
  starting_position = "TRIM_HORIZON"

  # バッチサイズ: 1回の Lambda 呼び出しで処理するレコード数。
  # 100 に設定してスループットを最大化する。
  # ReportBatchItemFailures と組み合わせることで失敗レコードのみリトライできる。
  batch_size = 100

  # bisect_on_function_error: Lambda がエラーを返したとき、バッチを2分割してリトライする。
  # 問題レコードを特定するための二分探索として機能する。
  # 1レコードまで絞り込まれた時点でそのレコードを DLQ に送信するか破棄できる。
  bisect_on_function_error = true

  # 部分的なバッチ失敗のレポートを有効化。
  # 失敗したレコードのみリトライし、成功済みレコードを再処理しない。
  function_response_types = ["ReportBatchItemFailures"]
}
