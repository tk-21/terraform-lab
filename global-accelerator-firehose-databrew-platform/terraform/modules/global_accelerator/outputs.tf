output "accelerator_dns_name" {
  description = "DNS name of the Global Accelerator"
  value       = aws_globalaccelerator_accelerator.this.dns_name
}

output "accelerator_ip_sets" {
  description = "Static IP addresses of the Global Accelerator"
  value       = aws_globalaccelerator_accelerator.this.ip_sets
}

output "accelerator_arn" {
  description = "ARN of the Global Accelerator"
  value       = aws_globalaccelerator_accelerator.this.id
}
