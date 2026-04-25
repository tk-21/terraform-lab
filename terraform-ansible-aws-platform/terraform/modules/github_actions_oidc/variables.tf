variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "github_org" {
  type        = string
  description = "GitHubオーガニゼーション名またはユーザー名"
}

variable "github_repo" {
  type        = string
  description = "リポジトリ名"
}
