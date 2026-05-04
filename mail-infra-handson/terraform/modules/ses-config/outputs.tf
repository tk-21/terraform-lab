output "configuration_set_name" {
  description = "SES Configuration Set名。メール送信時に ConfigurationSetName として指定する"
  value       = aws_sesv2_configuration_set.main.configuration_set_name
}

output "configuration_set_arn" {
  description = "SES Configuration SetのARN"
  value       = aws_sesv2_configuration_set.main.arn
}
