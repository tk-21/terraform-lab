output "public_nacl_id" {
  description = "Public サブネット用 NACL ID"
  value       = aws_network_acl.public.id
}

output "private_nacl_id" {
  description = "Private サブネット用 NACL ID"
  value       = aws_network_acl.private.id
}
