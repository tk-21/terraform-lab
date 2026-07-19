# Phase 2: ECS Deep Dive — Capacity Provider・Service Connect・ECS Exec

## このフェーズの目標

「ECS を使ったことがある」を超え、以下を実体験として語れるようにする:
1. Capacity Provider の base/weight 数学
2. Service Connect（Envoy サイドカー自動注入）
3. タスク配置戦略（spread + binpack の組み合わせ理由）
4. ECS Exec でのライブデバッグ
5. SIGTERM × stopTimeout によるグレースフルシャットダウン

---

## 前提

Phase 1 の terraform/foundation/terraform.tfstate が存在し、
ECR に両イメージがプッシュ済みであること。

---

## Step 1: terraform/ecs/ の作成

### terraform/ecs/main.tf を作成すること

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1"
  default_tags {
    tags = {
      Project     = "ecs-eks-deepdive"
      Environment = "lab"
      Phase       = "ecs"
    }
  }
}

# Foundation の出力値を参照
data "terraform_remote_state" "foundation" {
  backend = "local"
  config = {
    path = "../foundation/terraform.tfstate"
  }
}

locals {
  vpc_id                 = data.terraform_remote_state.foundation.outputs.vpc_id
  private_subnet_ids     = data.terraform_remote_state.foundation.outputs.private_subnet_ids
  public_subnet_ids      = data.terraform_remote_state.foundation.outputs.public_subnet_ids
  ecr_api_url            = data.terraform_remote_state.foundation.outputs.ecr_api_url
  ecr_worker_url         = data.terraform_remote_state.foundation.outputs.ecr_worker_url
  sqs_queue_url          = data.terraform_remote_state.foundation.outputs.sqs_queue_url
  sqs_queue_arn          = data.terraform_remote_state.foundation.outputs.sqs_queue_arn
  execution_role_arn     = data.terraform_remote_state.foundation.outputs.ecs_execution_role_arn
  task_role_arn          = data.terraform_remote_state.foundation.outputs.ecs_task_role_arn
}
```

### terraform/ecs/security_groups.tf を作成すること

**ALB Security Group**:
- Inbound: TCP 80 from `0.0.0.0/0`
- Outbound: TCP 8080 to ECS Tasks SG

**ECS Tasks Security Group**:
- Inbound: TCP 8080 from ALB SG のみ
- Outbound: HTTPS 443 to `0.0.0.0/0`（VPC Endpoint 経由）

### terraform/ecs/cloudwatch.tf を作成すること

CloudWatch Log Groups（retention_in_days = 7）:
- `/ecs/deepdive/api`
- `/ecs/deepdive/worker`

### terraform/ecs/cluster.tf を作成すること

```hcl
resource "aws_ecs_cluster" "main" {
  name = "deepdive-ecs"

  setting {
    name  = "containerInsights"
    value = "enabled"
    # Container Insights で CPU/Memory/ネットワーク使用量を CloudWatch に送信
    # Phase 4 の ECS vs EKS 比較ダッシュボードで使用する
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name = aws_ecs_cluster.main.name

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = 1
    # base=1: 最初の 1 タスクは必ず通常 Fargate で起動
    # Spot 中断が発生しても最低 1 タスクは安定稼働を保証
    weight            = 1
  }

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    base              = 0
    weight            = 4
    # weight 比 1:4 = Fargate 20% : Spot 80%
    # base 消化後の追加タスクは weight 比率で分配される
    #
    # タスク数別の分配例（コメントとして残す）:
    # 1 タスク  → Fargate:1  Spot:0  （base=1 を優先消化）
    # 2 タスク  → Fargate:1  Spot:1
    # 5 タスク  → Fargate:1  Spot:4
    # 10 タスク → Fargate:2  Spot:8  （残り 9 を 1:4 で → F:1.8→2, S:7.2→8）
  }
}
```

### terraform/ecs/cloudmap.tf を作成すること

```hcl
resource "aws_service_discovery_http_namespace" "main" {
  name = "deepdive.local"
  # Service Connect は Cloud Map の HTTP namespace を使用する
  # DNS namespace（aws_service_discovery_private_dns_namespace）とは異なり
  # Envoy サイドカーがプロキシするため DNS ではなく HTTP で解決する
}
```

### terraform/ecs/alb.tf を作成すること

**ALB**:
- `internal = false`（Public Subnet に配置、外部からテスト可能）
- subnets: `local.public_subnet_ids`
- security_groups: ALB SG

**Target Group** (API 用):
- `target_type = "ip"`（awsvpc モードでは ip 必須。インスタンス指定不可）
  コメント: 「awsvpc で各タスクが独自 ENI を持つため、IP を直接登録する」
- protocol: HTTP, port: 8080
- health_check: `path = "/health"`, `interval = 30`, `healthy_threshold = 2`

**Listener**: port 80 → forward to Target Group

**Outputs**: `alb_dns_name`, `alb_arn`, `target_group_arn`

### terraform/ecs/task_definitions.tf を作成すること

**API タスク定義** を作成すること:
- family: `deepdive-api`
- `requires_compatibilities = ["FARGATE"]`
- `network_mode = "awsvpc"`（各タスクが独立した ENI を持つ、セキュリティグループがタスク単位）
- `cpu = 512`, `memory = 1024`
- runtime_platform: `cpu_architecture = "ARM64"`, `operating_system_family = "LINUX"`
- `execution_role_arn = local.execution_role_arn`
- `task_role_arn = local.task_role_arn`

container_definitions（JSON）:
```json
[{
  "name": "api",
  "image": "<ecr_api_url>:latest",
  "essential": true,
  "portMappings": [{
    "name": "api",
    "containerPort": 8080,
    "protocol": "tcp",
    "appProtocol": "http"
  }],
  "secrets": [{
    "name": "SQS_QUEUE_URL",
    "valueFrom": "/deepdive/sqs-queue-url"
  }],
  "environment": [{
    "name": "AWS_REGION",
    "value": "ap-northeast-1"
  }],
  "logConfiguration": {
    "logDriver": "awslogs",
    "options": {
      "awslogs-group": "/ecs/deepdive/api",
      "awslogs-region": "ap-northeast-1",
      "awslogs-stream-prefix": "api"
    }
  },
  "healthCheck": {
    "command": ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://localhost:8080/health')\" || exit 1"],
    "interval": 30,
    "timeout": 5,
    "retries": 3,
    "startPeriod": 10
  },
  "linuxParameters": {
    "initProcessEnabled": true
  }
}]
```

**Worker タスク定義** を作成すること:
- family: `deepdive-worker`
- `requires_compatibilities = ["FARGATE"]`
- `network_mode = "awsvpc"`
- `cpu = 256`, `memory = 512`
- runtime_platform: ARM64 / LINUX

container_definitions:
```json
[{
  "name": "worker",
  "image": "<ecr_worker_url>:latest",
  "essential": true,
  "stopTimeout": 30,
  // ECS が SIGTERM を送ってから SIGKILL するまでの待機時間
  // ワーカーはこの 30 秒以内に現在処理中のメッセージを完了させる
  // Fargate の stopTimeout 上限は 120 秒（デフォルト 30 秒）
  "secrets": [{
    "name": "SQS_QUEUE_URL",
    "valueFrom": "/deepdive/sqs-queue-url"
  }],
  "environment": [{
    "name": "AWS_REGION",
    "value": "ap-northeast-1"
  }],
  "logConfiguration": {
    "logDriver": "awslogs",
    "options": {
      "awslogs-group": "/ecs/deepdive/worker",
      "awslogs-region": "ap-northeast-1",
      "awslogs-stream-prefix": "worker"
    }
  },
  "linuxParameters": {
    "initProcessEnabled": true
  }
}]
```

### terraform/ecs/services.tf を作成すること

**API ECS Service**:
```hcl
resource "aws_ecs_service" "api" {
  name            = "deepdive-api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = 2

  # Capacity Provider 個別指定（cluster default を上書き）
  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = 1
    weight            = 1
  }
  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    base              = 0
    weight            = 4
  }

  # Service Connect: Cloud Map HTTP namespace に登録し、Envoy サイドカーが自動注入される
  # 他サービスから "http://api:8080" でアクセス可能になる
  # Cloud Map DNS と異なり: Retry/Circuit Breaker/メトリクスが無料で使える
  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.main.arn
    service {
      port_name      = "api"  # task_definition の portMappings.name と一致させる
      discovery_name = "api"
      client_alias {
        port     = 8080
        dns_name = "api"
      }
    }
    log_configuration {
      log_driver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/deepdive/api"
        "awslogs-region"        = "ap-northeast-1"
        "awslogs-stream-prefix" = "serviceconnect"
      }
    }
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 8080
  }

  network_configuration {
    subnets          = local.private_subnet_ids
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  # タスク配置戦略（順序が意味を持つ）
  ordered_placement_strategy {
    type  = "spread"
    field = "attribute:ecs.availability-zone"
    # 理由: AZ 障害時の影響を最小化するため、まず AZ に均等分散する
  }
  ordered_placement_strategy {
    type  = "binpack"
    field = "cpu"
    # 理由: AZ 内では CPU を詰め込み、タスク密度を上げる
    # Fargate では実質的なコスト影響は少ないが EC2 起動型なら意味が大きい
    # ベストプラクティスとして設定しておくことで EC2 移行時も問題ない
  }

  # ECS Exec: コンテナ内シェルへのアクセスを有効化
  # 必要 IAM: タスクロールに ssmmessages:* 権限 (Phase 1 で設定済み)
  enable_execute_command = true

  depends_on = [aws_lb_listener.main]
}
```

**Worker ECS Service**:
```hcl
resource "aws_ecs_service" "worker" {
  name            = "deepdive-worker"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = 1

  # Worker は全タスクを Spot に振り切る
  # 処理失敗は SQS visibility timeout で自動リトライ、最終的に DLQ に流れる
  # つまり Spot 中断による中断は SQS が吸収してくれる
  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    base              = 0
    weight            = 1
  }

  network_configuration {
    subnets         = local.private_subnet_ids
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  enable_execute_command = true
}
```

### terraform/ecs/scaling.tf を作成すること

```hcl
# Worker サービスのオートスケーリング（SQS キュー深度ベース）
resource "aws_appautoscaling_target" "worker" {
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.worker.name}"
  min_capacity       = 1
  max_capacity       = 10
}

