# ✅Phase 3 — CodeBuild + CodePipeline (CI/CD パイプライン)

## このフェーズのゴール

GitHub push をトリガーに Docker ビルド → ECR push → ECS Blue/Green デプロイまでを
自動化する CI/CD パイプラインを構築する。

パイプライン全体像:
```
GitHub (push) → CodePipeline → [Source] → [Build] → [Deploy]
                                  ↓           ↓          ↓
                               GitHub      CodeBuild   CodeDeploy
                               Connection  (docker     (Blue/Green
                                           build+push)  ECS swap)
```

---

## 事前準備: GitHub Connection

AWS コンソールで CodeStar Connections を作成する (Terraform では作成できない)。

```bash
# 1. AWS コンソール → CodePipeline → Settings → Connections → Create connection
# 2. Provider: GitHub を選択
# 3. Connection 名: cicd-lab-github-connection
# 4. "Install a new app" で GitHub App を承認
# 5. ステータスが "Available" になったら Connection ARN をコピー

# Connection ARN を terraform.tfvars に追記
echo 'github_connection_arn = "arn:aws:codestar-connections:ap-northeast-1:XXXX:connection/XXXX"' \
  >> terraform/terraform.tfvars
echo 'github_owner = "your-github-username"' >> terraform/terraform.tfvars
echo 'github_repo  = "docker-cicd-pipeline-lab"' >> terraform/terraform.tfvars
```

---

## `terraform/variables.tf` に追記

```hcl
variable "github_connection_arn" {
  description = "CodeStar Connections の GitHub Connection ARN"
  type        = string
}

variable "github_owner" {
  description = "GitHub リポジトリオーナー名"
  type        = string
}

variable "github_repo" {
  description = "GitHub リポジトリ名"
  type        = string
}

variable "github_branch" {
  description = "監視するブランチ名"
  type        = string
  default     = "main"
}
```

---

## 作成するファイル

### `buildspec/buildspec.yml`

```yaml
version: 0.2

# CodeBuild 環境変数は CodeBuild Project で定義
# REPOSITORY_URI, CONTAINER_NAME, TASK_FAMILY は自動注入される
env:
  variables:
    REGION: ap-northeast-1

phases:
  pre_build:
    commands:
      - echo "=== ECR ログイン ==="
      - aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $REPOSITORY_URI
      - COMMIT_HASH=$(echo $CODEBUILD_RESOLVED_SOURCE_VERSION | cut -c 1-8)
      - IMAGE_TAG=${COMMIT_HASH:-latest}
      - echo "IMAGE_TAG=$IMAGE_TAG"

  build:
    commands:
      - echo "=== Docker ビルド (arm64 向け) ==="
      - docker buildx create --use --name mybuilder || true
      - |
        docker buildx build \
          --platform linux/arm64 \
          --build-arg IMAGE_TAG=$IMAGE_TAG \
          -t $REPOSITORY_URI:$IMAGE_TAG \
          -t $REPOSITORY_URI:latest \
          ./app \
          --push

  post_build:
    commands:
      - echo "=== imagedefinitions.json 生成 ==="
      # CodeDeploy (Blue/Green) 用のアーティファクト
      - |
        cat > imagedefinitions.json << EOF
        [{"name":"${CONTAINER_NAME}","imageUri":"${REPOSITORY_URI}:${IMAGE_TAG}"}]
        EOF
      # imageDetail.json は Blue/Green デプロイ必須
      - |
        cat > imageDetail.json << EOF
        {"ImageURI":"${REPOSITORY_URI}:${IMAGE_TAG}"}
        EOF
      - echo "=== ビルド完了: $IMAGE_TAG ==="
      - cat imagedefinitions.json

artifacts:
  files:
    - imagedefinitions.json
    - imageDetail.json
```

### `terraform/modules/codebuild/main.tf`

