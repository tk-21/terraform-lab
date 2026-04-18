# -----------------------------------------------------------------------
# Access Analyzer: 外部アクセス検出（type = ACCOUNT）
# -----------------------------------------------------------------------
resource "aws_accessanalyzer_analyzer" "external_access" {
  analyzer_name = "${var.project_name}-external-access"
  type          = "ACCOUNT"

  tags = var.tags
}

# -----------------------------------------------------------------------
# Access Analyzer: 未使用アクセス検出（type = ACCOUNT_UNUSED_ACCESS）
# unused_access_age: 90日間アクセスがない権限を「未使用」とみなす
# -----------------------------------------------------------------------
resource "aws_accessanalyzer_analyzer" "unused_access" {
  analyzer_name = "${var.project_name}-unused-access"
  type          = "ACCOUNT_UNUSED_ACCESS"

  configuration {
    unused_access {
      unused_access_age = var.unused_access_age
    }
  }

  tags = var.tags
}
