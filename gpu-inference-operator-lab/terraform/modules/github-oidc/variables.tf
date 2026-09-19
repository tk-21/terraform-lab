variable "prefix" {
  description = "リソース名プレフィックス (例: giop)"
  type        = string
  validation {
    condition     = length(var.prefix) <= 5
    error_message = "プレフィックスは5文字以内にしてください (IAMロール名64文字制限のため)"
  }
}

variable "env" {
  description = "環境識別子 (dev / staging / prod)"
  type        = string
  default     = "dev"
}

variable "github_org" {
  description = "GitHubの組織名またはユーザー名"
  type        = string
}

variable "github_repo" {
  description = "GitHubリポジトリ名 (OIDCのsub条件でmainブランチ・vタグに限定する)"
  type        = string
}

variable "ecr_repository_name" {
  description = "pushを許可するECRリポジトリ名"
  type        = string
  default     = "gpu-inference-operator"
}

variable "tags" {
  description = "全リソースに付与する共通タグ"
  type        = map(string)
  default     = {}
}
