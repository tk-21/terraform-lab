variable "github_owner" {
  description = "GitHub オーナー名（ユーザー名 or Org名）"
  type        = string
}

variable "github_repo" {
  description = "GitHub リポジトリ名（モノレポのリポジトリ自体の名前。プロジェクトのサブディレクトリ名ではない）"
  type        = string
  default     = "terraform-lab"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "bedrock-finops-automation"
}
