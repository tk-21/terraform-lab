# terraform/environments/dev/variables.tf
#
# dev 環境の入力変数定義。
# 秘匿情報（パスワードなど）は SSM Parameter Store 経由で取得し、
# ここには含めないこと（CLAUDE.md の禁止事項より）。

variable "environment" {
  description = "デプロイ環境名。リソース名・タグのプレフィックスとして使用する。"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment は dev / staging / prod のいずれかを指定してください。"
  }
}

variable "project" {
  description = "プロジェクト名。リソースの命名規則 sap-<env>-<resource> の sap 部分。"
  type        = string
  default     = "sap"
}

variable "aws_region" {
  description = "AWSリージョン。Lambda / API Gateway / DynamoDB を同一リージョンに配置する。"
  type        = string
  default     = "ap-northeast-1"
}

variable "account_id" {
  description = <<-EOT
    AWSアカウントID。S3バケット名のサフィックスとして使用し、
    グローバルで一意なバケット名を保証する。
    本来は data "aws_caller_identity" で自動取得できるが、
    明示的に渡すことでplan段階での検証を可能にする。
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id は12桁の数字で指定してください。"
  }
}

variable "alert_email" {
  description = <<-EOT
    CloudWatch アラーム通知先のメールアドレス。
    SNS トピックのサブスクリプションとして登録される。
    初回 apply 後に確認メールが届くので承認すること。
  EOT
  type        = string

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.alert_email))
    error_message = "有効なメールアドレスを指定してください。"
  }
}

variable "allowed_ips" {
  description = <<-EOT
    API Gateway の WAF IP 許可リスト。
    prod 環境では本番クライアントの IPアドレスを設定する。
    dev 環境では開発者の IP を設定する（空リストの場合 WAF は無効化される）。
    CIDR 形式で指定すること（例: ["203.0.113.0/24"]）。
  EOT
  type        = list(string)
  default     = []
}
