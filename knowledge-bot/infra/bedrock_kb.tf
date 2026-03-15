# KB用IAM Role（BedrockがS3/OSにアクセスするため）
data "aws_iam_policy_document" "kb_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "kb" {
  name               = "${local.name}-kb-role"
  assume_role_policy = data.aws_iam_policy_document.kb_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "kb_policy" {
  statement {
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:ListBucket"]
    resources = [
      aws_s3_bucket.knowledge.arn,
      "${aws_s3_bucket.knowledge.arn}/*"
    ]
  }

  statement {
    effect    = "Allow"
    actions   = ["aoss:APIAccessAll"]
    resources = ["*"]
  }

  statement {
    effect  = "Allow"
    actions = ["bedrock:InvokeModel"]
    resources = [
      "arn:aws:bedrock:${var.region}::foundation-model/amazon.titan-embed-text-v2:0"
    ]
  }

  # ★追加：S3(KMS暗号化)を読めるようにする
  statement {
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey"
    ]
    resources = [
      aws_kms_key.knowledge.arn
    ]
  }
}

resource "aws_iam_policy" "kb" {
  name   = "${local.name}-kb-policy"
  policy = data.aws_iam_policy_document.kb_policy.json
  tags   = local.tags
}

resource "aws_iam_role_policy_attachment" "kb" {
  role       = aws_iam_role.kb.name
  policy_arn = aws_iam_policy.kb.arn
}

resource "aws_bedrockagent_knowledge_base" "this" {
  name     = "${local.name}-kb"
  role_arn = aws_iam_role.kb.arn

  knowledge_base_configuration {
    type = "VECTOR"
    vector_knowledge_base_configuration {
      embedding_model_arn = "arn:aws:bedrock:${var.region}::foundation-model/amazon.titan-embed-text-v2:0"
    }
  }

  storage_configuration {
    type = "OPENSEARCH_SERVERLESS"
    opensearch_serverless_configuration {
      collection_arn    = aws_opensearchserverless_collection.kb.arn
      vector_index_name = "${local.name}-index"
      field_mapping {
        vector_field   = "vector"
        text_field     = "text"
        metadata_field = "metadata"
      }
    }
  }

  tags = local.tags

  depends_on = [
    opensearch_index.kb
  ]
}

resource "aws_bedrockagent_data_source" "s3" {
  knowledge_base_id = aws_bedrockagent_knowledge_base.this.id
  name              = "${local.name}-s3"

  data_source_configuration {
    type = "S3"
    s3_configuration {
      bucket_arn = aws_s3_bucket.knowledge.arn
    }
  }
}
