variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "owner" {
  description = "Team or individual responsible for this infrastructure"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for ALB placement"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for ASG EC2 placement"
  type        = list(string)
}

variable "alb_sg_id" {
  description = "Security Group ID for ALB"
  type        = string
}

variable "ec2_sg_id" {
  description = "Security Group ID for EC2 instances"
  type        = string
}

variable "ec2_instance_profile_name" {
  description = "IAM Instance Profile name to attach to EC2 instances"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS CMK ARN for EBS volume encryption"
  type        = string
}

variable "enable_https" {
  description = "HTTPS リスナーを有効化するか否か。false にすると HTTP でターゲットにフォワードする (ハンズオン用)"
  type        = bool
  default     = true
}

variable "certificate_arn" {
  description = "ACM certificate ARN for HTTPS listener (enable_https=true の場合に必須)"
  type        = string
  default     = ""
}

variable "asg_min_size" {
  description = "Minimum number of instances in the ASG"
  type        = number
  default     = 2
}

variable "asg_max_size" {
  description = "Maximum number of instances in the ASG"
  type        = number
  default     = 6
}

variable "asg_desired_capacity" {
  description = "Desired number of instances in the ASG"
  type        = number
  default     = 2
}

variable "instance_type" {
  description = "EC2 instance type (arm64)"
  type        = string
  default     = "t4g.small"
}

variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
