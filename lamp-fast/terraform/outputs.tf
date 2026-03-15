output "public_ip" {
  value = aws_instance.lamp.public_ip
}

output "ssh_user" {
  value = "ec2-user"
}

output "ssh_command" {
  value = "ssh -i ../lamp-fast-key ec2-user@${aws_instance.lamp.public_ip}"
}

output "url" {
  value = "http://${aws_instance.lamp.public_ip}/"
}
