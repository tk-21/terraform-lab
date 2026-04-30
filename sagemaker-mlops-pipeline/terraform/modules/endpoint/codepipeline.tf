# CodePipelineソース用のプレースホルダーオブジェクト
# EventBridgeによるトリガー時にCodePipelineが参照するS3オブジェクト
resource "aws_s3_object" "deploy_config" {
  bucket       = var.artifacts_bucket_name
  key          = "deploy-config/config.json"
  content      = jsonencode({ version = "1", pipeline = "${local.prefix}-deploy-pipeline" })
  content_type = "application/json"

  tags = local.common_tags
}

# CodeBuildプロジェクト: 承認済みモデルをSageMaker Endpointにデプロイ
resource "aws_codebuild_project" "deploy" {
  name          = "${local.prefix}-deploy-build"
  description   = "承認済みモデルをSageMaker Endpointに自動デプロイ"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 20

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = false

    environment_variable {
      name  = "MODEL_GROUP_NAME"
      value = "${local.prefix}-model-group"
    }

    environment_variable {
      name  = "ENDPOINT_NAME"
      value = "${local.prefix}-inference-endpoint"
    }

    environment_variable {
      name  = "ENDPOINT_ROLE_ARN"
      value = var.endpoint_role_arn
    }

    environment_variable {
      name  = "REGION"
      value = local.region
    }
  }

  source {
    type = "CODEPIPELINE"
    # buildspecはインラインで定義。シェル変数($VAR)はCodeBuild実行時に展開される
    buildspec = <<-BUILDSPEC
      version: 0.2
      phases:
        build:
          commands:
            - |
              set -euo pipefail

              # 最新承認済みモデルのARNを取得
              MODEL_ARN=$(aws sagemaker list-model-packages \
                --model-package-group-name $MODEL_GROUP_NAME \
                --model-approval-status Approved \
                --sort-by CreationTime \
                --sort-order Descending \
                --max-results 1 \
                --region $REGION \
                --query 'ModelPackageSummaryList[0].ModelPackageArn' \
                --output text)

              if [ "$MODEL_ARN" = "None" ] || [ -z "$MODEL_ARN" ]; then
                echo "承認済みモデルが見つかりません"
                exit 1
              fi

              echo "デプロイ対象モデルARN: $MODEL_ARN"

              TIMESTAMP=$(date +%Y%m%d%H%M%S)
              MODEL_NAME="$ENDPOINT_NAME-model-$TIMESTAMP"
              CONFIG_NAME="$ENDPOINT_NAME-config-$TIMESTAMP"

              # SageMakerモデルリソース作成
              aws sagemaker create-model \
                --model-name $MODEL_NAME \
                --primary-container ModelPackageName=$MODEL_ARN \
                --execution-role-arn $ENDPOINT_ROLE_ARN \
                --region $REGION
              echo "モデルリソース作成完了: $MODEL_NAME"

              # 新しいEndpoint Configuration作成
              aws sagemaker create-endpoint-config \
                --endpoint-config-name $CONFIG_NAME \
                --production-variants VariantName=primary,ModelName=$MODEL_NAME,InitialInstanceCount=1,InstanceType=ml.t2.medium,InitialVariantWeight=1 \
                --region $REGION
              echo "エンドポイント設定作成完了: $CONFIG_NAME"

              # エンドポイント存在確認→更新または新規作成
              ENDPOINT_STATUS=$(aws sagemaker describe-endpoint \
                --endpoint-name $ENDPOINT_NAME \
                --region $REGION \
                --query 'EndpointStatus' \
                --output text 2>/dev/null || echo "NOT_FOUND")

              if [ "$ENDPOINT_STATUS" = "NOT_FOUND" ]; then
                aws sagemaker create-endpoint \
                  --endpoint-name $ENDPOINT_NAME \
                  --endpoint-config-name $CONFIG_NAME \
                  --region $REGION
                echo "エンドポイント新規作成開始: $ENDPOINT_NAME"
              else
                aws sagemaker update-endpoint \
                  --endpoint-name $ENDPOINT_NAME \
                  --endpoint-config-name $CONFIG_NAME \
                  --region $REGION
                echo "エンドポイント更新開始: $ENDPOINT_NAME"
              fi
    BUILDSPEC
  }

  tags = local.common_tags
}

# CodePipeline: モデル承認後の自動デプロイパイプライン
# EventBridgeからStartPipelineExecutionで起動（S3ポーリングは無効）
resource "aws_codepipeline" "deploy" {
  name     = "${local.prefix}-deploy-pipeline"
  role_arn = aws_iam_role.codepipeline.arn

  artifact_store {
    location = var.artifacts_bucket_name
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "S3Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "S3"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        S3Bucket             = var.artifacts_bucket_name
        S3ObjectKey          = "deploy-config/config.json"
        PollForSourceChanges = "false"
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name             = "DeployToSageMaker"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["deploy_output"]

      configuration = {
        ProjectName = aws_codebuild_project.deploy.name
      }
    }
  }

  tags = local.common_tags

  depends_on = [aws_s3_object.deploy_config]
}
