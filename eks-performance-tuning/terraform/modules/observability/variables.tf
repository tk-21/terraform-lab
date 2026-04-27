variable "environment" {
  type = string
}

variable "aws_region" {
  type    = string
  default = "ap-northeast-1"
}

variable "cluster_name" {
  type = string
}

variable "prometheus_retention" {
  type    = string
  default = "7d"
}

variable "grafana_service_type" {
  type    = string
  default = "LoadBalancer"
}
