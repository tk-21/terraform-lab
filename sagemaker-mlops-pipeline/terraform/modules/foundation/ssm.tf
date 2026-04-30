resource "aws_ssm_parameter" "chatwork_room_id" {
  name  = "/${var.prefix}/chatwork/room_id"
  type  = "SecureString"
  value = "REPLACE_ME"

  tags = var.common_tags

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "chatwork_api_token" {
  name  = "/${var.prefix}/chatwork/api_token"
  type  = "SecureString"
  value = "REPLACE_ME"

  tags = var.common_tags

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "model_approval_threshold" {
  name  = "/${var.prefix}/config/model_approval_threshold"
  type  = "String"
  value = tostring(var.model_approval_threshold)

  tags = var.common_tags
}

# apply後にTerraformが自動設定するARNのプレースホルダー
resource "aws_ssm_parameter" "pipeline_role_arn" {
  name  = "/${var.prefix}/config/pipeline_role_arn"
  type  = "String"
  value = aws_iam_role.pipeline.arn

  tags = var.common_tags
}
