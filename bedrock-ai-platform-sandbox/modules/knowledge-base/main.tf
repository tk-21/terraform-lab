locals {
  name_prefix = "${var.project}-${var.environment}"
  # pgvector 初期化 SQL（Titan Text Embeddings V2: 1024次元）
  init_sql = [
    "CREATE EXTENSION IF NOT EXISTS vector",
    "CREATE SCHEMA IF NOT EXISTS bedrock_integration",
    <<-SQL
      CREATE TABLE IF NOT EXISTS bedrock_integration.bedrock_kb (
        id        uuid PRIMARY KEY,
        embedding vector(${var.vector_dimensions}),
        chunks    text,
        metadata  json
      )
    SQL
    ,
    "CREATE INDEX IF NOT EXISTS bedrock_kb_embedding_idx ON bedrock_integration.bedrock_kb USING hnsw (embedding vector_cosine_ops)",
    # Bedrock Knowledge Bases の RDS ストレージ検証で必須となる全文検索インデックス。
    "CREATE INDEX IF NOT EXISTS bedrock_kb_chunks_fts_idx ON bedrock_integration.bedrock_kb USING gin (to_tsvector('simple', chunks))",
  ]
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# -----------------------------------------------------------------
# S3 Bucket: ナレッジベース用ドキュメント格納
# -----------------------------------------------------------------
resource "aws_s3_bucket" "documents" {
  bucket        = "${local.name_prefix}-kb-docs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name = "${local.name_prefix}-kb-documents"
  }
}

resource "aws_s3_bucket_versioning" "documents" {
  bucket = aws_s3_bucket.documents.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "documents" {
  bucket = aws_s3_bucket.documents.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "documents" {
  bucket = aws_s3_bucket.documents.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "documents" {
  bucket = aws_s3_bucket.documents.id

  rule {
    id     = "move-to-ia"
    status = "Enabled"

    # 空のフィルターはバケット内の全オブジェクトを対象にする。
    filter {}

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
  }
}

# Bedrock がバケットにアクセスできるバケットポリシー
resource "aws_s3_bucket_policy" "documents" {
  bucket = aws_s3_bucket.documents.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowBedrockKBRead"
        Effect = "Allow"
        Principal = {
          Service = "bedrock.amazonaws.com"
        }
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.documents.arn,
          "${aws_s3_bucket.documents.arn}/*",
        ]
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

# -----------------------------------------------------------------
# Aurora PostgreSQL Serverless v2 (pgvector)
# -----------------------------------------------------------------

resource "aws_db_subnet_group" "aurora" {
  name        = "${local.name_prefix}-aurora-subnet-group"
  description = "Subnet group for Aurora pgvector cluster"
  subnet_ids  = var.private_subnet_ids

  tags = {
    Name = "${local.name_prefix}-aurora-subnet-group"
  }
}

resource "aws_security_group" "aurora" {
  name        = "${local.name_prefix}-aurora-sg"
  description = "Security group for Aurora pgvector cluster"
  vpc_id      = var.vpc_id

  ingress {
    description = "PostgreSQL from VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr_block]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-aurora-sg"
  }
}

resource "aws_rds_cluster" "main" {
  cluster_identifier = "${local.name_prefix}-aurora-pgvector"
  engine             = "aurora-postgresql"
  engine_version     = var.aurora_engine_version
  engine_mode        = "provisioned"

  database_name               = var.db_name
  master_username             = var.db_master_username
  manage_master_user_password = true # AWS Secrets Manager で自動管理

  serverlessv2_scaling_configuration {
    min_capacity = var.aurora_min_acu
    max_capacity = var.aurora_max_acu
  }

  db_subnet_group_name   = aws_db_subnet_group.aurora.name
  vpc_security_group_ids = [aws_security_group.aurora.id]

  # RDS Data API: Bedrock KB が Aurora に接続するために必須
  enable_http_endpoint = true

  storage_encrypted       = true
  deletion_protection     = false # dev 環境
  skip_final_snapshot     = true
  apply_immediately       = true
  backup_retention_period = 1
  copy_tags_to_snapshot   = true

  enabled_cloudwatch_logs_exports = ["postgresql"]

  tags = {
    Name = "${local.name_prefix}-aurora-pgvector"
  }
}

resource "aws_rds_cluster_instance" "main" {
  identifier         = "${local.name_prefix}-aurora-pgvector-1"
  cluster_identifier = aws_rds_cluster.main.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.main.engine
  engine_version     = aws_rds_cluster.main.engine_version

  apply_immediately            = true
  auto_minor_version_upgrade   = true
  performance_insights_enabled = true

  tags = {
    Name = "${local.name_prefix}-aurora-pgvector-1"
  }
}

# -----------------------------------------------------------------
# pgvector スキーマ初期化
# terraform_data は Terraform 1.4+ 組み込み（追加プロバイダー不要）
# RDS Data API を利用して SQL を実行
# -----------------------------------------------------------------
resource "terraform_data" "aurora_init" {
  # クラスター再作成時、またはスキーマ定義変更時に再実行する。
  triggers_replace = [
    aws_rds_cluster.main.cluster_identifier,
    sha256(join("\n", local.init_sql)),
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      REGION="${data.aws_region.current.name}"
      CLUSTER_ARN="${aws_rds_cluster.main.arn}"
      SECRET_ARN="${aws_rds_cluster.main.master_user_secret[0].secret_arn}"
      DB="${var.db_name}"

      echo "Waiting for Aurora cluster to be available..."
      aws rds wait db-cluster-available \
        --db-cluster-identifier "${aws_rds_cluster.main.cluster_identifier}" \
        --region "$REGION"

      echo "Initializing pgvector schema..."
      for SQL in \
        "CREATE EXTENSION IF NOT EXISTS vector" \
        "CREATE SCHEMA IF NOT EXISTS bedrock_integration" \
        "CREATE TABLE IF NOT EXISTS bedrock_integration.bedrock_kb (id uuid PRIMARY KEY, embedding vector(${var.vector_dimensions}), chunks text, metadata json)" \
        "CREATE INDEX IF NOT EXISTS bedrock_kb_embedding_idx ON bedrock_integration.bedrock_kb USING hnsw (embedding vector_cosine_ops)" \
        "CREATE INDEX IF NOT EXISTS bedrock_kb_chunks_fts_idx ON bedrock_integration.bedrock_kb USING gin (to_tsvector('simple', chunks))"
      do
        aws rds-data execute-statement \
          --resource-arn "$CLUSTER_ARN" \
          --secret-arn   "$SECRET_ARN" \
          --database     "$DB" \
          --sql          "$SQL" \
          --region       "$REGION"
        echo "OK: $SQL"
      done

      echo "pgvector initialization complete."
    EOT
  }

  depends_on = [aws_rds_cluster_instance.main]
}

# -----------------------------------------------------------------
# IAM Role for Bedrock Knowledge Base
# -----------------------------------------------------------------
resource "aws_iam_role" "bedrock_kb" {
  name        = "${local.name_prefix}-bedrock-kb-role"
  description = "Role for Amazon Bedrock Knowledge Base"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowBedrockAssume"
        Effect = "Allow"
        Principal = {
          Service = "bedrock.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:aws:bedrock:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:knowledge-base/*"
          }
        }
      }
    ]
  })

  tags = {
    Name = "${local.name_prefix}-bedrock-kb-role"
  }
}

