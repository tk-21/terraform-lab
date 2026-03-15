data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  base_name = var.name

  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  vpc_cidr = "10.0.0.0/16"
  public_subnet_cidrs = [
    "10.0.0.0/24",
    "10.0.1.0/24",
  ]
  private_subnet_cidrs = [
    "10.0.10.0/24",
    "10.0.11.0/24",
  ]
}

module "network" {
  source = "../../modules/network"

  name                 = local.base_name
  vpc_cidr             = local.vpc_cidr
  azs                  = local.azs
  public_subnet_cidrs  = local.public_subnet_cidrs
  private_subnet_cidrs = local.private_subnet_cidrs
}

module "ecr" {
  source = "../../modules/ecr"
  name   = local.base_name
}

module "alb" {
  source = "../../modules/alb"

  name              = local.base_name
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids

  health_check_path = var.health_check_path
  target_port       = var.container_port
}

module "ecs" {
  source = "../../modules/ecs"

  name               = local.base_name
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids

  alb_target_group_arn = module.alb.target_group_arn
  alb_listener_arn     = module.alb.listener_arn

  container_port    = var.container_port
  health_check_path = var.health_check_path

  ecr_repo_url = module.ecr.repo_url
  image_tag    = var.image_tag

  aws_region = var.aws_region
}

module "rds" {
  source = "../../modules/rds"

  name               = local.base_name
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids

  ecs_security_group_id = module.ecs.service_security_group_id

  db_name        = var.db_name
  db_username    = var.db_username
  db_password    = var.db_password
  instance_class = var.db_instance_class
}
