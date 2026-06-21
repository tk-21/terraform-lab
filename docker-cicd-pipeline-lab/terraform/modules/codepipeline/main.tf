# CodeDeploy 設定
resource "aws_codedeploy_app" "ecs" {
  name             = "${var.name_prefix}-deploy"
  compute_platform = "ECS"
}

resource "aws_codedeploy_deployment_group" "ecs" {
  app_name               = aws_codedeploy_app.ecs.name
  deployment_group_name  = "${var.name_prefix}-dg"
  deployment_config_name = "CodeDeployDefault.ECSAllAtOnce"
  service_role_arn       = aws_iam_role.codedeploy.arn

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }

  blue_green_deployment_config {
    deployment_ready_option {
      # ヘルスチェック通過後すぐに本番トラフィックを切り替え
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }

    terminate_blue_instances_on_deployment_success {
      action = "TERMINATE"
      # Blue 環境のタスクを5分後に削除 (ロールバック猶予)
      termination_wait_time_in_minutes = 5
    }
  }

  ecs_service {
    cluster_name = var.ecs_cluster_name
    service_name = var.ecs_service_name
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [var.listener_http_arn]
      }

      test_traffic_route {
        listener_arns = [var.listener_test_arn]
      }

      target_group {
        name = var.tg_blue_name
      }

      target_group {
        name = var.tg_green_name
      }
    }
  }
}

# CodePipeline 用 IAM ロール
resource "aws_iam_role" "pipeline" {
  name = "${var.name_prefix}-pipeline-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "pipeline" {
  name = "${var.name_prefix}-pipeline-policy"
  role = aws_iam_role.pipeline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3Artifacts"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:GetObjectVersion"]
        Resource = "${var.artifact_bucket_arn}/*"
      },
      {
        Sid      = "CodeBuildTrigger"
        Effect   = "Allow"
        Action   = ["codebuild:BatchGetBuilds", "codebuild:StartBuild"]
        Resource = var.codebuild_project_arn
      },
      {
        Sid    = "CodeDeployActions"
        Effect = "Allow"
        Action = [
          "codedeploy:CreateDeployment",
          "codedeploy:GetDeployment",
          "codedeploy:GetApplication",
          "codedeploy:GetApplicationRevision",
          "codedeploy:RegisterApplicationRevision",
        ]
        Resource = [
          aws_codedeploy_app.ecs.arn,
          aws_codedeploy_deployment_group.ecs.arn,
        ]
      },
      {
        Sid      = "CodeDeployConfigRead"
        Effect   = "Allow"
        Action   = ["codedeploy:GetDeploymentConfig"]
        Resource = "arn:aws:codedeploy:*:${var.account_id}:deploymentconfig:*"
      },
      {
        # ecs:RegisterTaskDefinition はリソースレベル権限が未サポートのため * が必須
        Sid      = "ECSRegisterTaskDefinition"
        Effect   = "Allow"
        Action   = ["ecs:RegisterTaskDefinition"]
        Resource = "*"
      },
      {
        Sid    = "PassRoleToECS"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [
          var.task_execution_role_arn,
          var.task_role_arn,
        ]
      },
      {
        Sid      = "GitHubConnection"
        Effect   = "Allow"
        Action   = ["codestar-connections:UseConnection"]
        Resource = var.github_connection_arn
      }
    ]
  })
}

# CodeDeploy 用 IAM ロール
resource "aws_iam_role" "codedeploy" {
  name = "${var.name_prefix}-codedeploy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codedeploy.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "codedeploy" {
  role       = aws_iam_role.codedeploy.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeDeployRoleForECS"
}

# CodePipeline
resource "aws_codepipeline" "main" {
  name     = "${var.name_prefix}-pipeline"
  role_arn = aws_iam_role.pipeline.arn

  artifact_store {
    location = var.artifact_bucket_id
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "GitHub_Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn    = var.github_connection_arn
        FullRepositoryId = "${var.github_owner}/${var.github_repo}"
        BranchName       = var.github_branch
        # push イベントで即時起動 (ポーリング不要)
        DetectChanges = "true"
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "Docker_Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]

      configuration = {
        ProjectName = var.codebuild_project_name
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name            = "ECS_BlueGreen_Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "CodeDeployToECS"
      version         = "1"
      input_artifacts = ["source_output", "build_output"]

      configuration = {
        ApplicationName                = aws_codedeploy_app.ecs.name
        DeploymentGroupName            = aws_codedeploy_deployment_group.ecs.deployment_group_name
        TaskDefinitionTemplateArtifact = "source_output"
        TaskDefinitionTemplatePath     = "terraform/task-definition.json"
        AppSpecTemplateArtifact        = "source_output"
        AppSpecTemplatePath            = "appspec.yml"
        Image1ArtifactName             = "build_output"
        Image1ContainerName            = "IMAGE1_NAME"
      }
    }
  }

  tags = { Name = "${var.name_prefix}-pipeline" }
}
