output "certificate_arn" {
  value = aws_acm_certificate_validation.this.certificate_arn
}

output "validation_record_fqdns" {
  value = aws_acm_certificate_validation.this.validation_record_fqdns
}

output "alb_fqdn" {
  value = aws_route53_record.alb_alias.fqdn
}
