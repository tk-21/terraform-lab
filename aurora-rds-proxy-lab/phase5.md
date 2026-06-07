# ✅Phase 5 — ECS Fargate アプリ + ALB

## 前フェーズ確認

```bash
# appuser でシークレットが有効化されていること
aws secretsmanager describe-secret \
  --secret-id arpl/db/appuser \
  --query 'RotationEnabled' --output text
# true
```

## このフェーズのゴール

- FastAPI アプリを ECS Fargate (arm64/FARGATE_SPOT) でデプロイ
- RDS Proxy に **IAM 認証トークン** で接続（パスワードをコード・環境変数に持たない）
- ALB でインターネット公開し `/health` と `/items` エンドポイントを動作確認

---

## Step 5-1: FastAPI アプリケーション

### `app/requirements.txt`

```
fastapi==0.111.0
uvicorn[standard]==0.29.0
psycopg[binary]==3.1.18
boto3==1.34.0
aws-lambda-powertools==2.36.1
```

### `app/db/connection.py`

```python
"""
RDS Proxy IAM 認証による接続管理

IAM 認証フロー:
1. ECS タスクロールで boto3 が IAM 認証トークンを生成（15分有効）
2. トークンをパスワードとして RDS Proxy に渡す
3. Proxy がトークンを検証し、Aurora には Secrets Manager のパスワードで接続
→ アプリコードに DB パスワードが一切現れない
"""
import os
import boto3
import psycopg
from contextlib import asynccontextmanager
from aws_lambda_powertools import Logger

logger = Logger(service="aurora-rds-proxy-lab")

# 起動時に SSM から取得してキャッシュ
_ssm = boto3.client("ssm", region_name=os.environ.get("AWS_REGION", "ap-northeast-1"))
_rds = boto3.client("rds", region_name=os.environ.get("AWS_REGION", "ap-northeast-1"))

_proxy_endpoint: str = ""
_db_name: str = ""


def _get_ssm(param_name: str) -> str:
    """SSM Parameter Store から値を取得"""
    return _ssm.get_parameter(Name=param_name)["Parameter"]["Value"]


def _generate_iam_token(host: str, port: int, db_user: str) -> str:
    """
    IAM 認証トークン生成
    有効期限 15 分 → 接続ごとに生成してもオーバーヘッドは小さい
    本番では接続プールと組み合わせて 10 分ごとに更新する
    """
    return _rds.generate_db_auth_token(
        DBHostname=host,
        Port=port,
        DBUsername=db_user,
        Region=os.environ.get("AWS_REGION", "ap-northeast-1"),
    )


def init_db_config() -> None:
    """アプリ起動時に DB 設定を初期化"""
    global _proxy_endpoint, _db_name
    _proxy_endpoint = _get_ssm(os.environ["PROXY_ENDPOINT_PARAM"])
    _db_name = _get_ssm(os.environ["DB_NAME_PARAM"])
    logger.info("DB設定初期化完了", extra={"proxy_endpoint": _proxy_endpoint})


def get_connection() -> psycopg.Connection:
    """
    RDS Proxy に IAM 認証で接続して返す
    呼び出し元は with ステートメントで使用すること
    """
    db_user = os.environ.get("DB_USER", "appuser")
    token = _generate_iam_token(_proxy_endpoint, 5432, db_user)

    conn_str = (
        f"host={_proxy_endpoint} "
        f"port=5432 "
        f"dbname={_db_name} "
        f"user={db_user} "
        f"password={token} "
        f"sslmode=require"  # Proxy の require_tls=true に対応
    )
    return psycopg.connect(conn_str)
```

### `app/main.py`

```python
"""FastAPI エントリポイント"""
from contextlib import asynccontextmanager
import os

from fastapi import FastAPI
from aws_lambda_powertools import Logger

from db.connection import init_db_config
from api import health, items

logger = Logger(service="aurora-rds-proxy-lab")


@asynccontextmanager
async def lifespan(app: FastAPI):
    """アプリ起動時に DB 設定を初期化"""
    init_db_config()
    yield


app = FastAPI(title="aurora-rds-proxy-lab", lifespan=lifespan)
app.include_router(health.router)
app.include_router(items.router)
```

### `app/api/health.py`

```python
from fastapi import APIRouter
from db.connection import get_connection

router = APIRouter()

@router.get("/health")
def health_check():
    """ALB ヘルスチェック用エンドポイント + DB 接続確認"""
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT 1")
    return {"status": "healthy", "db": "connected"}
```

