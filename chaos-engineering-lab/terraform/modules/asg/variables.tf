variable "prefix" {
  description = "リソース名プレフィックス（例: cel）"
  type        = string
}

variable "env" {
  description = "環境名（例: dev）"
  type        = string
}

variable "private_subnet_ids" {
  description = "ASG が EC2 インスタンスを起動するプライベートサブネット ID のリスト"
  type        = list(string)
}

variable "ec2_sg_id" {
  description = "EC2 インスタンスに適用するセキュリティグループの ID"
  type        = string
}

variable "target_group_arn" {
  description = "ASG インスタンスを登録する ALB ターゲットグループの ARN"
  type        = string
}

variable "instance_profile_name" {
  description = "EC2 インスタンスプロファイル名（SSM・CloudWatch 通信に使用、Phase 3 で設定）"
  type        = string
  default     = ""
}

variable "min_size" {
  description = "ASG の最小インスタンス数"
  type        = number
  default     = 2
}

variable "max_size" {
  description = "ASG の最大インスタンス数"
  type        = number
  default     = 6
}

variable "desired_capacity" {
  description = "ASG の希望インスタンス数"
  type        = number
  default     = 2
}

variable "tags" {
  description = "全リソースに付与する共通タグ"
  type        = map(string)
  default     = {}
}
