# SageMaker Endpoint Configuration（Blue/Greenデプロイ設定）
# 初回デプロイはendpoint_model_name変数にモデル名を指定してapplyすること
# その後のモデル更新はCodePipelineが自動で実施する
resource "aws_sagemaker_endpoint_configuration" "main" {
  count = var.endpoint_model_name != "" ? 1 : 0
  name  = "${local.prefix}-endpoint-config"

  production_variants {
    variant_name           = "primary"
    model_name             = var.endpoint_model_name
    initial_instance_count = 1
    # テスト環境: ml.t2.medium、本番環境: ml.m5.large を推奨
    instance_type          = var.endpoint_instance_type
    initial_variant_weight = 1.0
  }

  # Blue/Greenデプロイ設定
  # テスト環境では一括切り替え。本番ではCanary（10%→全量）またはLinear（10%ずつ）を推奨
  deployment_config {
    blue_green_update_policy {
      traffic_routing_configuration {
        type                     = "ALL_AT_ONCE"
        wait_interval_in_seconds = 0
      }
      termination_wait_in_seconds = 0
    }
  }

  tags = local.common_tags

  lifecycle {
    # CodePipelineによるエンドポイント更新後のドリフトをTerraformが戻さないよう無視
    ignore_changes = [production_variants]
  }
}

resource "aws_sagemaker_endpoint" "main" {
  count                = var.endpoint_model_name != "" ? 1 : 0
  name                 = "${local.prefix}-inference-endpoint"
  endpoint_config_name = aws_sagemaker_endpoint_configuration.main[0].name

  tags = local.common_tags

  lifecycle {
    # CodePipelineによるエンドポイント設定更新をTerraformが上書きしないよう無視
    # テスト後は必ずコンソールまたはCLIで削除してコスト最適化すること:
    #   aws sagemaker delete-endpoint --endpoint-name smp-inference-endpoint
    ignore_changes = [endpoint_config_name]
  }
}