### `app/api/items.py`

```python
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from db.connection import get_connection

router = APIRouter(prefix="/items")

class Item(BaseModel):
    name: str

@router.get("/")
def list_items():
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT id, name, created_at FROM items ORDER BY id")
            rows = cur.fetchall()
    return [{"id": r[0], "name": r[1], "created_at": str(r[2])} for r in rows]

@router.post("/")
def create_item(item: Item):
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO items (name) VALUES (%s) RETURNING id, name, created_at",
                (item.name,),
            )
            row = cur.fetchone()
            conn.commit()
    return {"id": row[0], "name": row[1], "created_at": str(row[2])}
```

### `app/Dockerfile`

```dockerfile
# arm64 (Graviton2) 向けイメージ
FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# 非 root ユーザーで実行（最小権限）
RUN useradd -m appuser
USER appuser

EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
```

---

## Step 5-2: ECS モジュール

### `terraform/modules/ecs-app/main.tf`

```hcl
# =============================================================
# ECS Fargate アプリケーション構成
# - FARGATE_SPOT でコスト最適化（Spot 中断時の再接続は RDS Proxy が吸収）
# - arm64 (Graviton2): 同等性能で x86 比 ~20% コスト削減
# - パスワードを一切環境変数に渡さず IAM 認証トークンを使用
# =============================================================

variable "prefix"                  {}
variable "vpc_id"                  {}
variable "public_subnet_ids"       { type = list(string) }
variable "private_app_subnet_ids"  { type = list(string) }
variable "proxy_sg_id"             {}
variable "app_rds_connect_policy_arn" {}
variable "aws_region"              { default = "ap-northeast-1" }
variable "aws_account_id"         {}
variable "ecr_image_uri"          {}

# ─── ECR リポジトリ ────────────────────────────────────────────
resource "aws_ecr_repository" "app" {
  name                 = "${var.prefix}-app"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true # プッシュ時に脆弱性スキャン
  }
}

# ─── セキュリティグループ ──────────────────────────────────────
resource "aws_security_group" "alb" {
  name   = "${var.prefix}-alb-sg"
  vpc_id = var.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "インターネットからの HTTP"
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "app" {
  name   = "${var.prefix}-app-sg"
  vpc_id = var.vpc_id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "ALBからのトラフィックのみ"
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ─── ALB ─────────────────────────────────────────────────────
resource "aws_lb" "app" {
  name               = "${var.prefix}-alb"
  internal           = false # インターネット公開（検証用）
  load_balancer_type = "application"
  subnets            = var.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]
}

resource "aws_lb_target_group" "app" {
  name        = "${var.prefix}-app-tg"
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip" # Fargate は IP ターゲット
  vpc_id      = var.vpc_id

  health_check {
    path                = "/health"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "app" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ─── ECS Cluster ─────────────────────────────────────────────
resource "aws_ecs_cluster" "main" {
  name = "${var.prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled" # Container Insights で詳細メトリクス収集
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name = aws_ecs_cluster.main.name

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 4 # 80% を SPOT
    base              = 0
  }
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1 # 20% を オンデマンド（Spot 中断時のバッファ）
    base              = 1 # 最低 1 タスクは FARGATE 保証
  }
}

# ─── IAM Roles ───────────────────────────────────────────────
# Task Execution Role: ECR/CloudWatch へのアクセス
resource "aws_iam_role" "task_execution" {
  name = "${var.prefix}-ecs-exec-role"

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
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Task Role: アプリが使う権限（RDS Proxy, SSM）
resource "aws_iam_role" "task" {
  name = "${var.prefix}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# RDS Proxy IAM 認証権限（Phase 3 で作成したポリシー）
resource "aws_iam_role_policy_attachment" "task_rds" {
  role       = aws_iam_role.task.name
  policy_arn = var.app_rds_connect_policy_arn
}

# SSM Parameter Store 読み取り権限
resource "aws_iam_role_policy" "task_ssm" {
  name = "${var.prefix}-task-ssm-policy"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "GetSSMParameters"
      Effect = "Allow"
      Action = ["ssm:GetParameter"]
      Resource = [
        "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/arpl/*"
      ]
    }]
  })
}

# ─── ECS Task Definition ──────────────────────────────────────
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.prefix}-app"
  retention_in_days = 7
}

resource "aws_ecs_task_definition" "app" {
  family                   = "${var.prefix}-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256  # 0.25 vCPU
  memory                   = 512  # 512 MB
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  # arm64 (Graviton2) 指定
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([{
    name      = "app"
    image     = var.ecr_image_uri
    essential = true

    portMappings = [{
      containerPort = 8080
      protocol      = "tcp"
    }]

    # パスワード系は一切渡さない
    # DB 接続は IAM 認証トークンを使用し、エンドポイントは SSM から取得
    environment = [
      { name = "PROXY_ENDPOINT_PARAM", value = "/arpl/rds-proxy/endpoint" },
      { name = "DB_NAME_PARAM",        value = "/arpl/rds/db-name" },
      { name = "DB_USER",              value = "appuser" },
      { name = "AWS_REGION",           value = var.aws_region },
      { name = "LOG_LEVEL",            value = "INFO" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "ecs"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "curl -f http://localhost:8080/health || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }
  }])
}

# ─── ECS Service ─────────────────────────────────────────────
resource "aws_ecs_service" "app" {
  name            = "${var.prefix}-app-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 2 # 2 AZ に分散

  # Capacity Provider（FARGATE_SPOT 優先）
  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 4
    base              = 0
  }
  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }

  network_configuration {
    subnets          = var.private_app_subnet_ids
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false # Private Subnet なのでパブリック IP 不要
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = 8080
  }

  # ローリングデプロイ設定
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  depends_on = [aws_lb_listener.app]
}

output "alb_dns_name"  { value = aws_lb.app.dns_name }
output "ecr_repo_url"  { value = aws_ecr_repository.app.repository_url }
output "app_sg_id"     { value = aws_security_group.app.id }
```

