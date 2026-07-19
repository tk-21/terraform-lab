output "cloudfront_domain_name" {
  description = "CloudFront ディストリビューションのデフォルトドメイン名 (Phase 5 の攻撃シミュレーションで使用)"
  value       = aws_cloudfront_distribution.main.domain_name
}

output "cloudfront_distribution_id" {
  description = "CloudFront ディストリビューション ID (キャッシュ無効化などの管理操作に使用)"
  value       = aws_cloudfront_distribution.main.id
}

output "cloudfront_arn" {
  description = "CloudFront ディストリビューション ARN"
  value       = aws_cloudfront_distribution.main.arn
}
