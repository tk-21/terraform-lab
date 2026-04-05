# terraform/modules/api-gateway/main.tf
#
# API Gateway REST API の実装。
# REST API (v1) を選択した理由:
#   HTTP API (v2) の方が安価だが、リクエストボディの JSON スキーマバリデーション、
#   Cognito オーソライザー TTL 設定、詳細なアクセスログ等は REST API にしかない。
#   詳細は docs/adr/003-rest-vs-http-api.md を参照。

data "aws_region" "current" {}

locals {
  # Cognito オーソライザーを使用するかどうか（dev では null → NONE）
  use_cognito   = var.cognito_user_pool_arn != null
  auth_type     = local.use_cognito ? "COGNITO_USER_POOLS" : "NONE"
  authorizer_id = local.use_cognito ? aws_api_gateway_authorizer.cognito[0].id : null
}

# ============================================================
# 1. REST API 本体
# ============================================================
resource "aws_api_gateway_rest_api" "this" {
  name        = "${var.prefix}-api"
  description = "Serverless API Platform REST API (${var.environment})"

  # REGIONAL エンドポイントを選択した理由:
  # EDGE（CloudFront 経由）より REGIONAL の方がレイテンシが低い。
  # 同一リージョンのクライアントが多い場合は REGIONAL を推奨。
  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = var.tags
}

# ============================================================
# 2. リソース定義
# ============================================================
resource "aws_api_gateway_resource" "items" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "items"
}

resource "aws_api_gateway_resource" "item" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.items.id
  path_part   = "{id}"
}

# ============================================================
# 3. Cognito オーソライザー
# ============================================================
# Cognito の JWT トークン検証を API Gateway に委譲する。
# Lambda 側でトークン検証を実装してはならない（CLAUDE.md の禁止事項）。
# API Gateway が Authorization ヘッダーの JWT を検証し、
# 不正なトークンには 401 を返す（Lambda は呼ばれない）。
resource "aws_api_gateway_authorizer" "cognito" {
  count = local.use_cognito ? 1 : 0

  name          = "${var.prefix}-cognito-authorizer"
  rest_api_id   = aws_api_gateway_rest_api.this.id
  type          = "COGNITO_USER_POOLS"
  provider_arns = [var.cognito_user_pool_arn]

  # Authorization ヘッダーから JWT を取得する
  identity_source = "method.request.header.Authorization"

  # 検証結果を 300 秒（5分）キャッシュする。
  # キャッシュにより同一トークンの繰り返し検証を省略し、レイテンシを低減する。
  # セキュリティ上問題はない（トークンは秒単位で検証される）。
  authorizer_result_ttl_in_seconds = var.authorizer_ttl
}

# ============================================================
# 4. リクエストバリデーター
# ============================================================
# API Gateway がリクエストボディの JSON スキーマ検証を行う。
# Lambda が呼ばれる前に検証するため、無効なリクエストの Lambda コスト（起動費用）を削減できる。
resource "aws_api_gateway_request_validator" "body" {
  rest_api_id           = aws_api_gateway_rest_api.this.id
  name                  = "${var.prefix}-body-validator"
  validate_request_body = true
  # パスパラメータ・クエリパラメータの検証は Lambda で行うため false
  validate_request_parameters = false
}

# ============================================================
# 5. リクエストモデル（JSON スキーマ）
# ============================================================
# POST /items リクエストボディのスキーマ定義
resource "aws_api_gateway_model" "create_item" {
  rest_api_id  = aws_api_gateway_rest_api.this.id
  name         = "CreateItemRequest"
  content_type = "application/json"

  schema = jsonencode({
    "$schema" = "http://json-schema.org/draft-04/schema#"
    type      = "object"
    # name は必須フィールド
    required = ["name"]
    properties = {
      name = {
        type      = "string"
        minLength = 1
        maxLength = 100
      }
      description = {
        type      = "string"
        maxLength = 1000
      }
      # expires_days は整数・1〜365 の範囲のみ許容
      expires_days = {
        type    = "integer"
        minimum = 1
        maximum = 365
      }
    }
    # 未定義フィールドの追加を拒否する（意図しないデータの混入防止）
    additionalProperties = false
  })
}