resource "aws_appautoscaling_policy" "worker_scale_out" {
  name               = "deepdive-worker-scale-out"
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = aws_appautoscaling_target.worker.resource_id
  policy_type        = "StepScaling"

  step_scaling_policy_configuration {
    adjustment_type          = "ChangeInCapacity"
    cooldown                 = 60
    metric_aggregation_type  = "Average"

    step_adjustment {
      scaling_adjustment          = 2
      metric_interval_lower_bound = 0
      metric_interval_upper_bound = 40
      # キュー深度 10〜50 のとき: +2 タスク
    }
    step_adjustment {
      scaling_adjustment          = 5
      metric_interval_lower_bound = 40
      # キュー深度 50+ のとき: +5 タスク
    }
  }
}

resource "aws_appautoscaling_policy" "worker_scale_in" {
  name               = "deepdive-worker-scale-in"
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = aws_appautoscaling_target.worker.resource_id
  policy_type        = "StepScaling"

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 120
    # スケールインは慎重に: スケールアウトの 2 倍の cooldown
    metric_aggregation_type = "Average"

    step_adjustment {
      scaling_adjustment          = -1
      metric_interval_upper_bound = 0
    }
  }
}

# CloudWatch Alarm: スケールアウトトリガー
resource "aws_cloudwatch_metric_alarm" "sqs_scale_out" {
  alarm_name          = "deepdive-sqs-scale-out"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Average"
  threshold           = 10

  dimensions = {
    QueueName = "deepdive-job-queue"
  }

  alarm_actions = [aws_appautoscaling_policy.worker_scale_out.arn]
}

