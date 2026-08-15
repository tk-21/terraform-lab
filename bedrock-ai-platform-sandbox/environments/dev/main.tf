module "networking" {
  source = "../../modules/networking"

  project     = var.project
  environment = var.environment
  vpc_cidr    = var.vpc_cidr
}

module "bedrock_foundation" {
  source = "../../modules/bedrock-foundation"

  project     = var.project
  environment = var.environment
  vpc_id      = module.networking.vpc_id
  subnet_ids  = module.networking.private_subnet_ids

  depends_on = [module.networking]
}

module "knowledge_base" {
  source = "../../modules/knowledge-base"

  project            = var.project
  environment        = var.environment
  vpc_id             = module.networking.vpc_id
  vpc_cidr_block     = module.networking.vpc_cidr_block
  private_subnet_ids = module.networking.private_subnet_ids

  depends_on = [module.networking]
}

module "multi_tenant" {
  source = "../../modules/multi-tenant"

  project     = var.project
  environment = var.environment
}

module "router_lambda" {
  source = "../../modules/router-lambda"

  project                          = var.project
  environment                      = var.environment
  vpc_id                           = module.networking.vpc_id
  vpc_cidr_block                   = module.networking.vpc_cidr_block
  private_subnet_ids               = module.networking.private_subnet_ids
  dynamodb_endpoint_prefix_list_id = module.networking.dynamodb_endpoint_prefix_list_id

  guardrail_id      = module.bedrock_foundation.guardrail_id
  guardrail_arn     = module.bedrock_foundation.guardrail_arn
  guardrail_version = module.bedrock_foundation.guardrail_version

  tenant_table_name = module.multi_tenant.tenant_table_name
  tenant_table_arn  = module.multi_tenant.tenant_table_arn
  usage_table_name  = module.multi_tenant.usage_table_name
  usage_table_arn   = module.multi_tenant.usage_table_arn

  depends_on = [
    module.networking,
    module.bedrock_foundation,
    module.multi_tenant,
  ]
}

module "cost_controller" {
  source = "../../modules/cost-controller"

  project     = var.project
  environment = var.environment

  tenant_table_name = module.multi_tenant.tenant_table_name
  tenant_table_arn  = module.multi_tenant.tenant_table_arn
  usage_table_name  = module.multi_tenant.usage_table_name
  usage_table_arn   = module.multi_tenant.usage_table_arn

  alert_email        = var.alert_email
  monthly_budget_usd = var.monthly_budget_usd

  depends_on = [module.multi_tenant]
}

module "api_gateway" {
  source = "../../modules/api-gateway"

  project     = var.project
  environment = var.environment

  router_lambda_invoke_arn    = module.router_lambda.lambda_invoke_arn
  router_lambda_function_name = module.router_lambda.lambda_function_name

  depends_on = [module.router_lambda]
}

module "bedrock_agent" {
  source = "../../modules/bedrock-agent"

  project     = var.project
  environment = var.environment

  enable_bedrock_agent = var.enable_bedrock_agent

  knowledge_base_id = module.knowledge_base.knowledge_base_id
  guardrail_id      = module.bedrock_foundation.guardrail_id
  guardrail_version = module.bedrock_foundation.guardrail_version

  usage_table_name = module.multi_tenant.usage_table_name
  usage_table_arn  = module.multi_tenant.usage_table_arn

  depends_on = [
    module.knowledge_base,
    module.bedrock_foundation,
    module.multi_tenant,
  ]
}

module "observability" {
  source = "../../modules/observability"

  project     = var.project
  environment = var.environment

  router_lambda_name          = module.router_lambda.lambda_function_name
  cost_controller_lambda_name = module.cost_controller.lambda_function_name
  action_handler_lambda_name  = module.bedrock_agent.action_handler_function_name

  api_id = module.api_gateway.api_id

  tenant_table_name = module.multi_tenant.tenant_table_name
  usage_table_name  = module.multi_tenant.usage_table_name

  alert_topic_arn      = module.cost_controller.alert_topic_arn
  cloudtrail_log_group = module.bedrock_foundation.cloudtrail_log_group

  depends_on = [
    module.router_lambda,
    module.cost_controller,
    module.api_gateway,
    module.bedrock_agent,
    module.bedrock_foundation,
    module.multi_tenant,
  ]
}
