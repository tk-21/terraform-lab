# Lambda 関数共通モジュール
# arm64 アーキテクチャ・Powertools レイヤー・X-Ray・CloudWatch Logs を標準装備する。
# 全 Lambda 関数はこのモジュールを経由してデプロイし、設定の一貫性を保証する。

# ── ローカル変数 ──────────────────────────────────────────────

locals {
  # IAM ロール名: sep-<env>-<function_name>-role
  # ただし function_name には既に sep-<env>- prefix が含まれる想定のため、
  # 重複を避けて function_name から直接構築する。
  role_name = "${var.function_name}-role"

  # S3 オブジェクトキー: 関数ごとにパスを分け、同一バケット内で混在しても識別できるようにする
  s3_key = "lambda-packages/${var.function_name}/package.zip"

  # Powertools 必須環境変数を自動付与し、呼び出し元の設定値でオーバーライドできるようにマージする。
  # 呼び出し元が同じキーを指定した場合は呼び出し元の値が優先される。
  powertools_env_vars = {
    POWERTOOLS_SERVICE_NAME = var.function_name
    LOG_LEVEL               = var.log_level
  }
  merged_env_vars = merge(local.powertools_env_vars, var.environment_variables)

  # Powertools レイヤーを先頭に配置し、追加レイヤーを後続に結合する。
  # レイヤーの評価順序は末尾が優先されるため、Powertools を先頭にすることで
  # 追加レイヤーが Powertools の依存関係を上書きできるようにする。
  all_layers = concat(
    [data.aws_ssm_parameter.powertools_layer_arn.value],
    var.layers
  )

  # SSM パラメータ名: 未指定時はプロジェクト規約のパスを使用する
  powertools_ssm_name = var.powertools_ssm_parameter != "" ? var.powertools_ssm_parameter : "/${var.project}/${var.environment}/lambda/powertools_layer_arn"
}

# ── データソース ──────────────────────────────────────────────

# Powertools Lambda レイヤー ARN を SSM Parameter Store から取得する。
# ハードコードを避けることで、レイヤーバージョンの更新時に SSM の値を変更するだけで
# 全 Lambda 関数に自動反映できる。
# 注意: bootstrap.sh で /${project}/${env}/lambda/powertools_layer_arn を設定しておくこと。
data "aws_ssm_parameter" "powertools_layer_arn" {
  name = local.powertools_ssm_name
}

# ── 1. ソースコードの zip 化 ──────────────────────────────────

# src/<function_name>/ ディレクトリを zip に圧縮する。
# output_base64sha256 を Lambda の source_code_hash に渡すことで、
# ソースコードが変更されていない場合は Lambda の更新をスキップできる（毎回デプロイ防止）。
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.module}/dist/${var.function_name}.zip"
}

# ── 2. zip を S3 にアップロード ───────────────────────────────

# Lambda のデプロイパッケージは S3 経由でアップロードする。
# 直接アップロード（filename）は 50 MB 制限があるため、大規模依存関係に対応できない。
# etag に output_md5 を指定することで Terraform が内容変化を検知して S3 を更新する。
resource "aws_s3_object" "lambda_zip" {
  bucket = var.s3_bucket
  key    = local.s3_key
  source = data.archive_file.lambda_zip.output_path
  etag   = data.archive_file.lambda_zip.output_md5

  tags = var.common_tags
}

# ── 3. CloudWatch Logs グループ ───────────────────────────────

# Lambda が自動生成するロググループより先に Terraform で作成することで、
# 保持期間・KMS 暗号化などの設定を確実に適用できる。
# 命名規則 /aws/lambda/<function_name> は Lambda の自動生成と一致させる必要がある。
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = var.log_retention_days

  tags = var.common_tags
}

# ── 4. IAM ロール ─────────────────────────────────────────────

# Lambda 実行ロール。最小権限の原則に基づき、基本実行権限のみを付与する。
# 関数固有の権限（DynamoDB・SQS アクセスなど）は additional_policy_arns で追加する。
resource "aws_iam_role" "lambda" {
  name = local.role_name

  # Lambda サービスプリンシパルのみが AssumeRole できるように制限する
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = var.common_tags
}

