variable "name_prefix" {
  description = "Resource naming prefix"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "msk_cluster_name" {
  description = "MSK cluster name for dashboard metrics"
  type        = string
}

variable "lambda_function_name" {
  description = "Lambda producer function name for dashboard metrics"
  type        = string
}

variable "flink_app_name" {
  description = "Managed Flink application name for dashboard metrics"
  type        = string
}

variable "vpc_lattice_service_name" {
  description = "VPC Lattice service name for dashboard metrics"
  type        = string
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
