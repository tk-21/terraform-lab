variable "environment" {
  description = "Deployment environment (e.g. prod, stg)"
  type        = string
}

variable "owner" {
  description = "Owner tag value (team or individual responsible)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "172.16.0.0/16"
}

variable "azs" {
  description = "Availability zones to deploy into"
  type        = list(string)
  default     = ["ap-northeast-1a", "ap-northeast-1c", "ap-northeast-1d"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ)"
  type        = list(string)
  default     = ["172.16.0.0/24", "172.16.1.0/24", "172.16.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets — EC2 Auto Scaling Group 配置層"
  type        = list(string)
  default     = ["172.16.10.0/24", "172.16.11.0/24", "172.16.12.0/24"]
}

variable "data_subnet_cidrs" {
  description = "CIDR blocks for data subnets — RDS Aurora 配置層"
  type        = list(string)
  default     = ["172.16.20.0/24", "172.16.21.0/24", "172.16.22.0/24"]
}

variable "flow_logs_retention_days" {
  description = "CloudWatch Logs retention period for VPC Flow Logs (days)"
  type        = number
  default     = 90
}
