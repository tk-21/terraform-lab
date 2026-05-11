# ✅Phase 2 — IAM / ECS Cluster / Task Definition / Service

## 前フェーズ（Phase 1）の成果物

- `terraform/modules/vpc/` — VPC 10.1.0.0/16 / サブネット / IGW / NAT GW(1AZ)
- `terraform/modules/sg/` — ALB SG / ECS Task SG（ALB SG からのみ ingress 許可）
- `terraform/modules/ecr/` — ecl-dev-nginx リポジトリ（scan_on_push 有効）
- `terraform/modules/alb/` — ALB / TG (target_type="ip") / Listener HTTP:80
- `terraform/environments/dev/main.tf` — vpc/sg/ecr/alb モジュール有効化済み

## このフェーズのゴール

生成するファイル:
- `terraform/modules/iam/` — FIS 実行ロール + ECS Task 実行ロール + Task ロール
- `terraform/modules/ecs/` — Cluster / Task Definition / Service / CloudWatch Logs
- `scripts/bootstrap.sh` — ECR への初回イメージプッシュ
- `environments/dev/main.tf` の iam / ecs モジュールを有効化

---

## 生成指示

### 1. `terraform/modules/iam/main.tf`

#### 1-1. ECS Task 実行ロール

```hcl
# ECS がコンテナ起動時に使用するロール（ECR pull / CW Logs 書き込み）
resource "aws_iam_role" "task_execution" {
  name = "${var.prefix}-ecs-task-exec-role"  # ecl-ecs-task-exec-role

  assume_role_policy = jsonencode({
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
```

#### 1-2. ECS Task ロール

```hcl
# コンテナアプリ自体が使用するロール（最小権限）
resource "aws_iam_role" "task" {
  name = "${var.prefix}-ecs-task-role"  # ecl-ecs-task-role

  assume_role_policy = jsonencode({
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "task_logs" {
  name = "${var.prefix}-ecs-task-logs"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/ecs/${var.prefix}-${var.env}:*"
    }]
  })
}
```

#### 1-3. FIS 実行ロール

```hcl
# FIS が ECS 障害を注入するために使用するロール
# コメント: 3シナリオ（Task Kill / Network Disruption / Desired Count 変更）を網羅する最小権限
resource "aws_iam_role" "fis_execution" {
  # IAM ロール名 64 文字制限に注意
  name = "${var.prefix}-fis-exec-role"  # ecl-fis-exec-role

  assume_role_policy = jsonencode({
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "fis.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "fis_execution" {
  name = "${var.prefix}-fis-exec-policy"
  role = aws_iam_role.fis_execution.id

  policy = jsonencode({
    Statement = [
      {
        # シナリオ1: Task 強制停止
        Sid    = "ECSTaskKill"
        Effect = "Allow"
        Action = [
          "ecs:StopTask",
          "ecs:DescribeTasks",
          "ecs:ListTasks"
        ]
        Resource = "*"
      },
      {
        # シナリオ2: ネットワーク遮断（ENI レベルで操作）
        Sid    = "NetworkDisruption"
        Effect = "Allow"
        Action = [
          "ec2:DescribeNetworkInterfaces",
          "ec2:CreateNetworkAclEntry",
          "ec2:DeleteNetworkAclEntry",
          "ec2:DescribeNetworkAcls"
        ]
        Resource = "*"
      },
      {
        # シナリオ3: Lambda 経由で DesiredCount 変更
        Sid    = "LambdaInvoke"
        Effect = "Allow"
        Action = ["lambda:InvokeFunction"]
        # Lambda ARN を絞る（ワイルドカード回避）
        Resource = "arn:aws:lambda:${var.aws_region}:${var.account_id}:function:${var.prefix}-*"
      },
      {
        # 停止条件の監視
        Sid    = "CloudWatchAlarms"
        Effect = "Allow"
        Action = [
          "cloudwatch:DescribeAlarms",
          "elasticloadbalancing:DescribeTargetHealth"
        ]
        Resource = "*"
      },
      {
        # FIS 実験ログ書き込み
        Sid    = "FISLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/aws/fis/*"
      }
    ]
  })
}
```

`variables.tf`: prefix, env, aws_region, account_id, tags
`outputs.tf`: fis_role_arn, task_execution_role_arn, task_role_arn, fis_role_name

---

### 2. `terraform/modules/ecs/main.tf`

#### 2-1. CloudWatch Logs グループ

