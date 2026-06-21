variable "github_repo_owner" {
  description = "GitHubユーザー名または組織名 (例: takuya0220)"
  type        = string
}

variable "github_repo_name" {
  description = "AtlantisがwebhookをリッスンするGitHubリポジトリ名"
  type        = string
  default     = "pr-driven-iac-lab"
}

variable "atlantis_image" {
  description = "Atlantisコンテナイメージ (arm64ビルドを使用)"
  type        = string
  default     = "ghcr.io/runatlantis/atlantis:latest"
}

variable "atlantis_port" {
  description = "AtlantisがリッスンするHTTPポート番号"
  type        = number
  default     = 4141
}
