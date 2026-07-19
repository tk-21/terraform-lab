# ────────────────────────────────────────────────
# vLLM モデルキャッシュ S3 バケット
# ────────────────────────────────────────────────

resource "aws_s3_bucket" "model_cache" {
  # HuggingFaceからDLしたモデル重みを保存するバケット
  # EBSより安価で、複数ノード間でinitContainerを通じて共有できる
  bucket = "${local.name_prefix}-model-cache-${data.aws_caller_identity.current.account_id}"

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-model-cache"
    Purpose = "vllm-model-weights"
  })
}

resource "aws_s3_bucket_versioning" "model_cache" {
  bucket = aws_s3_bucket.model_cache.id
  versioning_configuration {
    # モデルバージョン管理: 誤削除時のロールバックと複数モデルバージョンの管理のため
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "model_cache" {
  bucket = aws_s3_bucket.model_cache.id
  rule {
    apply_server_side_encryption_by_default {
      # SSE-S3ではなくSSE-KMSを使用: 鍵ローテーションとCloudTrailによるアクセス監査のため
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "model_cache" {
  # モデル重みは機密データではないが、パブリックアクセスはVPC Endpoint経由のみで十分なため遮断する
  bucket                  = aws_s3_bucket.model_cache.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# S3へのアクセスをVPC Endpoint経由のみに制限するバケットポリシー
data "aws_iam_policy_document" "model_cache_bucket_policy" {
  statement {
    sid    = "DenyNonVPCEndpointAccess"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.model_cache.arn,
      "${aws_s3_bucket.model_cache.arn}/*",
    ]
    condition {
      test     = "StringNotEquals"
      variable = "aws:SourceVpce"
      # S3 Gateway Endpoint経由のアクセスのみを許可: NAT GW不要でVPC外への通信を排除する
      values = [var.s3_vpc_endpoint_id]
    }
  }
}

resource "aws_s3_bucket_policy" "model_cache" {
  bucket = aws_s3_bucket.model_cache.id
  policy = data.aws_iam_policy_document.model_cache_bucket_policy.json
}

# ────────────────────────────────────────────────
# vLLM IRSA: S3モデルキャッシュへの読み取り権限
# ────────────────────────────────────────────────

data "aws_iam_policy_document" "vllm_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${aws_iam_openid_connect_provider.eks.url}:sub"
      # ai-inferenceネームスペースのvllm-saサービスアカウントのみが引き受け可能
      values = ["system:serviceaccount:ai-inference:vllm-sa"]
    }
    condition {
      test     = "StringEquals"
      variable = "${aws_iam_openid_connect_provider.eks.url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "vllm_irsa" {
  # 64文字制限: "eks-ai-inf-dev-vllm-s3-irsa" = 28文字
  name               = "${local.name_prefix}-vllm-s3-irsa"
  assume_role_policy = data.aws_iam_policy_document.vllm_assume_role.json

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vllm-s3-irsa"
  })
}

data "aws_iam_policy_document" "vllm_s3_access" {
  statement {
    sid    = "ReadModelCache"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    # モデルキャッシュバケットのみに限定 (最小権限: 書き込みは不要)
    resources = [
      aws_s3_bucket.model_cache.arn,
      "${aws_s3_bucket.model_cache.arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "vllm_s3_access" {
  name   = "${local.name_prefix}-vllm-s3-policy"
  role   = aws_iam_role.vllm_irsa.id
  policy = data.aws_iam_policy_document.vllm_s3_access.json
}
