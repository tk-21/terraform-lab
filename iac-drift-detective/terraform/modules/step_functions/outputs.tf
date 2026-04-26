output "state_machine_arn" {
  description = "Step Functions State MachineのARN"
  value       = aws_sfn_state_machine.drift_detection.arn
}

output "state_machine_name" {
  description = "Step Functions State Machine名"
  value       = aws_sfn_state_machine.drift_detection.name
}