```hcl
# CodeBuild 用 IAM ロール
resource "aws_iam_role" "codebuild" {
  name = "${var.name_prefix}-codebuild-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codebuild" {
  name = "${var.name_prefix}-codebuild-policy"
  role = aws_iam_role.codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuth"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload"
        ]
        Resource = var.ecr_repository_arn
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        # CodeBuild のログは専用プレフィックス配下に限定
        Resource = "arn:aws:logs:*:${var.account_id}:log-group:/aws/codebuild/${var.name_prefix}*"
      },
      {
        Sid    = "S3ArtifactAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject"
        ]
        Resource = "${var.artifact_bucket_arn}/*"
      }
    ]
  })
}

# CodeBuild プロジェクト
resource "aws_codebuild_project" "app" {
  name          = "${var.name_prefix}-build"
  description   = "Docker イメージをビルドして ECR に push する"
  build_timeout = 20  # 分 (arm64 buildx は x86 より時間がかかる)
  service_role  = aws_iam_role.codebuild.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    # docker buildx を使うため privileged_mode が必要
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true  # Docker daemon 起動に必要

    environment_variable {
      name  = "REPOSITORY_URI"
      value = var.ecr_repository_url
    }

    environment_variable {
      name  = "CONTAINER_NAME"
      value = "app"
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec/buildspec.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/${var.name_prefix}"
      stream_name = "build"
    }
  }

  tags = { Name = "${var.name_prefix}-codebuild" }
}
```

### `terraform/modules/codebuild/variables.tf`

```hcl
variable "name_prefix"         { type = string }
variable "account_id"          { type = string }
variable "ecr_repository_url"  { type = string }
variable "ecr_repository_arn"  { type = string }
variable "artifact_bucket_arn" { type = string }
```

### `terraform/modules/codebuild/outputs.tf`

```hcl
output "project_name"     { value = aws_codebuild_project.app.name }
output "role_arn"         { value = aws_iam_role.codebuild.arn }
```

### `terraform/modules/codepipeline/main.tf`

```hcl
# パイプライン用アーティファクトバケット
resource "aws_s3_bucket" "artifacts" {
  # アカウント ID をサフィックスに付けてグローバル一意にする
  bucket        = "${var.name_prefix}-artifacts-${var.account_id}"
  force_destroy = true  # ラボ環境のため destroy 時に中身ごと削除

  tags = { Name = "${var.name_prefix}-artifacts" }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration { status = "Enabled" }
}

# パブリックアクセスを完全ブロック
resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

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
      action                           = "TERMINATE"
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
        Resource = "${aws_s3_bucket.artifacts.arn}/*"
      },
      {
        Sid    = "CodeBuildTrigger"
        Effect = "Allow"
        Action = ["codebuild:BatchGetBuilds", "codebuild:StartBuild"]
        Resource = var.codebuild_project_arn
      },
      {
        Sid    = "CodeDeployTrigger"
        Effect = "Allow"
        Action = [
          "codedeploy:CreateDeployment",
          "codedeploy:GetDeployment",
          "codedeploy:GetApplication",
          "codedeploy:GetApplicationRevision",
          "codedeploy:RegisterApplicationRevision",
          "codedeploy:GetDeploymentConfig",
          "ecs:RegisterTaskDefinition",
          "iam:PassRole"
        ]
        Resource = "*"
      },
      {
        Sid    = "GitHubConnection"
        Effect = "Allow"
        Action = ["codestar-connections:UseConnection"]
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
    location = aws_s3_bucket.artifacts.bucket
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
        DetectChanges    = "true"
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
```

### `terraform/modules/codepipeline/variables.tf`

```hcl
variable "name_prefix"            { type = string }
variable "account_id"             { type = string }
variable "github_connection_arn"  { type = string }
variable "github_owner"           { type = string }
variable "github_repo"            { type = string }
variable "github_branch"          { type = string }
variable "codebuild_project_name" { type = string }
variable "codebuild_project_arn"  { type = string }
variable "ecs_cluster_name"       { type = string }
variable "ecs_service_name"       { type = string }
variable "listener_http_arn"      { type = string }
variable "listener_test_arn"      { type = string }
variable "tg_blue_name"           { type = string }
variable "tg_green_name"          { type = string }
variable "task_execution_role_arn" { type = string }
```

