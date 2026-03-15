variable "name" {
  type        = string
  description = "Base name (e.g. lab-dev)"
}

variable "private_subnet_ids" {
  type        = map(string)
  description = "Private subnet IDs keyed by AZ suffix (e.g. {a=..., d=...})"
}

variable "web_sg_id" {
  type        = string
  description = "Security group id for instances (from module.alb.web_sg_id)"
}

variable "target_group_arn" {
  type        = string
  description = "ALB target group ARN"
}

variable "lb_arn_suffix" {
  type        = string
  description = "ALB arn_suffix (from module.alb.lb_arn_suffix)"
}

variable "tg_arn_suffix" {
  type        = string
  description = "Target group arn_suffix (from module.alb.tg_arn_suffix)"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "asg_min_size" {
  type    = number
  default = 2
}

variable "asg_desired_capacity" {
  type    = number
  default = 2
}

variable "asg_max_size" {
  type    = number
  default = 4
}

variable "health_check_grace_period" {
  type    = number
  default = 60
}

# スケーリング（CPU）
variable "enable_cpu_target_tracking" {
  type    = bool
  default = true
}
variable "cpu_target_value" {
  type    = number
  default = 50
}

# スケーリング（ReqCount）
variable "enable_reqcount_target_tracking" {
  type    = bool
  default = true
}
variable "req_per_target" {
  type    = number
  default = 100
}

variable "user_data" {
  type        = string
  description = "User data script (plain text; will be base64encoded)"
  default     = <<-EOT
    #!/bin/bash
    set -euxo pipefail
    dnf -y update
    dnf -y install nginx
    cat >/usr/share/nginx/html/index.html <<HTML
    <html>
      <body>
        <h1>$${NAME}</h1>
        <p>autoscaling: true</p>
        <p>instance: $(hostname)</p>
      </body>
    </html>
    HTML
    systemctl enable --now nginx
  EOT
}

variable "tags" {
  type    = map(string)
  default = {}
}
