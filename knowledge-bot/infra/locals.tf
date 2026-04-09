# 複数ファイルで繰り返す命名規則と共通タグを集約する。
locals {
  name = var.project_name
  tags = {
    Project = var.project_name
    Owner   = var.owner
  }
}
