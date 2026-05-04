variable "prefix" {
  description = "リソース名プレフィックス"
  type        = string
}

variable "env" {
  description = "環境名 (dev / stg / prod)"
  type        = string
}

variable "vpc_id" {
  description = "配置先VPCのID"
  type        = string
}

variable "subnet_id" {
  description = "EC2を配置するサブネットID"
  type        = string
}

variable "instance_type" {
  description = "EC2インスタンスタイプ"
  type        = string
  default     = "t3.micro"

  validation {
    condition     = contains(["t3.micro", "t3.small", "t3.medium"], var.instance_type)
    error_message = "コスト管理のため t3.micro / t3.small / t3.medium のみ許可します。"
  }
}

variable "ingress_rules" {
  description = "セキュリティグループのインバウンドルール (dynamic ブロックで展開される)"
  type = list(object({
    description = string
    from_port   = number
    to_port     = number
    protocol    = string
    cidr_blocks = list(string)
  }))
  default = [
    {
      description = "HTTP"
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  ]
}

variable "user_data" {
  description = "EC2起動時に実行するUserDataスクリプト (空の場合は実行しない)"
  type        = string
  default     = ""
}

variable "tags" {
  description = "全リソースに付与する追加タグ"
  type        = map(string)
  default     = {}
}
