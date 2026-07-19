locals {
  prefix = "${var.project}-${var.env}"

  common_tags = {
    Project     = var.project
    Environment = var.env
    ManagedBy   = "terraform"
  }
}

# =============================================================================
# Lambda@Edge: viewer_request
# =============================================================================
# Lambda@Edge の制約:
#   - us-east-1 でのみ作成・publish できる（このモジュールは aws.use1 で呼ばれる）
#   - 環境変数が使えないため、SSM Secret をデプロイ時にソースコードへ埋め込む
#   - arm64 非対応（x86_64 のみ）
#   - タイムアウト上限 5 秒 / メモリ上限 128 MB (viewer request)
#   - publish = true が必須（CloudFront は qualified ARN を要求する）

# viewer_request.js 内の "__REPLACE_AT_DEPLOY__" を cloudfront_secret の値で置換して
# .build/ ディレクトリに書き出す。local_file リソースはデプロイ時に実行される。
resource "local_file" "viewer_request_embedded" {
  content = replace(
    file("${path.module}/../../../lambda/edge/viewer_request.js"),
    "__REPLACE_AT_DEPLOY__",
    var.cloudfront_secret
  )
  filename = "${path.module}/.build/viewer_request.js"
}

data "archive_file" "viewer_request" {
  type        = "zip"
  source_file = local_file.viewer_request_embedded.filename
  output_path = "${path.module}/.build/viewer_request.zip"
  depends_on  = [local_file.viewer_request_embedded]
}

resource "aws_iam_role" "lambda_edge" {
  # Lambda@Edge は lambda.amazonaws.com と edgelambda.amazonaws.com の両方が必要
  name = "${local.prefix}-lambda-edge-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = ["lambda.amazonaws.com", "edgelambda.amazonaws.com"]
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "lambda_edge_logs" {
  role       = aws_iam_role.lambda_edge.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "viewer_request" {
  function_name    = "${local.prefix}-viewer-request"
  runtime          = "nodejs20.x"
  architectures    = ["x86_64"] # Lambda@Edge は arm64 非対応
  handler          = "viewer_request.handler"
  role             = aws_iam_role.lambda_edge.arn
  filename         = data.archive_file.viewer_request.output_path
  source_code_hash = data.archive_file.viewer_request.output_base64sha256
  publish          = true # Lambda@Edge は qualified ARN（バージョン付き）が必須
  timeout          = 5
  memory_size      = 128

  tags = local.common_tags
}

# =============================================================================
# CloudFront ディストリビューション
# =============================================================================

resource "aws_cloudfront_distribution" "main" {
  enabled         = true
  is_ipv6_enabled = true
  price_class     = "PriceClass_100" # 北米・欧州・アジア (コスト最適化)
  comment         = "${local.prefix} distribution"
  aliases         = [var.domain_name]

  # WAF WebACL をアタッチ: CLOUDFRONT スコープで作成した WebACL の ARN を指定
  web_acl_id = var.webacl_arn

  # ===========================================================================
  # オリジン設定 (ALB)
  # ===========================================================================

  origin {
    domain_name = var.alb_dns_name
    origin_id   = "alb-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only" # オリジンへは必ず HTTPS
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    # CloudFront からのアクセスであることを ALB が検証するためのカスタムヘッダー。
    # Phase 4 で ALB リスナールールにこのヘッダーの検証を追加して
    # CloudFront をバイパスした直接アクセスを拒否する。
    custom_header {
      name  = "X-CloudFront-Secret"
      value = var.cloudfront_secret
    }
  }

  # ===========================================================================
  # デフォルトキャッシュ動作
  # ===========================================================================

  default_cache_behavior {
    target_origin_id       = "alb-origin"
    viewer_protocol_policy = "redirect-to-https"

    # 動的コンテンツ (API / フォーム送信) を想定して全メソッドを許可
    allowed_methods = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods  = ["GET", "HEAD"]

    # ALB への動的リクエストはキャッシュしない: TTL をすべて 0 に設定
    forwarded_values {
      query_string = true
      # Host: ALB のバーチャルホスト判別に必須
      # Authorization: API 認証ヘッダーをオリジンに転送
      # CloudFront-Viewer-Country: Lambda@Edge / WAF での地理制限に使用
      headers = ["Host", "Authorization", "CloudFront-Viewer-Country"]

      cookies {
        forward = "all"
      }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0

    # viewer_request: CloudFront がオリジンへ転送する前にカスタムヘッダーを検証する
    lambda_function_association {
      event_type   = "viewer-request"
      lambda_arn   = aws_lambda_function.viewer_request.qualified_arn
      include_body = false
    }
  }

  # ===========================================================================
  # 地理制限 (Phase 4 で Lambda@Edge に移行)
  # ===========================================================================

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # ===========================================================================
  # SSL/TLS 設定
  # ===========================================================================

  viewer_certificate {
    acm_certificate_arn      = var.acm_certificate_arn_use1
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = local.common_tags
}

# =============================================================================
# Route53 レコード (CloudFront ドメイン → カスタムドメイン)
# =============================================================================

data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

resource "aws_route53_record" "cloudfront" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}