```hcl
resource "aws_cloudwatch_log_group" "ecs" {
  # コメント: ECS コンテナログの保持先。FIS 実験中の Task 停止ログも記録される。
  name              = "/ecs/${var.prefix}-${var.env}"
  retention_in_days = 30
}
```

#### 2-2. ECS Cluster

```hcl
resource "aws_ecs_cluster" "main" {
  name = "${var.prefix}-${var.env}-cluster"  # ecl-dev-cluster

  setting {
    name  = "containerInsights"
    # コメント: Container Insights を有効化。FIS 実験中の CPU/Memory/Task 数を可視化。
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}
```

#### 2-3. Task Definition

```hcl
resource "aws_ecs_task_definition" "main" {
  family                   = "${var.prefix}-${var.env}-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  # コメント: awsvpc モードにより各 Task に ENI が割り当てられる。
  # FIS のネットワーク遮断（シナリオ2）はこの ENI を対象に動作する。
  cpu                      = var.task_cpu     # 256 (0.25 vCPU)
  memory                   = var.task_memory  # 512 MB
  execution_role_arn       = var.task_execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([
    {
      name      = "${var.prefix}-nginx"
      image     = var.ecr_image_uri
      essential = true

      portMappings = [{
        containerPort = var.container_port  # 80
        protocol      = "tcp"
      }]

      healthCheck = {
        command     = ["CMD-SHELL", "wget -qO- http://localhost/health || exit 1"]
        interval    = 10
        timeout     = 3
        retries     = 3
        startPeriod = 30
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "nginx"
        }
      }

      # FIS 実験中のリソース使用状況を確認しやすくするため
      # CPU/Memory 制限を明示的に設定
      cpu    = 256
      memory = 512
    }
  ])

  tags = var.tags
}
```

#### 2-4. ECS Service

```hcl
resource "aws_ecs_service" "main" {
  name            = "${var.prefix}-${var.env}-service"  # ecl-dev-service
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.main.arn
  desired_count   = var.desired_count  # 2
  launch_type     = "FARGATE"

  # コメント: enable_execute_command は FIS 実験のトラブルシューティング用。
  # 本番環境では false に設定すること。
  enable_execute_command = true

  network_configuration {
    subnets          = var.private_subnet_ids  # private subnet 配置
    security_groups  = [var.ecs_task_sg_id]
    assign_public_ip = false  # NAT GW 経由で ECR / CW Logs にアクセス
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "${var.prefix}-nginx"
    container_port   = var.container_port
  }

  # コメント: FIS Task Kill 実験後の自動復旧を妨げないよう
  # deployment_minimum_healthy_percent を 50 に設定（Task 数 2 の場合 1台で継続）
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  lifecycle {
    # コメント: FIS 実験でシナリオ3（Desired Count 変更）を実行した後、
    # Terraform が desired_count を上書きしないよう ignore_changes に追加。
    ignore_changes = [desired_count]
  }
}
```

#### 2-5. CloudWatch アラーム（FIS 停止条件用）

```hcl
# シナリオ1 停止条件: 実行中 Task が 1 未満になった状態が 5 分継続
resource "aws_cloudwatch_metric_alarm" "running_task_count_low" {
  alarm_name          = "${var.prefix}-${var.env}-fis-stop-running-task-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "RunningTaskCount"
  namespace           = "ECS/ContainerInsights"
  period              = 300
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "FIS停止条件: RunningTaskCount が 1 未満（全Task停止）"

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.main.name
  }
}

# シナリオ2 停止条件: ALB Healthy Host が 0 になった状態が 3 分継続
resource "aws_cloudwatch_metric_alarm" "healthy_host_count_zero" {
  alarm_name          = "${var.prefix}-${var.env}-fis-stop-healthy-host-zero"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 180
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "FIS停止条件: ALB の Healthy Host が 0（全断）"

  dimensions = {
    TargetGroup  = var.target_group_arn_suffix  # "targetgroup/ecl-dev-tg/xxx"
    LoadBalancer = var.alb_arn_suffix            # "app/ecl-dev-alb/xxx"
  }
}
```

`variables.tf`:
- prefix, env, aws_region, account_id
- task_cpu, task_memory, container_port
- desired_count
- ecr_image_uri
- task_execution_role_arn, task_role_arn
- private_subnet_ids, ecs_task_sg_id
- target_group_arn, target_group_arn_suffix, alb_arn_suffix
- tags

