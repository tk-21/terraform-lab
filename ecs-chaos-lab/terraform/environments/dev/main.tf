module "vpc" {
  source = "../../modules/vpc"

  prefix               = var.prefix
  env                  = var.env
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  availability_zones   = var.availability_zones
  tags                 = local.common_tags
}

module "sg" {
  source = "../../modules/sg"

  prefix = var.prefix
  env    = var.env
  vpc_id = module.vpc.vpc_id
  tags   = local.common_tags

  depends_on = [module.vpc]
}

module "ecr" {
  source = "../../modules/ecr"

  prefix     = var.prefix
  env        = var.env
  account_id = var.account_id
  tags       = local.common_tags
}

module "alb" {
  source = "../../modules/alb"

  prefix            = var.prefix
  env               = var.env
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  alb_sg_id         = module.sg.alb_sg_id
  account_id        = var.account_id
  tags              = local.common_tags

  depends_on = [module.sg]
}

module "iam" {
  source = "../../modules/iam"

  prefix     = var.prefix
  env        = var.env
  aws_region = var.aws_region
  account_id = var.account_id
  tags       = local.common_tags
}

module "ecs" {
  source = "../../modules/ecs"

  prefix                  = var.prefix
  env                     = var.env
  aws_region              = var.aws_region
  account_id              = var.account_id
  task_cpu                = var.ecs_task_cpu
  task_memory             = var.ecs_task_memory
  container_port          = var.container_port
  desired_count           = var.ecs_desired_count
  ecr_image_uri           = local.ecr_image_uri
  task_execution_role_arn = module.iam.task_execution_role_arn
  task_role_arn           = module.iam.task_role_arn
  private_subnet_ids      = module.vpc.private_subnet_ids
  ecs_task_sg_id          = module.sg.ecs_task_sg_id
  target_group_arn        = module.alb.target_group_arn
  target_group_arn_suffix = module.alb.target_group_arn_suffix
  alb_arn_suffix          = module.alb.alb_arn_suffix
  tags                    = local.common_tags

  depends_on = [module.iam, module.alb]
}

module "fis" {
  source = "../../modules/fis"

  prefix                       = var.prefix
  env                          = var.env
  aws_region                   = var.aws_region
  account_id                   = var.account_id
  fis_role_arn                 = module.iam.fis_role_arn
  cluster_name                 = module.ecs.cluster_name
  cluster_arn                  = module.ecs.cluster_arn
  service_name                 = module.ecs.service_name
  stop_condition_task_kill_arn = module.ecs.stop_condition_alarm_task_kill_arn
  stop_condition_network_arn   = module.ecs.stop_condition_alarm_network_arn
  tags                         = local.common_tags

  depends_on = [module.ecs, module.iam]
}