resource "aws_cloudwatch_metric_alarm" "sqs_scale_in" {
  alarm_name          = "deepdive-sqs-scale-in"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Average"
  threshold           = 5

  dimensions = {
    QueueName = "deepdive-job-queue"
  }

  alarm_actions = [aws_appautoscaling_policy.worker_scale_in.arn]
}
```

---

## Step 2: Terraform 実行

```bash
cd terraform/ecs
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

---

## Step 3: 動作確認

### 基本疎通確認
```bash
ALB_DNS=$(cd terraform/ecs && terraform output -raw alb_dns_name)

# ヘルスチェック
curl -s http://$ALB_DNS/health | python3 -m json.tool

# ジョブ送信（SQS にメッセージが入ることを確認）
curl -s -X POST http://$ALB_DNS/jobs \
  -H "Content-Type: application/json" \
  -d '{"payload": "phase2-test-job-001"}' | python3 -m json.tool
```

### ECS Exec デモ（深掘りポイント ①）
```bash
CLUSTER="deepdive-ecs"

# 実行中タスク ARN を取得
TASK_ARN=$(aws ecs list-tasks \
  --cluster $CLUSTER \
  --service-name deepdive-api \
  --query 'taskArns[0]' \
  --output text)

echo "接続するタスク: $TASK_ARN"

# コンテナ内シェルを起動
# 内部動作: SSM Session Manager が ECS タスクと ssmmessages エンドポイントで通信
# 必要な権限: タスクロールの ssmmessages:* + ec2messages:* (Phase 1 で設定済み)
aws ecs execute-command \
  --cluster $CLUSTER \
  --task $TASK_ARN \
  --container api \
  --interactive \
  --command "/bin/sh"
```

