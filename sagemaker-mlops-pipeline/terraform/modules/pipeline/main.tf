# SageMaker Model Package Group（Model Registryのコンテナ）
resource "aws_sagemaker_model_package_group" "main" {
  model_package_group_name        = "${local.prefix}-model-group"
  model_package_group_description = "sagemaker-mlops-pipelineのモデルバージョンを管理するグループ"
  tags                            = local.common_tags
}

# SageMaker Pipeline（pipeline_definition.pyから生成したJSONを使用）
# 注意: pipeline定義JSONは `python pipeline_definition.py --action definition` で生成してから
# terraform/modules/pipeline/pipeline_definition.json として保存すること
resource "aws_sagemaker_pipeline" "main" {
  pipeline_name         = "${local.prefix}-training-pipeline"
  pipeline_display_name = "SMP Training Pipeline"
  pipeline_description  = "前処理→学習→評価→条件分岐→Model Registry登録の自動パイプライン"
  role_arn              = var.pipeline_role_arn

  pipeline_definition = file("${path.module}/pipeline_definition.json")

  tags = local.common_tags
}
