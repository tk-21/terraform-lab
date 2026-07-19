variable "instance_name" {
  description = "EC2インスタンスの名前（IAMロール・SGの命名にも使用）"
  type        = string
}

variable "vpc_id" {
  description = "EC2を配置するVPCのID"
  type        = string
}

variable "subnet_id" {
  description = "EC2を配置するプライベートサブネットのID"
  type        = string
}

variable "tags" {
  description = "リソースに付与する共通タグ"
  type        = map(string)
  default     = {}
}
