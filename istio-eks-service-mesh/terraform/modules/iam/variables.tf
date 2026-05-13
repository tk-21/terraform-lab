variable "project_name" {
  description = "プロジェクト名"
  type        = string
}

variable "env" {
  description = "環境名"
  type        = string
}

variable "github_org" {
  description = "GitHub OrganizationまたはユーザーID"
  type        = string
}

variable "repo_name" {
  description = "GitHubリポジトリ名"
  type        = string
}

variable "report_bucket_arn" {
  description = "S3レポートバケットARN（GitHub ActionsロールへのS3書き込み権限付与用）"
  type        = string
}