---

## Step 5-3: GitHub Actions ワークフロー

### `.github/workflows/deploy.yml`

```yaml
name: Build and Deploy

on:
  push:
    branches: [main]
    paths: [app/**]

permissions:
  id-token: write  # OIDC トークン取得に必須
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS Credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/arpl-github-actions-role
          aws-region: ap-northeast-1

      - name: Login to ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build and Push (arm64)
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          ECR_REPOSITORY: arpl-app
          IMAGE_TAG: ${{ github.sha }}
        run: |
          docker buildx build \
            --platform linux/arm64 \
            --push \
            -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG \
            -t $ECR_REGISTRY/$ECR_REPOSITORY:latest \
            app/

      - name: Deploy to ECS
        run: |
          aws ecs update-service \
            --cluster arpl-cluster \
            --service arpl-app-service \
            --force-new-deployment \
            --region ap-northeast-1
```

---

## Step 5-4: 実行・検証

```bash
# ECR へのイメージプッシュ（初回は手動）
ECR_URL=$(cd terraform/environments/dev && terraform output -raw ecr_repo_url)
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

aws ecr get-login-password --region ap-northeast-1 | \
  docker login --username AWS --password-stdin $ECR_URL

docker buildx build \
  --platform linux/arm64 \
  --push \
  -t $ECR_URL:latest \
  app/

# ECS モジュールに ECR URI を渡して terraform apply
cd terraform/environments/dev
# main.tf の module "ecs_app" に ecr_image_uri を追記してから:
terraform apply

# ALB エンドポイント確認
ALB_DNS=$(terraform output -raw alb_dns_name)
echo "ALB: http://$ALB_DNS"

# 動作確認
curl http://$ALB_DNS/health
curl http://$ALB_DNS/items
curl -X POST http://$ALB_DNS/items \
  -H 'Content-Type: application/json' \
  -d '{"name": "hello-aurora"}'
```

---

## フェーズ完了チェック

- [ ] ECS サービスが `RUNNING` 状態
- [ ] `/health` が `{"status": "healthy", "db": "connected"}` を返す
- [ ] `/items` に GET/POST でデータ読み書きできる
- [ ] CloudWatch Logs にアプリログが出力されている
- [ ] ECS タスクが DB パスワードを環境変数に持っていない（コンソールで確認）
- [ ] GitHub Actions が OIDC で deploy できる

## 口頭説明チェック（Phase 5）

以下を5分で説明できること:

1. ECS タスクが RDS Proxy に接続するまでの完全なフロー（IAM → Proxy → Aurora）
2. FARGATE_SPOT 中断時にアプリへの影響が最小化される理由（RDS Proxy が接続を保持）
3. arm64 と x86_64 の違いと Graviton2 選択理由