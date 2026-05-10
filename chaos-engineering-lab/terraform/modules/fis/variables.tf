variable "prefix" {
  description = "リソース名プレフィックス（例: cel）"
  type        = string
}

variable "env" {
  description = "環境名（例: dev）"
  type        = string
}

variable "fis_role_arn" {
  description = "FIS 実行ロールの ARN（iam モジュールから取得）"
  type        = string
}

variable "asg_name" {
  description = "FIS ターゲットとする Auto Scaling Group の名前"
  type        = string
}

variable "tags" {
  description = "全リソースに付与する共通タグ"
  type        = map(string)
  default     = {}
}
