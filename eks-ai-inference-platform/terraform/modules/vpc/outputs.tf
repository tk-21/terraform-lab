output "vpc_id" {
  value = aws_vpc.main.id
}

output "private_subnet_ids" {
  value = [for s in aws_subnet.private : s.id]
}

output "public_subnet_ids" {
  value = [for s in aws_subnet.public : s.id]
}

output "vpc_endpoint_subnet_ids" {
  value = [for s in aws_subnet.endpoint : s.id]
}

output "vpc_endpoint_sg_id" {
  value = aws_security_group.vpc_endpoint.id
}

output "s3_vpc_endpoint_id" {
  description = "S3 Gateway Endpoint ID (vLLMモデルキャッシュバケットポリシーのVPCE条件に使用)"
  value       = aws_vpc_endpoint.s3.id
}
