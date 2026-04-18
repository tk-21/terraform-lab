output "external_access_analyzer_arn" {
  description = "外部アクセス検出 Analyzer の ARN"
  value       = aws_accessanalyzer_analyzer.external_access.arn
}

output "external_access_analyzer_name" {
  description = "外部アクセス検出 Analyzer の名前"
  value       = aws_accessanalyzer_analyzer.external_access.analyzer_name
}

output "unused_access_analyzer_arn" {
  description = "未使用アクセス検出 Analyzer の ARN"
  value       = aws_accessanalyzer_analyzer.unused_access.arn
}

output "unused_access_analyzer_name" {
  description = "未使用アクセス検出 Analyzer の名前"
  value       = aws_accessanalyzer_analyzer.unused_access.analyzer_name
}
