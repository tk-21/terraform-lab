variable "environment" {
  description = "環境名（Terratestがテスト用に上書きする。通常は terraform.tfvars で設定）"
  type        = string
  default     = "dev"
}

variable "az_count" {
  description = "使用するAZ数（Terratestがシングル/マルチAZテストで上書きする）"
  type        = number
  default     = 2
}
