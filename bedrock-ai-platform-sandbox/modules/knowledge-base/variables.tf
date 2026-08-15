variable "project" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where Aurora will be placed"
  type        = string
}

variable "vpc_cidr_block" {
  description = "VPC CIDR block used for Aurora security group ingress"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for Aurora subnet group (minimum 2 AZs)"
  type        = list(string)
}

variable "db_name" {
  description = "Initial database name"
  type        = string
  default     = "bedrock_kb"
}

variable "db_master_username" {
  description = "Aurora master username"
  type        = string
  default     = "dbadmin"
}

variable "aurora_engine_version" {
  description = "Aurora PostgreSQL engine version"
  type        = string
  # ap-northeast-1 で db.serverless をサポートする利用可能バージョン。
  # 利用可能な値は `aws rds describe-db-engine-versions` でリージョンごとに確認する。
  default = "16.14"
}

variable "aurora_min_acu" {
  description = "Minimum Aurora Serverless v2 ACU (cost optimization: 0.5)"
  type        = number
  default     = 0.5
}

variable "aurora_max_acu" {
  description = "Maximum Aurora Serverless v2 ACU"
  type        = number
  default     = 4.0
}

variable "embedding_model_arn" {
  description = "Bedrock embedding model ARN for Knowledge Base"
  type        = string
  default     = "arn:aws:bedrock:ap-northeast-1::foundation-model/amazon.titan-embed-text-v2:0"
}

# Titan Text Embeddings V2 のデフォルト次元数 (256 / 512 / 1024)
variable "vector_dimensions" {
  description = "Embedding vector dimensions (must match embedding model output)"
  type        = number
  default     = 1024
}

variable "chunk_max_tokens" {
  description = "Max tokens per chunk for document ingestion"
  type        = number
  default     = 512
}

variable "chunk_overlap_percentage" {
  description = "Overlap percentage between chunks"
  type        = number
  default     = 10
}
