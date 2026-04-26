# dev環境用変数定義（ルートモジュールの変数を再宣言してterraform.tfvarsから受け取る）

variable "aws_region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "bedrock_region" {
  description = "Bedrock Claude Sonnet 3.5が利用可能なリージョン"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "デプロイ環境名"
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "プロジェクト名（タグ・命名規則に使用）"
  type        = string
  default     = "iac-drift-detective"
}

variable "github_owner" {
  description = "GitHubユーザー名またはOrg名"
  type        = string
}

variable "github_repo" {
  description = "対象リポジトリ名"
  type        = string
}

variable "chatwork_room_id" {
  description = "Chatwork通知先ルームID"
  type        = string
}

variable "monitored_tfstate_bucket" {
  description = "監視対象のtfstateが保存されているS3バケット名"
  type        = string
}

variable "monitored_tfstate_key" {
  description = "監視対象のtfstateのS3キーパス"
  type        = string
  default     = "terraform.tfstate"
}