resource "aws_iam_policy" "bedrock_kb" {
  name        = "${local.name_prefix}-bedrock-kb-policy"
  description = "Policy for Bedrock Knowledge Base: S3, embedding model, Aurora Data API"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowS3DocumentsRead"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.documents.arn,
          "${aws_s3_bucket.documents.arn}/*",
        ]
        Condition = {
          StringEquals = {
            "aws:ResourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid      = "AllowEmbeddingModel"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = [var.embedding_model_arn]
      },
      {
        Sid    = "AllowAuroraDataAPI"
        Effect = "Allow"
        Action = [
          "rds-data:ExecuteStatement",
          "rds-data:BatchExecuteStatement",
        ]
        Resource = [aws_rds_cluster.main.arn]
      },
      {
        # Bedrock Knowledge Bases が RDS ベクトルストアの接続情報を検証するために必要
        Sid      = "AllowDescribeAuroraCluster"
        Effect   = "Allow"
        Action   = ["rds:DescribeDBClusters"]
        Resource = [aws_rds_cluster.main.arn]
      },
      {
        Sid      = "AllowAuroraSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_rds_cluster.main.master_user_secret[0].secret_arn]
      }
    ]
  })

  tags = {
    Name = "${local.name_prefix}-bedrock-kb-policy"
  }
}

resource "aws_iam_role_policy_attachment" "bedrock_kb" {
  role       = aws_iam_role.bedrock_kb.name
  policy_arn = aws_iam_policy.bedrock_kb.arn
}

# -----------------------------------------------------------------
# Bedrock Knowledge Base
# aurora_init 完了後に作成
# -----------------------------------------------------------------
resource "aws_bedrockagent_knowledge_base" "main" {
  name        = "${local.name_prefix}-kb"
  description = "RAG knowledge base backed by Aurora pgvector"
  role_arn    = aws_iam_role.bedrock_kb.arn

  knowledge_base_configuration {
    type = "VECTOR"
    vector_knowledge_base_configuration {
      embedding_model_arn = var.embedding_model_arn
    }
  }

  storage_configuration {
    type = "RDS"
    rds_configuration {
      resource_arn           = aws_rds_cluster.main.arn
      database_name          = var.db_name
      table_name             = "bedrock_integration.bedrock_kb"
      credentials_secret_arn = aws_rds_cluster.main.master_user_secret[0].secret_arn

      field_mapping {
        primary_key_field = "id"
        vector_field      = "embedding"
        text_field        = "chunks"
        metadata_field    = "metadata"
      }
    }
  }

  tags = {
    Name = "${local.name_prefix}-kb"
  }

  # Aurora のスキーマ初期化と、Bedrock サービスロールへの権限付与後に作成する。
  depends_on = [
    terraform_data.aurora_init,
    aws_iam_role_policy_attachment.bedrock_kb,
  ]
}

# -----------------------------------------------------------------
# S3 Data Source: ドキュメントを KB に同期
# -----------------------------------------------------------------
resource "aws_bedrockagent_data_source" "s3" {
  knowledge_base_id = aws_bedrockagent_knowledge_base.main.id
  name              = "${local.name_prefix}-kb-s3-docs"
  description       = "S3 document source for knowledge base ingestion"

  data_source_configuration {
    type = "S3"
    s3_configuration {
      bucket_arn = aws_s3_bucket.documents.arn
    }
  }

  vector_ingestion_configuration {
    chunking_configuration {
      chunking_strategy = "FIXED_SIZE"
      fixed_size_chunking_configuration {
        max_tokens         = var.chunk_max_tokens
        overlap_percentage = var.chunk_overlap_percentage
      }
    }
  }
}
