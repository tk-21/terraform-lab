output "vpc_id" { value = aws_vpc.main.id }
output "public_subnet_ids" { value = aws_subnet.public[*].id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
output "sg_alb_id" { value = aws_security_group.alb.id }
output "sg_ecs_task_id" { value = aws_security_group.ecs_task.id }