`outputs.tf`:
- cluster_name, cluster_arn
- service_name, service_arn
- task_definition_arn
- log_group_name
- stop_condition_alarm_task_kill_arn
- stop_condition_alarm_network_arn

---

### 3. `scripts/bootstrap.sh`

```bash
#!/usr/bin/env bash
# ECR へのサンプル nginx イメージの初回プッシュスクリプト
# 使い方: ./scripts/bootstrap.sh
# 前提: Docker が起動済み、AWS CLI が設定済み

set -euo pipefail

REGION="ap-northeast-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REPO_URL="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/ecl-dev-nginx"

echo "[INFO] ECR ログイン..."
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "[INFO] イメージビルド..."
docker build -t ecl-dev-nginx ./app/

echo "[INFO] イメージタグ付け..."
docker tag ecl-dev-nginx:latest "${REPO_URL}:latest"

echo "[INFO] ECR へのプッシュ..."
docker push "${REPO_URL}:latest"

echo "[SUCCESS] プッシュ完了: ${REPO_URL}:latest"
echo ""
echo "次のステップ:"
echo "  terraform/environments/dev/terraform.tfvars に account_id を設定後"
echo "  cd terraform/environments/dev && terraform apply"
```

### 4. `terraform/environments/dev/main.tf` 更新

Phase 1 の vpc/sg/ecr/alb に加えて iam/ecs を有効化:

```hcl
module "iam" {
  source     = "../../modules/iam"
  prefix     = var.prefix
  env        = var.env
  aws_region = var.aws_region
  account_id = var.account_id
  tags       = local.common_tags
}

module "ecs" {
  source                       = "../../modules/ecs"
  prefix                       = var.prefix
  env                          = var.env
  aws_region                   = var.aws_region
  account_id                   = var.account_id
  task_cpu                     = var.ecs_task_cpu
  task_memory                  = var.ecs_task_memory
  container_port               = var.container_port
  desired_count                = var.ecs_desired_count
  ecr_image_uri                = local.ecr_image_uri
  task_execution_role_arn      = module.iam.task_execution_role_arn
  task_role_arn                = module.iam.task_role_arn
  private_subnet_ids           = module.vpc.private_subnet_ids
  ecs_task_sg_id               = module.sg.ecs_task_sg_id
  target_group_arn             = module.alb.target_group_arn
  target_group_arn_suffix      = module.alb.target_group_arn_suffix
  alb_arn_suffix               = module.alb.alb_arn_suffix
  tags                         = local.common_tags

  depends_on = [module.iam, module.alb]
}

# Phase 3 以降（コメントアウト）
# module "fis" { ... }
```

`outputs.tf` に追加:
- `cluster_name`, `cluster_arn`
- `service_name`
- `fis_role_arn`
- `stop_condition_task_kill_arn`
- `stop_condition_network_arn`

---

## 完了条件

- [ ] `terraform fmt` / `terraform validate` が通ること
- [ ] ECS Task の network_mode が `"awsvpc"` であること（FIS ネットワーク遮断に必須）
- [ ] `enable_execute_command = true` が設定されていること（デバッグ用）
- [ ] `lifecycle { ignore_changes = [desired_count] }` が Service に設定されていること
- [ ] CloudWatch Logs グループが `/ecs/ecl-dev` で生成されること
- [ ] Container Insights が有効化されていること
- [ ] 停止条件アラームが 2 種類（Task Kill 用 / Network 用）生成されること
- [ ] `bootstrap.sh` が実行権限付きで生成されること（chmod +x）

---

## bootstrap.sh 実行手順（apply 後）

```bash
# 1. terraform apply（Phase 1+2）
cd terraform/environments/dev
terraform init
terraform apply

# 2. ECR にイメージをプッシュ
chmod +x ../../scripts/bootstrap.sh
../../scripts/bootstrap.sh

# 3. ECS Service の起動確認
aws ecs wait services-stable \
  --cluster ecl-dev-cluster \
  --services ecl-dev-service \
  --region ap-northeast-1

echo "サービス起動確認完了"
```

---

## 次フェーズへの引き継ぎ情報

Phase 3 で必要な値:
- `module.ecs.cluster_name` = `ecl-dev-cluster`
- `module.ecs.service_name` = `ecl-dev-service`
- `module.ecs.cluster_arn`
- `module.iam.fis_role_arn`
- `module.ecs.stop_condition_task_kill_arn`
- `module.ecs.stop_condition_network_arn`
- `module.alb.alb_dns_name`（動作確認用）