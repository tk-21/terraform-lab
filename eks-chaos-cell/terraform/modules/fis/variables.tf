variable "cluster_name" {
  description = "EKSクラスター名（リソース命名に使用）"
  type        = string
}

variable "aws_region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "aws_account_id" {
  description = "AWSアカウントID（IAMポリシーのARN生成に使用）"
  type        = string
}

variable "common_tags" {
  description = "全リソースに付与する共通タグ"
  type        = map(string)
  default     = {}
}
