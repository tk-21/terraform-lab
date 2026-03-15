locals {
  env  = "dev"
  name = "${var.name}-${local.env}"
}

module "vpc" {
  source = "../../modules/vpc"

  name = local.name
  cidr = "10.10.0.0/16"

  public_subnets = {
    "ap-northeast-1a" = "10.10.0.0/24"
    "ap-northeast-1c" = "10.10.1.0/24"
  }

  private_subnets = {
    "ap-northeast-1a" = "10.10.10.0/24"
    "ap-northeast-1c" = "10.10.11.0/24"
  }
}

module "alb" {
  source = "../../modules/alb"

  name              = local.name
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids

  enable_https_listener = false
  certificate_arn       = ""
}

module "ecs_service" {
  source = "../../modules/ecs_service"

  name               = local.name
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  alb_listener_arn   = module.alb.http_listener_arn
  alb_sg_id          = module.alb.alb_sg_id

  container_image = "public.ecr.aws/nginx/nginx:latest"
  container_port  = 80
  desired_count   = 1
}

module "rds" {
  source = "../../modules/rds"

  name               = local.name
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  db_username = var.db_username
  db_password = var.db_password

  # ECSからDBへ到達できるようにするため、ECS側のSGを許可
  allowed_sg_ids = [module.ecs_service.ecs_service_sg_id]
}
