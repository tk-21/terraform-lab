variable "prefix" {
  description = "リソース名プレフィックス"
  type        = string
  default     = "ecl"
}

variable "env" {
  description = "環境名"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "account_id" {
  description = "AWSアカウントID (terraform.tfvars で設定)"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR ブロック (chaos-engineering-lab の 10.0.x と競合しない)"
  type        = string
  default     = "10.1.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "パブリックサブネット CIDR リスト"
  type        = list(string)
  default     = ["10.1.1.0/24", "10.1.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "プライベートサブネット CIDR リスト"
  type        = list(string)
  default     = ["10.1.11.0/24", "10.1.12.0/24"]
}

variable "availability_zones" {
  description = "使用するアベイラビリティゾーン"
  type        = list(string)
  default     = ["ap-northeast-1a", "ap-northeast-1c"]
}

variable "ecs_task_cpu" {
  description = "ECS タスク CPU ユニット (256 = 0.25 vCPU)"
  type        = number
  default     = 256
}

variable "ecs_task_memory" {
  description = "ECS タスクメモリ (MB)"
  type        = number
  default     = 512
}

variable "ecs_desired_count" {
  description = "ECS サービスの希望タスク数"
  type        = number
  default     = 2
}

variable "container_port" {
  description = "コンテナが Listen するポート番号"
  type        = number
  default     = 80
}
