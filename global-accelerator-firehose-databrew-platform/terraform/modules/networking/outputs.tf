output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "List of public subnet IDs"
  value       = tolist(aws_subnet.public[*].id)
}

output "private_subnet_ids" {
  description = "List of private subnet IDs"
  value       = tolist(aws_subnet.private[*].id)
}

output "sg_alb_id" {
  description = "Security group ID for ALB"
  value       = aws_security_group.alb.id
}

output "sg_lambda_receiver_id" {
  description = "Security group ID for Lambda Receiver"
  value       = aws_security_group.lambda_receiver.id
}

output "sg_lambda_generator_id" {
  description = "Security group ID for Lambda Generator"
  value       = aws_security_group.lambda_generator.id
}