### `terraform/modules/codepipeline/outputs.tf`

```hcl
output "pipeline_name"       { value = aws_codepipeline.main.name }
output "artifact_bucket_arn" { value = aws_s3_bucket.artifacts.arn }
output "artifact_bucket_id"  { value = aws_s3_bucket.artifacts.id }
```

---

## CodeDeploy 用テンプレートファイル

### `appspec.yml` (リポジトリルート)

```yaml
version: 0.0
Resources:
  - TargetService:
      Type: AWS::ECS::Service
      Properties:
        TaskDefinition: <TASK_DEFINITION>
        LoadBalancerInfo:
          ContainerName: "app"
          ContainerPort: 8080
```

### `terraform/task-definition.json` (CodeDeploy が参照するテンプレート)

```json
{
  "family": "cicd-lab-prod-app",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "runtimePlatform": {
    "operatingSystemFamily": "LINUX",
    "cpuArchitecture": "ARM64"
  },
  "containerDefinitions": [
    {
      "name": "app",
      "image": "<IMAGE1_NAME>",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 8080,
          "protocol": "tcp"
        }
      ],
      "environment": [
        { "name": "PORT", "value": "8080" }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/cicd-lab-prod/app",
          "awslogs-region": "ap-northeast-1",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "healthCheck": {
        "command": ["CMD-SHELL", "curl -f http://localhost:8080/health || exit 1"],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 10
      }
    }
  ]
}
```

---

## `terraform/main.tf` に追記

```hcl
module "codebuild" {
  source = "./modules/codebuild"

  name_prefix        = local.name_prefix
  account_id         = local.account_id
  ecr_repository_url = module.ecr.repository_url
  ecr_repository_arn = module.ecr.repository_arn
  artifact_bucket_arn = module.codepipeline.artifact_bucket_arn
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
}
```

---

## 実行手順

```bash
# 1. terraform apply
terraform -chdir=terraform fmt -recursive
terraform -chdir=terraform validate
terraform -chdir=terraform apply -auto-approve

# 2. パイプライン状態確認
aws codepipeline get-pipeline-state --name cicd-lab-prod-pipeline \
  --query 'stageStates[*].{Stage:stageName,Status:latestExecution.status}'

# 3. 動作テスト: app.py を変更して main ブランチに push
# → パイプラインが自動起動し Blue/Green デプロイが走ることを確認

# 4. デプロイ確認
ALB_DNS=$(terraform -chdir=terraform output -raw alb_dns_name)
watch -n 5 "curl -s http://$ALB_DNS/ | python3 -m json.tool"
```

---

## 完了チェックリスト

- [ ] CodeBuild プロジェクトが作成されている
- [ ] CodePipeline が3ステージ (Source / Build / Deploy) で作成されている
- [ ] GitHub への push でパイプラインが自動起動する
- [ ] CodeBuild が成功し ECR にイメージが push されている
- [ ] CodeDeploy の Blue/Green デプロイが完了する
- [ ] ALB に curl して新しい `image_tag` (commit hash) が返ってくる
- [ ] CloudWatch Logs でビルドログが確認できる

## 口頭説明チェックポイント

> 以下を見ずに 5 分間で説明できるか確認すること

1. **CodePipeline の各ステージの役割は？** — Source / Build / Deploy それぞれ何をしているか？
2. **Blue/Green デプロイの切り替えシーケンスは？** — 失敗した場合どうロールバックするか？
3. **buildspec.yml で imageDetail.json を生成する理由は？** — imagedefinitions.json との違いは？
4. **CodeDeploy に AWSCodeDeployRoleForECS を使う理由は？** — 必要な最小権限は何か？
5. **GitHub Connection が Terraform で作れない理由は？** — 代わりに何が必要か？