# Lambda 基本実行ポリシー: CloudWatch Logs への書き込み権限を付与する。
# AWSLambdaBasicExecutionRole は AWS マネージドポリシーで最小限のログ権限のみを含む。
resource "aws_iam_role_policy_attachment" "basic_execution" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# X-Ray デーモン書き込みポリシー: トレースデータを X-Ray に送信する権限を付与する。
# X-Ray トレーシングを Active モードで使用するために必須。
resource "aws_iam_role_policy_attachment" "xray" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# 関数固有の追加ポリシーをアタッチする。
# for_each で複数ポリシーを動的にアタッチし、追加・削除時の差分管理を容易にする。
# 注意: ポリシー ARN に * リソースを含むポリシーは使用禁止（CLAUDE.md 禁止事項参照）。
resource "aws_iam_role_policy_attachment" "additional" {
  for_each = toset(var.additional_policy_arns)

  role       = aws_iam_role.lambda.name
  policy_arn = each.value
}

# ── 5. Lambda 関数 ────────────────────────────────────────────

resource "aws_lambda_function" "this" {
  function_name = var.function_name
  role          = aws_iam_role.lambda.arn

  # publish = true が必須: バージョン番号を発行することで aws_lambda_alias が
  # function_version を参照できるようになる。false のままだと $LATEST しか存在せず、
  # エイリアスの Weighted Routing（カナリアデプロイ）が使用できない。
  publish = true

  # S3 経由のデプロイ: s3_bucket + s3_key + source_code_hash の組み合わせで
  # コードの変更を検知する。source_code_hash が変わった場合のみ Lambda が更新される。
  s3_bucket        = aws_s3_object.lambda_zip.bucket
  s3_key           = aws_s3_object.lambda_zip.key
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  handler     = var.handler
  runtime     = var.runtime
  timeout     = var.timeout
  memory_size = var.memory_size

  # arm64（Graviton2）アーキテクチャ: x86_64 比で約 20% のコスト削減・性能向上が見込める。
  # Python ランタイムは arm64 完全対応済み。
  architectures = ["arm64"]

  # 予約済み同時実行数: -1 はアカウントプールから使用（デフォルト）。
  # ダウンストリームのスロットリング防止やコスト制御が必要な場合に明示的に設定する。
  reserved_concurrent_executions = var.reserved_concurrent_executions

  # Powertools レイヤー（SSM から取得）＋ 追加レイヤーをマージして適用する
  layers = local.all_layers

  environment {
    variables = local.merged_env_vars
  }

  # X-Ray アクティブトレーシング: 全リクエストをサンプリングしてトレースを記録する。
  # PassThrough はリクエストの一部のみトレースするが、Active は全件記録で問題診断に有効。
  tracing_config {
    mode = "Active"
  }

  # CloudWatch Logs グループを先に作成してから Lambda を作成する。
  # これにより、Lambda が自動生成するロググループと競合せず保持期間設定が確実に適用される。
  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy_attachment.basic_execution,
  ]

  tags = var.common_tags
}

# ── 6. Lambda エイリアス（live）─────────────────────────────

# live エイリアスはカナリアデプロイのエントリーポイントとなる。
# 通常運用時は現在の $LATEST バージョンを指すが、カナリアリリース時は
# routing_config.additional_version_weights で新バージョンへのトラフィック割合を制御する。
# イベントソースマッピング（ESM）はこのエイリアス ARN を参照することで、
# デプロイ時のトラフィック制御を ESM レベルで透過的に行える。
resource "aws_lambda_alias" "live" {
  name        = "live"
  description = "本番トラフィックを受け付けるエイリアス。カナリアデプロイ時に routing_config を追加する。"

  function_name    = aws_lambda_function.this.function_name
  function_version = aws_lambda_function.this.version

  # Weighted Routing プレースホルダー:
  # カナリアデプロイ時は以下をアンコメントして新バージョンに 10% を流す。
  #
  # routing_config {
  #   additional_version_weights = {
  #     "<new_version_number>" = 0.1
  #   }
  # }
}

# ── 7. 非同期呼び出し設定 ────────────────────────────────────

# S3 トリガーや SNS からの非同期呼び出し時のリトライ・保持ポリシーを設定する。
# qualifier に live エイリアスを指定することで、エイリアス経由の呼び出しに設定が適用される。
resource "aws_lambda_function_event_invoke_config" "this" {
  function_name = aws_lambda_function.this.function_name
  qualifier     = aws_lambda_alias.live.name

  # 最大リトライ回数: 2回（Lambda のデフォルト上限）
  # 失敗時は指数バックオフ（1分・2分）でリトライされる。
  # 全リトライ失敗後は DLQ へ移動するか、on_failure destination へルーティングする。
  maximum_retry_attempts = 2

  # 最大イベント保持時間: 21600秒（6時間）
  # Lambda キューにイベントが滞留できる最大時間。
  # この時間を超えたイベントは破棄されるため、DLQ との組み合わせで損失を防ぐ。
  maximum_event_age_in_seconds = 21600
}
