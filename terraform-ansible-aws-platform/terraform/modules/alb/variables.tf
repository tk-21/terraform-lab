variable "project" {
  type        = string
  description = "プロジェクト名（リソース命名に使用）"
}

variable "environment" {
  type        = string
  description = "環境名（dev / stg / prod）"
}

variable "vpc_id" {
  type        = string
  description = "ALBおよびTarget Groupを配置するVPCのID"
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "ALBを配置するパブリックサブネットIDのリスト（2AZ分）"
}

variable "alb_sg_id" {
  type        = string
  description = "ALBに適用するセキュリティグループID"
}

variable "app_instance_ids" {
  type        = list(string)
  description = "Target Groupに登録するAppサーバーのEC2インスタンスIDリスト"
}
