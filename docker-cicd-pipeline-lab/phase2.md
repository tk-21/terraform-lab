# ✅Phase 2 — ALB + ECS Fargate

## このフェーズのゴール

ALB・ECS クラスター・タスク定義・ECS サービスを構築する。
Phase 1 で作ったネットワーク基盤に乗せる形で、コンテナを実際に動かすところまで完成させる。

---

## 作成するファイル

### `terraform/modules/alb/main.tf`

```hcl
# Application Load Balancer
resource "aws_lb" "main" {
  name               = "${var.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"

  # パブリックサブネットに ALB を配置し、インターネットからのアクセスを受け付ける
  subnets         = var.public_subnet_ids
  security_groups = [var.sg_alb_id]

  # アクセスログは今回省略 (コスト削減) — 本番では S3 に出力すること
  enable_deletion_protection = false

  tags = { Name = "${var.name_prefix}-alb" }
}

# ターゲットグループ (Blue 環境)
resource "aws_lb_target_group" "blue" {
  name        = "${var.name_prefix}-tg-blue"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"  # Fargate は ENI ベースなので ip タイプ必須

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
  }

  tags = { Name = "${var.name_prefix}-tg-blue" }
}

# ターゲットグループ (Green 環境 — Blue/Green デプロイ用)
resource "aws_lb_target_group" "green" {
  name        = "${var.name_prefix}-tg-green"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
  }

  tags = { Name = "${var.name_prefix}-tg-green" }
}

# HTTP リスナー — 本番トラフィックは Blue TG へ
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue.arn
  }

  # CodeDeploy が Blue/Green 切り替え時にこのリスナーを操作するため
  # lifecycle で外部変更を無視する
  lifecycle {
    ignore_changes = [default_action]
  }
}

# テスト用リスナー (Green 環境の動作確認に使用)
resource "aws_lb_listener" "test" {
  load_balancer_arn = aws_lb.main.arn
  port              = 8080
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.green.arn
  }

  lifecycle {
    ignore_changes = [default_action]
  }
}
```

### `terraform/modules/alb/variables.tf`

```hcl
variable "name_prefix"       { type = string }
variable "vpc_id"            { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "sg_alb_id"         { type = string }
```

### `terraform/modules/alb/outputs.tf`

```hcl
output "alb_dns_name"         { value = aws_lb.main.dns_name }
output "alb_arn"              { value = aws_lb.main.arn }
output "tg_blue_arn"          { value = aws_lb_target_group.blue.arn }
output "tg_green_arn"         { value = aws_lb_target_group.green.arn }
output "listener_http_arn"    { value = aws_lb_listener.http.arn }
output "listener_test_arn"    { value = aws_lb_listener.test.arn }
output "tg_blue_name"         { value = aws_lb_target_group.blue.name }
output "tg_green_name"        { value = aws_lb_target_group.green.name }
```

### `terraform/modules/ecs/main.tf`

```hcl
# ECS クラスター
resource "aws_ecs_cluster" "main" {
  name = "${var.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    # Container Insights を有効化してメトリクスを取得
    # CloudWatch エージェントが自動でサイドカー起動する
    value = "enabled"
  }

  tags = { Name = "${var.name_prefix}-cluster" }
}

# CloudWatch ロググループ
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.name_prefix}/app"
  # コスト管理のため30日でログを自動削除
  retention_in_days = 30

  tags = { Name = "${var.name_prefix}-logs" }
}

# ECS タスク実行ロール (ECR pull / CloudWatch Logs への書き込み権限)
resource "aws_iam_role" "task_execution" {
  name = "${var.name_prefix}-ecs-task-exec-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  # AmazonECSTaskExecutionRolePolicy には ECR read + CloudWatch Logs 書き込みが含まれる
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ECS タスクロール (アプリが AWS サービスにアクセスする際に使用)
resource "aws_iam_role" "task" {
  name = "${var.name_prefix}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# タスク定義
resource "aws_ecs_task_definition" "app" {
  family                   = "${var.name_prefix}-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"  # Fargate では awsvpc 必須

  # コスト最適: 最小構成 (0.25 vCPU / 0.5 GB)
  cpu    = 256
  memory = 512

  execution_role_arn = aws_iam_role.task_execution.arn
  task_role_arn      = aws_iam_role.task.arn

  # Graviton2 (arm64) を使用してコストを ~20% 削減
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([{
    name      = "app"
    image     = "${var.ecr_repository_url}:${var.image_tag}"
    essential = true

    portMappings = [{
      containerPort = 8080
      protocol      = "tcp"
    }]

    environment = [
      { name = "PORT",      value = "8080" },
      { name = "IMAGE_TAG", value = var.image_tag }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.app.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "curl -f http://localhost:8080/health || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 10
    }
  }])

  tags = { Name = "${var.name_prefix}-taskdef" }
}

# ECS サービス
resource "aws_ecs_service" "app" {
  name            = "${var.name_prefix}-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    # ECS タスクはプライベートサブネットに配置
    # インターネット疎通は VPC Endpoint 経由
    subnets          = var.private_subnet_ids
    security_groups  = [var.sg_ecs_task_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.tg_blue_arn
    container_name   = "app"
    container_port   = 8080
  }

  # Blue/Green デプロイのため CodeDeploy コントローラーを使用
  # rolling update だと切り替え中に ALB が新旧タスクに振り分けてしまうため
  deployment_controller {
    type = "CODE_DEPLOY"
  }

  # CodeDeploy がタスク定義とロードバランサーを管理するため
  # Terraform の差分検知から除外する
  lifecycle {
    ignore_changes = [task_definition, load_balancer]
  }

  depends_on = [var.listener_http_arn]
}
```

