module "networking" {
  source = "../../modules/networking"

  project     = var.project
  environment = var.environment
  vpc_cidr    = var.vpc_cidr
}

module "messaging" {
  source = "../../modules/messaging"

  project                        = var.project
  environment                    = var.environment
  sqs_visibility_timeout_seconds = var.sqs_visibility_timeout_seconds
  max_receive_count              = var.max_receive_count
}

module "storage" {
  source = "../../modules/storage"

  project            = var.project
  environment        = var.environment
  job_retention_days = var.job_retention_days
}

module "workflow" {
  source = "../../modules/workflow"

  project     = var.project
  environment = var.environment

  jobs_table_name        = module.storage.jobs_table_name
  jobs_table_arn         = module.storage.jobs_table_arn
  notification_topic_arn = module.messaging.notification_topic_arn
}

module "dispatcher" {
  source = "../../modules/dispatcher"

  project     = var.project
  environment = var.environment

  vpc_id             = module.networking.vpc_id
  vpc_cidr_block     = module.networking.vpc_cidr_block
  private_subnet_ids = module.networking.private_subnet_ids

  input_queue_arn   = module.messaging.input_queue_arn
  input_queue_url   = module.messaging.input_queue_url
  jobs_table_name   = module.storage.jobs_table_name
  jobs_table_arn    = module.storage.jobs_table_arn
  state_machine_arn = module.workflow.state_machine_arn
}

module "stream_processor" {
  source = "../../modules/stream-processor"

  project     = var.project
  environment = var.environment

  vpc_id             = module.networking.vpc_id
  vpc_cidr_block     = module.networking.vpc_cidr_block
  private_subnet_ids = module.networking.private_subnet_ids

  jobs_table_stream_arn = module.storage.jobs_table_stream_arn
  metrics_table_name    = module.storage.metrics_table_name
  metrics_table_arn     = module.storage.metrics_table_arn
}

module "event_router" {
  source = "../../modules/event-router"

  project     = var.project
  environment = var.environment

  vpc_id             = module.networking.vpc_id
  vpc_cidr_block     = module.networking.vpc_cidr_block
  private_subnet_ids = module.networking.private_subnet_ids

  state_machine_arn = module.workflow.state_machine_arn
  jobs_table_name   = module.storage.jobs_table_name
  jobs_table_arn    = module.storage.jobs_table_arn
  alert_topic_arn   = module.messaging.alert_topic_arn
  alert_email       = var.alert_email
}

module "api_ingestor" {
  source = "../../modules/api-ingestor"

  project     = var.project
  environment = var.environment

  input_queue_url  = module.messaging.input_queue_url
  input_queue_name = module.messaging.input_queue_name
  input_queue_arn  = module.messaging.input_queue_arn
  jobs_table_name  = module.storage.jobs_table_name
  jobs_table_arn   = module.storage.jobs_table_arn
}

module "observability" {
  source = "../../modules/observability"

  project     = var.project
  environment = var.environment

  input_queue_name               = module.messaging.input_queue_name
  dlq_name                       = module.messaging.dlq_name
  dispatcher_function_name       = module.dispatcher.lambda_function_name
  stream_processor_function_name = module.stream_processor.lambda_function_name
  dlq_handler_function_name      = module.event_router.dlq_handler_function_name
  state_machine_name             = module.workflow.state_machine_name
  state_machine_arn              = module.workflow.state_machine_arn
  jobs_table_name                = module.storage.jobs_table_name
  alert_topic_arn                = module.messaging.alert_topic_arn
}