シェル内で以下を確認すること:
```sh
# 環境変数の確認（SQS URL が SSM から取得されているか）
env | grep -E "SQS|AWS"

# Service Connect の動作確認（Envoy サイドカーが localhost で待ち受け）
# （別サービスからなら "http://api:8080/health" でアクセスできる）
curl -s http://localhost:8080/health

# プロセス確認（initProcessEnabled で PID 1 が init になっている）
ps aux
exit
```

### Service Connect メトリクス確認（深掘りポイント ②）
```bash
# ECS Service Connect のメトリクスが CloudWatch に送信されているか確認
aws cloudwatch list-metrics \
  --namespace "AWS/ECS/ManagedScaling" \
  --query 'Metrics[*].MetricName' \
  --output text

# Service Connect の Envoy メトリクス
aws cloudwatch list-metrics \
  --namespace "ECS/ContainerInsights" \
  --dimensions Name=ClusterName,Value=deepdive-ecs \
  --query 'Metrics[*].MetricName' \
  --output table
```

### Capacity Provider の確認（深掘りポイント ③）
```bash
# 各タスクがどの Capacity Provider で起動しているか確認
aws ecs describe-tasks \
  --cluster deepdive-ecs \
  --tasks $(aws ecs list-tasks --cluster deepdive-ecs --query 'taskArns[*]' --output text) \
  --query 'tasks[*].{id:taskArn,provider:capacityProviderName,status:lastStatus}' \
  --output table
```

### スケーリングテスト（深掘りポイント ④）
```bash
SQS_URL=$(cd terraform/foundation && terraform output -raw sqs_queue_url)

# 50 メッセージを一気に送信してスケールアウトを観察
for i in $(seq 1 50); do
  aws sqs send-message \
    --queue-url $SQS_URL \
    --message-body "load-test-${i}" \
    --message-attributes "{\"job_id\":{\"StringValue\":\"test-$(date +%s)-${i}\",\"DataType\":\"String\"}}"
done

echo "SQS にメッセージ送信完了"

# Worker タスク数の変化を観察（30 秒おきに確認）
watch -n 30 "aws ecs describe-services \
  --cluster deepdive-ecs \
  --services deepdive-worker \
  --query 'services[0].{desired:desiredCount,running:runningCount,pending:pendingCount}'"
```

**記録すること（Phase 4 比較用）**:
- CloudWatch Alarm トリガーから ECS スケールポリシー発動まで: _____ 秒
- ECS タスクが PENDING → RUNNING になるまで: _____ 秒
- スケールアウトの合計所要時間: _____ 秒

---

## Step 4: Capacity Provider の数学を確認

以下のコマンドで現在の分配を確認し、理論値と照合すること:
```bash
# タスク数とプロバイダーの対応を確認
aws ecs list-tasks --cluster deepdive-ecs --output text | \
xargs -I{} aws ecs describe-tasks --cluster deepdive-ecs --tasks {} \
  --query 'tasks[*].capacityProviderName' --output text
```

---

## Phase 2 完了チェック

- [ ] ALB 経由で `/health` が 200 を返す
- [ ] `/jobs` にリクエストを送ると SQS にメッセージが入る
- [ ] ECS Exec でコンテナ内 shell に入れた
- [ ] タスクの Capacity Provider が Fargate / Fargate Spot に分かれている
- [ ] 50 メッセージ送信でワーカーのタスク数が増加した
- [ ] スケールアウト所要時間を記録した

## 口頭説明チェック（5 分で答えられること）

1. 「base=1, weight=4 の設定で 6 タスク起動したとき、Fargate と Spot の内訳は？」
2. 「Service Connect と旧来の Cloud Map DNS（Service Discovery）の違いは何か？」
3. 「awsvpc モードと bridge モードの違い、なぜ Fargate では awsvpc しか使えないか？」
4. 「ECS Exec が動く仕組み（SSM Session Manager の役割）を説明せよ」