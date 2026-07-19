# Security Hub 本体を有効化する
# control_finding_generator: 新形式 SECURITY_CONTROL を採用 (旧形式 STANDARD_CONTROL は廃止予定)
resource "aws_securityhub_account" "main" {
  auto_enable_controls      = true
  control_finding_generator = "SECURITY_CONTROL"
  enable_default_standards  = true
}

# AWS基本セキュリティベストプラクティス標準を有効化
resource "aws_securityhub_standards_subscription" "aws_foundational" {
  standards_arn = "arn:aws:securityhub:ap-northeast-1::standards/aws-foundational-security-best-practices/v/1.0.0"
  depends_on    = [aws_securityhub_account.main]
}

# CIS AWS Foundations Benchmark v1.4.0 を有効化
# MFA未設定・パスワードポリシーなどをConfig Rulesと補完的に評価する
resource "aws_securityhub_standards_subscription" "cis_v140" {
  standards_arn = "arn:aws:securityhub:ap-northeast-1::standards/cis-aws-foundations-benchmark/v/1.4.0"
  depends_on    = [aws_securityhub_account.main]
}
