output "service_network_id" {
  description = "VPC Lattice Service Network ID"
  value       = aws_vpclattice_service_network.main.id
}

output "service_network_arn" {
  description = "VPC Lattice Service Network ARN"
  value       = aws_vpclattice_service_network.main.arn
}

output "service_id" {
  description = "VPC Lattice Service（MSK）ID"
  value       = aws_vpclattice_service.msk.id
}

output "service_arn" {
  description = "VPC Lattice Service（MSK）ARN"
  value       = aws_vpclattice_service.msk.arn
}

output "target_group_id" {
  description = "VPC Lattice Target Group（MSK）ID"
  value       = aws_vpclattice_target_group.msk.id
}

output "listener_arn" {
  description = "VPC Lattice Listener（Kafka）ARN"
  value       = aws_vpclattice_listener.kafka.arn
}