### `terraform/modules/ecs/variables.tf`

```hcl
variable "name_prefix"          { type = string }
variable "aws_region"           { type = string }
variable "private_subnet_ids"   { type = list(string) }
variable "sg_ecs_task_id"       { type = string }
variable "ecr_repository_url"   { type = string }
variable "tg_blue_arn"          { type = string }
variable "listener_http_arn"    { type = string }
variable "image_tag"            {
  type    = string
  default = "latest"
}
```

### `terraform/modules/ecs/outputs.tf`

```hcl
output "cluster_name"       { value = aws_ecs_cluster.main.name }
output "cluster_arn"        { value = aws_ecs_cluster.main.arn }
output "service_name"       { value = aws_ecs_service.app.name }
output "task_definition_arn" { value = aws_ecs_task_definition.app.arn }
output "task_execution_role_arn" { value = aws_iam_role.task_execution.arn }
output "task_role_arn"      { value = aws_iam_role.task.arn }
```

---

## `terraform/main.tf` に追記 (module ブロック追加)

```hcl
module "alb" {
  source = "./modules/alb"

  name_prefix       = local.name_prefix
  vpc_id            = module.networking.vpc_id
  public_subnet_ids = module.networking.public_subnet_ids
  sg_alb_id         = module.networking.sg_alb_id
}

module "ecs" {
  source = "./modules/ecs"

  name_prefix         = local.name_prefix
  aws_region          = var.aws_region
  private_subnet_ids  = module.networking.private_subnet_ids
  sg_ecs_task_id      = module.networking.sg_ecs_task_id
  ecr_repository_url  = module.ecr.repository_url
  tg_blue_arn         = module.alb.tg_blue_arn
  listener_http_arn   = module.alb.listener_http_arn
}
```

## `terraform/outputs.tf` に追記

```hcl
output "alb_dns_name" {
  description = "ALB の DNS 名 (アクセス確認用)"
  value       = module.alb.alb_dns_name
}

output "ecs_cluster_name" {
  description = "ECS クラスター名"
  value       = module.ecs.cluster_name
}
```

---

## 動作確認前に ECR へ初回イメージ Push

```bash
# アカウント ID 取得
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="ap-northeast-1"
REPO="cicd-lab-prod-app"

# ECR ログイン
aws ecr get-login-password --region $REGION | \
  docker login --username AWS --password-stdin \
  $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com

# arm64 向けビルド (Graviton2 対応)
docker buildx build --platform linux/arm64 \
  -t $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$REPO:latest \
  -t $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$REPO:manual-init \
  ./app --push

# ECS サービス更新 (初回タスク起動)
aws ecs update-service \
  --cluster cicd-lab-prod-cluster \
  --service cicd-lab-prod-service \
  --force-new-deployment
```

---

## 実行手順

```bash
# terraform apply
terraform -chdir=terraform fmt -recursive
terraform -chdir=terraform validate
terraform -chdir=terraform apply -auto-approve

# ALB DNS 名を取得
ALB_DNS=$(terraform -chdir=terraform output -raw alb_dns_name)
echo "ALB: http://$ALB_DNS"

# ECR に初回 push してタスクを起動 (上記スクリプトを実行)

# ECS タスクが RUNNING になるまで待機 (~1-2分)
aws ecs wait services-stable \
  --cluster cicd-lab-prod-cluster \
  --services cicd-lab-prod-service

# 動作確認
curl http://$ALB_DNS/health
curl http://$ALB_DNS/
```

---

## 完了チェックリスト

- [ ] ALB が作成され、DNS 名でアクセスできる
- [ ] ECS クラスター・サービスが ACTIVE になっている
- [ ] ECS タスクが RUNNING 状態である
- [ ] `curl http://{ALB_DNS}/health` が `{"status":"healthy"}` を返す
- [ ] `curl http://{ALB_DNS}/` で `image_tag` が確認できる
- [ ] CloudWatch Logs にタスクのログが出力されている

## 口頭説明チェックポイント

> 以下を見ずに 3 分間で説明できるか確認すること

1. **Blue/Green デプロイを選んだ理由は？** — Rolling update との違いとトレードオフは？
2. **Fargate タスクに assign_public_ip = false にした理由は？** — 代わりにどう ECR に繋がるか？
3. **タスク実行ロールとタスクロールの違いは？** — それぞれ何の権限が必要か？
4. **lifecycle の ignore_changes に task_definition を指定した理由は？**