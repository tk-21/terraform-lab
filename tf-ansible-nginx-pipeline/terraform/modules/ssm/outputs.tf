output "nginx_port_param_name" {
  description = "Ansible vars_filesで参照するパラメータ名"
  value       = aws_ssm_parameter.nginx_port.name
}
