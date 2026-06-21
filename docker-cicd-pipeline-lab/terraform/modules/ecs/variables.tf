variable "name_prefix" { type = string }
variable "aws_region" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "sg_ecs_task_id" { type = string }
variable "ecr_repository_url" { type = string }
variable "tg_blue_arn" { type = string }
variable "image_tag" {
  description = "初回 Terraform apply 時のブートストラップ用イメージタグ (initial-push.sh で push した値を指定)"
  type        = string
}
