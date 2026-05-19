output "endpoint_service_name" {
  description = "Consumer側がInterface Endpointを作成する際に指定するService Name"
  value       = aws_vpc_endpoint_service.this.service_name
}

output "nlb_arn" {
  description = "NLBのARN"
  value       = aws_lb.this.arn
}

output "service_instance_id" {
  description = "Session Managerでのログイン確認用"
  value       = aws_instance.service.id
}
