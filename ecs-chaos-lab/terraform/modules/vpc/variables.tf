variable "prefix" {
  description = "リソース名プレフィックス"
  type        = string
}

variable "env" {
  description = "環境名"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR ブロック"
  type        = string
}

variable "public_subnet_cidrs" {
  description = "パブリックサブネット CIDR リスト"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "プライベートサブネット CIDR リスト"
  type        = list(string)
}

variable "availability_zones" {
  description = "使用するアベイラビリティゾーン"
  type        = list(string)
}

variable "tags" {
  description = "全リソースに付与する追加タグ"
  type        = map(string)
  default     = {}
}