# PUT /items/{id} リクエストボディのスキーマ定義（部分更新なので required なし）
resource "aws_api_gateway_model" "update_item" {
  rest_api_id  = aws_api_gateway_rest_api.this.id
  name         = "UpdateItemRequest"
  content_type = "application/json"

  schema = jsonencode({
    "$schema" = "http://json-schema.org/draft-04/schema#"
    type      = "object"
    # 部分更新: 全フィールドが任意（最低1フィールドの検証は Lambda 側で実施）
    properties = {
      name = {
        type      = "string"
        minLength = 1
        maxLength = 100
      }
      description = {
        type      = "string"
        maxLength = 1000
      }
      status = {
        type = "string"
        # Lambda の ItemUpdate モデル（Literal["ACTIVE","ARCHIVED"]）と一致させる
        enum = ["ACTIVE", "ARCHIVED"]
      }
    }
    additionalProperties = false
  })
}

# ============================================================
# 6. OPTIONS /items（CORS プリフライトリクエスト）
# ============================================================
# ブラウザは cross-origin リクエストの前に OPTIONS メソッドで CORS 確認を行う。
# MOCK 統合を使用して Lambda を呼ばずに CORS ヘッダーを返す（コスト削減）。
#
# TODO(STEP 10): カスタムドメイン設定後、Access-Control-Allow-Origin を
#               特定ドメインに制限すること（例: https://your-domain.com）。
resource "aws_api_gateway_method" "options_items" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.items.id
  http_method   = "OPTIONS"
  authorization = "NONE" # CORS プリフライトは認証不要
}

resource "aws_api_gateway_integration" "options_items" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.items.id
  http_method = aws_api_gateway_method.options_items.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = jsonencode({ statusCode = 200 })
  }
}

resource "aws_api_gateway_method_response" "options_items_200" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.items.id
  http_method = aws_api_gateway_method.options_items.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }

  response_models = {
    "application/json" = "Empty"
  }
}

resource "aws_api_gateway_integration_response" "options_items" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.items.id
  http_method = aws_api_gateway_method.options_items.http_method
  status_code = aws_api_gateway_method_response.options_items_200.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization,X-Amz-Date'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,OPTIONS'"
    # TODO(STEP 10): カスタムドメイン設定後に特定ドメインへ制限する
    "method.response.header.Access-Control-Allow-Origin" = "'*'"
  }

  depends_on = [aws_api_gateway_integration.options_items]
}

# ============================================================
# 7. GET /items → list-items Lambda
# ============================================================
resource "aws_api_gateway_method" "get_items" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.items.id
  http_method   = "GET"
  authorization = local.auth_type
  authorizer_id = local.authorizer_id
}

resource "aws_api_gateway_integration" "get_items" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.items.id
  http_method             = aws_api_gateway_method.get_items.http_method
  type                    = "AWS_PROXY"
  # Lambda は HTTP メソッドに関わらず常に POST で呼び出す（AWS 仕様）
  integration_http_method = "POST"
  uri                     = var.lambda_invoke_arns["list_items"]
}

# ============================================================
# 8. POST /items → create-item Lambda（リクエストバリデーション付き）
# ============================================================
resource "aws_api_gateway_method" "post_items" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.items.id
  http_method   = "POST"
  authorization = local.auth_type
  authorizer_id = local.authorizer_id

  # API Gateway がボディを JSON スキーマで検証する。
  # Lambda が呼ばれる前に無効リクエストを弾き、起動コストを削減する。
  request_validator_id = aws_api_gateway_request_validator.body.id
  request_models = {
    "application/json" = aws_api_gateway_model.create_item.name
  }
}

resource "aws_api_gateway_integration" "post_items" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.items.id
  http_method             = aws_api_gateway_method.post_items.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = var.lambda_invoke_arns["create_item"]
}

# ============================================================
# 9. OPTIONS /items/{id}（CORS プリフライトリクエスト）
# ============================================================
resource "aws_api_gateway_method" "options_item" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.item.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "options_item" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.item.id
  http_method = aws_api_gateway_method.options_item.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = jsonencode({ statusCode = 200 })
  }
}

resource "aws_api_gateway_method_response" "options_item_200" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.item.id
  http_method = aws_api_gateway_method.options_item.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }

  response_models = {
    "application/json" = "Empty"
  }
}

resource "aws_api_gateway_integration_response" "options_item" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.item.id
  http_method = aws_api_gateway_method.options_item.http_method
  status_code = aws_api_gateway_method_response.options_item_200.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization,X-Amz-Date'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,PUT,DELETE,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }

  depends_on = [aws_api_gateway_integration.options_item]
}

# ============================================================
# 10. GET /items/{id} → get-item Lambda
# ============================================================
resource "aws_api_gateway_method" "get_item" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.item.id
  http_method   = "GET"
  authorization = local.auth_type
  authorizer_id = local.authorizer_id
}

resource "aws_api_gateway_integration" "get_item" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.item.id
  http_method             = aws_api_gateway_method.get_item.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = var.lambda_invoke_arns["get_item"]
}

