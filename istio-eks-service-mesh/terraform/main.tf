module "vpc" {
  source = "./modules/vpc"

  project_name = var.project_name
  env          = var.env
  cluster_name = module.eks.cluster_name
}

module "iam" {
  source = "./modules/iam"

  project_name      = var.project_name
  env               = var.env
  github_org        = var.github_org
  repo_name         = "istio-eks-service-mesh"
  report_bucket_arn = module.s3.bucket_arn
}

module "eks" {
  source = "./modules/eks"

  project_name        = var.project_name
  env                 = var.env
  eks_cluster_version = var.eks_cluster_version
  node_instance_type  = var.node_instance_type
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
  allowed_cidr_blocks = var.allowed_cidr_blocks
  cluster_role_arn    = module.iam.eks_cluster_role_arn
  node_role_arn       = module.iam.eks_node_role_arn
  private_subnet_ids  = module.vpc.private_subnet_ids
  public_subnet_ids   = module.vpc.public_subnet_ids
}

module "s3" {
  source = "./modules/s3"

  project_name   = var.project_name
  env            = var.env
  lifecycle_days = var.report_bucket_lifecycle_days
}
