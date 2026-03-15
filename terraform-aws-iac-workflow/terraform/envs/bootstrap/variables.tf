variable "aws_region" {
  type    = string
  default = "ap-northeast-1"
}

# GitHub の所有者（ユーザー名 or Organization）
variable "github_owner" {
  type = string
}

# GitHub リポジトリ名（例: terraform-aws-infra-modules）
variable "github_repo" {
  type = string
}

# 許可するブランチ（最初は main でOK）
variable "allowed_branches" {
  type    = list(string)
  default = ["main"]
}

# 学習用：ひとまず広め権限で動かす（後で絞る）
variable "attach_admin_policy" {
  type    = bool
  default = true
}