# ============================================================
# 11. PUT /items/{id} → update-item Lambda（リクエストバリデーション付き）
# ============================================================
resource "aws_api_gateway_method" "put_item" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.item.id
  http_method   = "PUT"
  authorization = local.auth_type
  authorizer_id = local.authorizer_id

  request_validator_id = aws_api_gateway_request_validator.body.id
  request_models = {
    "application/json" = aws_api_gateway_model.update_item.name
  }
}

resource "aws_api_gateway_integration" "put_item" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.item.id
  http_method             = aws_api_gateway_method.put_item.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = var.lambda_invoke_arns["update_item"]
}

# ============================================================
# 12. DELETE /items/{id} → delete-item Lambda
# ============================================================
resource "aws_api_gateway_method" "delete_item" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.item.id
  http_method   = "DELETE"
  authorization = local.auth_type
  authorizer_id = local.authorizer_id
}

resource "aws_api_gateway_integration" "delete_item" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.item.id
  http_method             = aws_api_gateway_method.delete_item.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = var.lambda_invoke_arns["delete_item"]
}

# ============================================================
# 13. Lambda invoke 権限
# ============================================================
# API Gateway から各 Lambda を呼び出すための許可設定。
# source_arn を execution_arn/*/* に制限することで、
# このAPIからの呼び出しのみを許可する（他の API GW からは呼べない）。
resource "aws_lambda_permission" "list_items" {
  statement_id  = "AllowAPIGatewayInvoke-${var.prefix}-list-items"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_arns["list_items"]
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
}

resource "aws_lambda_permission" "create_item" {
  statement_id  = "AllowAPIGatewayInvoke-${var.prefix}-create-item"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_arns["create_item"]
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
}

resource "aws_lambda_permission" "get_item" {
  statement_id  = "AllowAPIGatewayInvoke-${var.prefix}-get-item"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_arns["get_item"]
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
}

resource "aws_lambda_permission" "update_item" {
  statement_id  = "AllowAPIGatewayInvoke-${var.prefix}-update-item"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_arns["update_item"]
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
}

resource "aws_lambda_permission" "delete_item" {
  statement_id  = "AllowAPIGatewayInvoke-${var.prefix}-delete-item"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_arns["delete_item"]
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
}

# ============================================================
# 14. デプロイメント
# ============================================================
# triggers ハッシュに統合 URI とモデルスキーマを含めることで、
# Lambda ARN の変更やスキーマ変更時も確実に再デプロイされる。
resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeployment = sha1(jsonencode({
      # リソース
      resources = [
        aws_api_gateway_resource.items.id,
        aws_api_gateway_resource.item.id,
      ]
      # メソッド（認証設定の変更を検知）
      methods = [
        aws_api_gateway_method.get_items.authorization,
        aws_api_gateway_method.post_items.authorization,
        aws_api_gateway_method.get_item.authorization,
        aws_api_gateway_method.put_item.authorization,
        aws_api_gateway_method.delete_item.authorization,
      ]
      # 統合 URI（Lambda ARN 変更時に再デプロイ）
      integrations = [
        aws_api_gateway_integration.get_items.uri,
        aws_api_gateway_integration.post_items.uri,
        aws_api_gateway_integration.get_item.uri,
        aws_api_gateway_integration.put_item.uri,
        aws_api_gateway_integration.delete_item.uri,
      ]
      # モデルスキーマ（バリデーション変更時に再デプロイ）
      models = [
        aws_api_gateway_model.create_item.schema,
        aws_api_gateway_model.update_item.schema,
      ]
      # オーソライザー（Cognito 設定変更時に再デプロイ）
      authorizer = local.use_cognito ? aws_api_gateway_authorizer.cognito[0].id : "none"
    }))
  }

  lifecycle {
    create_before_destroy = true
  }

  # 全インテグレーションの作成完了を待ってからデプロイする
  depends_on = [
    aws_api_gateway_integration.get_items,
    aws_api_gateway_integration.post_items,
    aws_api_gateway_integration.options_items,
    aws_api_gateway_integration.get_item,
    aws_api_gateway_integration.put_item,
    aws_api_gateway_integration.delete_item,
    aws_api_gateway_integration.options_item,
    aws_api_gateway_integration_response.options_items,
    aws_api_gateway_integration_response.options_item,
  ]
}

# ============================================================
# 15. CloudWatch Logs グループ（アクセスログ）
# ============================================================
resource "aws_cloudwatch_log_group" "api_gw" {
  name = "/aws/apigateway/${var.prefix}-api"
  # dev: 14日、prod: 90日を推奨（コストと監査要件のバランス）
  retention_in_days = var.log_retention_days

  tags = var.tags
}

