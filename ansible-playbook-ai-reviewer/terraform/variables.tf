variable "aws_region" {
  description = "AWSリージョン（メインリソース用）"
  type        = string
  default     = "ap-northeast-1"
}

variable "bedrock_region" {
  description = "Amazon Bedrockのリージョン"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "デプロイ環境"
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "プロジェクト名（タグ・命名に使用）"
  type        = string
  default     = "ansible-playbook-ai-reviewer"
}

variable "github_token_ssm_path" {
  description = "GitHub TokenのSSMパラメータパス"
  type        = string
  default     = "/ansible-ai-reviewer/github-token"
}

variable "api_gateway_stage" {
  description = "API Gatewayのステージ名"
  type        = string
  default     = "v1"
}

variable "lambda_timeout" {
  description = "Lambda関数のタイムアウト（秒）"
  type        = number
  default     = 300
}

variable "lambda_memory" {
  description = "Lambda関数のメモリサイズ（MB）"
  type        = number
  default     = 512
}
