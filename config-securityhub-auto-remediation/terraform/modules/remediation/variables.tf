variable "environment" {
  description = "デプロイ環境名 (dev / stg / prod)"
  type        = string
}

variable "lambda_role_arn" {
  description = "Lambda修復実行ロールのARN (iamモジュールから取得)"
  type        = string
}

variable "subnet_ids" {
  description = "LambdaをデプロイするプライベートサブネットIDリスト"
  type        = list(string)
}

variable "lambda_sg_id" {
  description = "Lambda用セキュリティグループID"
  type        = string
}

variable "dynamodb_table_name" {
  description = "修復ログ記録用DynamoDBテーブル名"
  type        = string
}

variable "audit_bucket_name" {
  description = "S3監査ログバケット名"
  type        = string
}

variable "dlq_arn" {
  description = "Lambda実行失敗時のDLQ (SQS) ARN"
  type        = string
}

variable "s3_config_rule_event_rule_arn" {
  description = "S3修復をトリガーするConfig Rule用EventBridgeルールARN"
  type        = string
}

variable "s3_custom_action_event_rule_arn" {
  description = "S3修復をトリガーするCustom Action用EventBridgeルールARN"
  type        = string
}

variable "iam_config_rule_event_rule_arn" {
  description = "IAM修復をトリガーするConfig Rule用EventBridgeルールARN"
  type        = string
}

variable "iam_custom_action_event_rule_arn" {
  description = "IAM修復をトリガーするCustom Action用EventBridgeルールARN"
  type        = string
}

variable "sg_config_rule_event_rule_arn" {
  description = "SG修復をトリガーするConfig Rule用EventBridgeルールARN"
  type        = string
}

variable "sg_custom_action_event_rule_arn" {
  description = "SG修復をトリガーするCustom Action用EventBridgeルールARN"
  type        = string
}

variable "rds_config_rule_event_rule_arn" {
  description = "RDS修復をトリガーするConfig Rule用EventBridgeルールARN"
  type        = string
}

variable "rds_custom_action_event_rule_arn" {
  description = "RDS修復をトリガーするCustom Action用EventBridgeルールARN"
  type        = string
}

variable "powertools_layer_version" {
  description = "Lambda Powertools公開LayerのバージョンID (ap-northeast-1, python3.12, arm64)"
  type        = number
  default     = 13
}

variable "common_tags" {
  description = "全リソースに付与するタグ"
  type        = map(string)
  default     = {}
}