# ============================================================
# 16. ステージ（デプロイ環境）
# ============================================================
resource "aws_api_gateway_stage" "this" {
  deployment_id = aws_api_gateway_deployment.this.id
  rest_api_id   = aws_api_gateway_rest_api.this.id
  stage_name    = var.environment

  # X-Ray アクティブトレーシング: Lambda の X-Ray と連携してエンドツーエンドのトレースを可能にする
  xray_tracing_enabled = true

  # アクセスログ: JSON 形式で CloudWatch Logs に保存する
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gw.arn
    # Cognito の sub をログに含めることで「誰が」いつアクセスしたか追跡できる
    format = jsonencode({
      requestId          = "$context.requestId"
      ip                 = "$context.identity.sourceIp"
      userAgent          = "$context.identity.userAgent"
      requestTime        = "$context.requestTime"
      httpMethod         = "$context.httpMethod"
      resourcePath       = "$context.resourcePath"
      status             = "$context.status"
      responseLength     = "$context.responseLength"
      integrationLatency = "$context.integrationLatency"
      errorMessage       = "$context.error.message"
      # Cognito JWT の sub クレーム（ユーザー識別に使用）
      cognitoUserId = "$context.authorizer.claims.sub"
    })
  }

  tags = var.tags

  # API GW アカウントの CloudWatch ロール設定が先に完了していることを保証する
  depends_on = [aws_api_gateway_account.this]
}

# ============================================================
# 17. メソッド設定（スロットリング・ログ・メトリクス）
# ============================================================
# スロットリング設定の意図:
#   - DDoS 対策: 大量リクエストによるシステム過負荷を防止する
#   - コスト上限: Lambda の無制限スケールによるコスト爆発を抑制する
#     rate_limit=1000 なら Lambda の最大同時実行は概算で ~1000 に収まる
#   - バーストリミット=500: 急激なスパイクに対して一定量まで許可し、
#     それを超えると 429 Too Many Requests を返すことでシステムを保護する
#
# prod でのチューニング指針:
#   - 正常時の peak rps × 1.5 を rate_limit に設定する
#   - burst_limit は rate_limit の 50% 程度が目安
resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  method_path = "*/*" # 全メソッドに適用

  settings {
    # リクエストレート上限（req/s）
    throttling_rate_limit = var.throttling_rate_limit
    # バーストリミット（同時処理可能な最大リクエスト数）
    throttling_burst_limit = var.throttling_burst_limit

    # INFO: リクエスト/レスポンスのヘッダーとボディをログに記録
    # prod では ERROR に変更してコスト削減を検討すること
    logging_level = "INFO"

    # リクエスト/レスポンスの本文ログは false（PII 漏洩防止のため）
    data_trace_enabled = false

    # CloudWatch メトリクス（Latency, Count, 4xx, 5xx）を有効化
    metrics_enabled = true
  }
}

# ============================================================
# 18. API Gateway アカウント設定（CloudWatch ログ用 IAM ロール）
# ============================================================
# API Gateway がアクセスログを CloudWatch Logs に書き込むには、
# アカウントレベルで IAM ロールを設定する必要がある。
# 注意: aws_api_gateway_account はアカウントに1つのみ存在する。
#       同一アカウントの別スタックと競合する可能性があるため、
#       既存の設定がある場合はこのリソースを除外し、
#       cloudwatch_role_arn を手動で設定すること。
resource "aws_api_gateway_account" "this" {
  cloudwatch_role_arn = aws_iam_role.api_gw_cloudwatch.arn
}

resource "aws_iam_role" "api_gw_cloudwatch" {
  name        = "${var.prefix}-api-gw-cw-role"
  description = "API Gateway が CloudWatch Logs にアクセスログを書き込むためのロール"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "apigateway.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

# AWS 管理ポリシーで CloudWatch Logs への書き込み権限を付与する
resource "aws_iam_role_policy_attachment" "api_gw_cloudwatch" {
  role       = aws_iam_role.api_gw_cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

# ============================================================
# 19. WAF WebACL（prod のみ）
# ============================================================
# TODO(STEP prod): WAF の実装
# enable_waf = true の場合に以下を追加する:
#   - aws_wafv2_web_acl（レートリミット・IP ブロックルール）
#   - aws_wafv2_web_acl_association（API GW ステージへのアタッチ）
#   - aws_wafv2_ip_set（allowed_ips を使用したホワイトリスト）
# dev では enable_waf = false（月額 ~$6/WebACL のコスト削減のため）
