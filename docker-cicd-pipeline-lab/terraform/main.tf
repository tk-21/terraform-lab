data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  account_id  = data.aws_caller_identity.current.account_id
}

module "networking" {
  source = "./modules/networking"

  name_prefix        = local.name_prefix
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  account_id         = local.account_id
  aws_region         = var.aws_region
}

module "ecr" {
  source = "./modules/ecr"

  name_prefix = local.name_prefix
  account_id  = local.account_id
}

module "alb" {
  source = "./modules/alb"

  name_prefix       = local.name_prefix
  vpc_id            = module.networking.vpc_id
  public_subnet_ids = module.networking.public_subnet_ids
  sg_alb_id         = module.networking.sg_alb_id
}

module "ecs" {
  source = "./modules/ecs"

  name_prefix        = local.name_prefix
  aws_region         = var.aws_region
  private_subnet_ids = module.networking.private_subnet_ids
  sg_ecs_task_id     = module.networking.sg_ecs_task_id
  ecr_repository_url = module.ecr.repository_url
  tg_blue_arn        = module.alb.tg_blue_arn
  # initial-push.sh が :initial タグで push するため、ここも initial を指定する
  # CodeDeploy 管理下に移行後は lifecycle.ignore_changes により Terraform は上書きしない
  image_tag = "initial"

  # ALB リスナーが存在してからサービスを作成するため明示的に依存を宣言
  depends_on = [module.alb]
}

# CodeBuild / CodePipeline 共有アーティファクトバケット
# codebuild と codepipeline の循環依存を避けるため、ルートで管理する
resource "aws_s3_bucket" "artifacts" {
  bucket        = "${local.name_prefix}-artifacts-${local.account_id}"
  force_destroy = true

  tags = { Name = "${local.name_prefix}-artifacts" }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

module "codebuild" {
  source = "./modules/codebuild"

  name_prefix         = local.name_prefix
  account_id          = local.account_id
  ecr_repository_url  = module.ecr.repository_url
  ecr_repository_arn  = module.ecr.repository_arn
  artifact_bucket_arn = aws_s3_bucket.artifacts.arn
}

module "codepipeline" {
  source = "./modules/codepipeline"

  name_prefix             = local.name_prefix
  account_id              = local.account_id
  github_connection_arn   = var.github_connection_arn
  github_owner            = var.github_owner
  github_repo             = var.github_repo
  github_branch           = var.github_branch
  codebuild_project_name  = module.codebuild.project_name
  codebuild_project_arn   = "arn:aws:codebuild:${var.aws_region}:${local.account_id}:project/${module.codebuild.project_name}"
  ecs_cluster_name        = module.ecs.cluster_name
  ecs_service_name        = module.ecs.service_name
  listener_http_arn       = module.alb.listener_http_arn
  listener_test_arn       = module.alb.listener_test_arn
  tg_blue_name            = module.alb.tg_blue_name
  tg_green_name           = module.alb.tg_green_name
  task_execution_role_arn = module.ecs.task_execution_role_arn
  task_role_arn           = module.ecs.task_role_arn
  artifact_bucket_arn     = aws_s3_bucket.artifacts.arn
  artifact_bucket_id      = aws_s3_bucket.artifacts.id
}

module "observability" {
  source = "./modules/observability"

  name_prefix            = local.name_prefix
  ecs_cluster_name       = module.ecs.cluster_name
  ecs_service_name       = module.ecs.service_name
  alb_arn_suffix         = module.alb.alb_arn_suffix
  codebuild_project_name = module.codebuild.project_name
  pipeline_name          = module.codepipeline.pipeline_name
}
