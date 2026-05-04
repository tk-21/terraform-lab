output "hosted_zone_id" {
  description = "Route 53 Hosted Zone ID。ses-identityモジュールへ渡してDKIM CNAMEレコードを登録する"
  value       = aws_route53_zone.main.zone_id
}

output "domain_name" {
  description = "ドメイン名"
  value       = aws_route53_zone.main.name
}

output "name_servers" {
  description = "Route 53のNSレコード。ドメインレジストラ側のNS設定をこの値に更新すること"
  value       = aws_route53_zone.main.name_servers
}
