locals {
  base_name = "${var.name_prefix}-${var.env}"
}

module "network" {
  source = "./modules/network"

  name                 = local.base_name
  aws_region           = var.aws_region
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs

  enable_s3_endpoint = true
  tags               = {}
}

module "alb" {
  source = "./modules/alb"

  name              = local.base_name
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids

  alb_ingress_cidrs = var.alb_ingress_cidrs
  ssh_ingress_cidrs = var.ssh_ingress_cidrs

  enable_https_listener = var.enable_https_listener
  certificate_arn       = module.acm_r53.certificate_arn

  tags = var.tags
}

module "asg_web" {
  source = "./modules/asg_web"

  name               = local.base_name
  private_subnet_ids = module.network.private_subnet_ids

  web_sg_id        = module.alb.web_sg_id
  target_group_arn = module.alb.target_group_arn
  lb_arn_suffix    = module.alb.lb_arn_suffix
  tg_arn_suffix    = module.alb.tg_arn_suffix

  instance_type        = var.instance_type
  asg_min_size         = var.asg_min_size
  asg_desired_capacity = var.asg_desired_capacity
  asg_max_size         = var.asg_max_size

  enable_cpu_target_tracking      = true
  cpu_target_value                = 50
  enable_reqcount_target_tracking = true
  req_per_target                  = var.req_per_target

  tags = var.tags
}

module "acm_r53" {
  source = "./modules/acm_r53"

  name        = local.base_name
  domain_name = var.domain_name
  zone_id     = var.route53_zone_id

  alb_dns_name = module.alb.alb_dns_name
  alb_zone_id  = module.alb.alb_zone_id

  tags = var.tags
}

module "waf_alb" {
  source = "./modules/waf_alb"

  name    = local.base_name
  alb_arn = module.alb.alb_arn

  enable_managed_common   = true
  enable_managed_knownbad = true

  tags = var.tags
}
