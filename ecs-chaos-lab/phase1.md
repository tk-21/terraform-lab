# ✅Phase 1 — VPC / SG / ECR / ALB

## このフェーズのゴール

ECS Fargate と FIS が動作するネットワーク基盤、ECR リポジトリ、ALB を構築する。

生成するファイル:
- `app/Dockerfile` + `app/html/index.html`
- `terraform/modules/vpc/`
- `terraform/modules/sg/`
- `terraform/modules/ecr/`
- `terraform/modules/alb/`
- `terraform/environments/dev/` の骨格ファイル群

---

## 前提

- CLAUDE.md の命名規則・タグ・リージョン・コスト方針を遵守
- プレフィックス `ecl`、リージョン `ap-northeast-1`
- コメントは日本語で設計意図を記述

---

## 生成指示

### 1. `app/Dockerfile`

```dockerfile
FROM nginx:alpine

# ヘルスチェックエンドポイントと静的コンテンツを配置
COPY html/ /usr/share/nginx/html/

# /health エンドポイント用の設定
RUN echo 'server { \
    listen 80; \
    location /health { \
        access_log off; \
        return 200 "ok\n"; \
        add_header Content-Type text/plain; \
    } \
    location / { \
        root /usr/share/nginx/html; \
        index index.html; \
    } \
}' > /etc/nginx/conf.d/default.conf

EXPOSE 80
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
    CMD wget -qO- http://localhost/health || exit 1
```

### 2. `app/html/index.html`

シンプルな HTML:
```html
<!DOCTYPE html>
<html>
<head><title>ECS Chaos Lab</title></head>
<body>
  <h1>ecs-chaos-lab</h1>
  <p>ECS Fargate + FIS カオスエンジニアリング検証環境</p>
</body>
</html>
```

### 3. `terraform/environments/dev/versions.tf`

```hcl
# Terraform / プロバイダーバージョン固定
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # S3 バックエンド
  # 注意: バケット名は事前に手動作成が必要
  # aws s3 mb s3://ecl-tfstate-ACCOUNT_ID --region ap-northeast-1
  # aws dynamodb create-table --table-name ecl-tfstate-lock \
  #   --attribute-definitions AttributeName=LockID,AttributeType=S \
  #   --key-schema AttributeName=LockID,KeyType=HASH \
  #   --billing-mode PAY_PER_REQUEST --region ap-northeast-1
  backend "s3" {
    bucket         = "ecl-tfstate-REPLACE_ME"  # account_id に置換
    key            = "ecs-chaos-lab/dev/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "ecl-tfstate-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "ecs-chaos-lab"
      ManagedBy = "terraform"
    }
  }
}
```

### 4. `terraform/environments/dev/variables.tf`

以下の変数を定義（型・説明・デフォルト値あり）:

```
prefix                 = "ecl"
env                    = "dev"
aws_region             = "ap-northeast-1"
account_id             # デフォルトなし（terraform.tfvars で設定）
vpc_cidr               = "10.1.0.0/16"   # chaos-engineering-lab(10.0.x)と被らない
public_subnet_cidrs    = ["10.1.1.0/24", "10.1.2.0/24"]
private_subnet_cidrs   = ["10.1.11.0/24", "10.1.12.0/24"]
availability_zones     = ["ap-northeast-1a", "ap-northeast-1c"]
ecs_task_cpu           = 256   # 0.25 vCPU
ecs_task_memory        = 512   # 0.5 GB
ecs_desired_count      = 2
container_port         = 80
```

### 5. `terraform/environments/dev/locals.tf`

```hcl
locals {
  # 共通タグ（versions.tf の default_tags に追加するタグ）
  common_tags = {
    Env = var.env
  }

  # ECR イメージ URI（bootstrap.sh でプッシュ後に参照）
  ecr_image_uri = "${var.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${var.prefix}-${var.env}-nginx:latest"
}
```

### 6. `terraform/environments/dev/terraform.tfvars`

```hcl
prefix     = "ecl"
env        = "dev"
aws_region = "ap-northeast-1"
account_id = ""  # 実行前に設定: $(aws sts get-caller-identity --query Account --output text)
```

### 7. `terraform/modules/vpc/main.tf`

chaos-engineering-lab の vpc モジュールと同等の構成で生成:

```
aws_vpc                    # ecl-{env}-vpc, CIDR 10.1.0.0/16, DNS 有効
aws_internet_gateway       # ecl-{env}-igw
aws_subnet (public × 2)   # ecl-{env}-public-{az}
aws_subnet (private × 2)  # ecl-{env}-private-{az}
aws_eip                    # NAT GW 用（1AZ のみ：コスト削減）
aws_nat_gateway            # ecl-{env}-ngw（1a サブネット）
aws_route_table (public)   # IGW ルート
aws_route_table (private)  # NAT GW ルート
aws_route_table_association (× 4)
```

`variables.tf`: vpc_cidr, public_subnet_cidrs, private_subnet_cidrs, availability_zones, prefix, env, tags
`outputs.tf`: vpc_id, public_subnet_ids, private_subnet_ids

### 8. `terraform/modules/sg/main.tf`

**ALB SG (`ecl-{env}-alb-sg`)**:
- Ingress: TCP 80, 0.0.0.0/0
- Egress: 全許可

**ECS Task SG (`ecl-{env}-ecs-task-sg`)**:
- Ingress: TCP 80, source = ALB SG のみ
  ```
  # コメント: Fargate awsvpc モードでは Task に ENI が割り当てられる。
  # ALB からのみ通信を許可し、直接アクセスを禁止。
  # FIS ネットワーク遮断実験はこの ENI レベルで動作する。
  ```
- Egress: 全許可（ECR イメージ pull / CloudWatch Logs 送信に必要）

`variables.tf`: vpc_id, prefix, env, tags
`outputs.tf`: alb_sg_id, ecs_task_sg_id

### 9. `terraform/modules/ecr/main.tf`

```
aws_ecr_repository         # ecl-{env}-nginx
  image_tag_mutability: MUTABLE
  image_scanning_configuration: { scan_on_push = true }

aws_ecr_lifecycle_policy   # 最新 5 世代のみ保持（コスト削減）
  policy: JSON で untaggedImageCountMoreThan = 5 のルール

aws_ecr_repository_policy  # 同一アカウントの ECS タスクのみプル可能
```

`variables.tf`: prefix, env, account_id, tags
`outputs.tf`: repository_url, repository_arn

### 10. `terraform/modules/alb/main.tf`

```
aws_lb                     # ecl-{env}-alb, internet-facing, public subnet
aws_lb_target_group        # ecl-{env}-tg
  target_type: ip          # ← Fargate awsvpc モードでは "ip" 必須
  protocol: HTTP, port: 80
  health_check:
    path: /health
    healthy_threshold: 2
    unhealthy_threshold: 3
    interval: 15           # FIS 実験中のヘルス変化を素早く検知
    timeout: 5
aws_lb_listener            # HTTP:80 → TG転送
```

> コメント: target_type = "ip" は Fargate 必須設定。
> "instance" を指定すると Task が TG に登録されない。

`variables.tf`: vpc_id, public_subnet_ids, alb_sg_id, prefix, env, account_id, tags
`outputs.tf`: alb_arn, alb_dns_name, target_group_arn

### 11. `terraform/environments/dev/main.tf`（Phase 1 骨格）

```hcl
module "vpc" { ... }
module "sg"  { ... depends_on = [module.vpc] }
module "ecr" { ... }
module "alb" { ... depends_on = [module.sg] }

# Phase 2 以降（コメントアウト）
# module "iam" { ... }
# module "ecs" { ... }
# module "fis" { ... }
```

`outputs.tf`:
- vpc_id, public_subnet_ids, private_subnet_ids
- alb_sg_id, ecs_task_sg_id
- alb_dns_name, target_group_arn
- ecr_repository_url

---

## 完了条件

- [ ] `terraform fmt -recursive` が通ること
- [ ] `terraform validate` が通ること
- [ ] ALB の target_type が `"ip"` になっていること（Fargate 必須）
- [ ] ALB ヘルスチェックパスが `/health` でインターバルが 15 秒以下であること
- [ ] ECR ライフサイクルポリシーが設定されていること
- [ ] ECS Task SG の Ingress が ALB SG のみに制限されていること
- [ ] VPC CIDR が `10.1.0.0/16`（chaos-engineering-lab と競合しない）

---

## 次フェーズへの引き継ぎ情報

Phase 2 で必要な値:
- `module.vpc.vpc_id`
- `module.vpc.private_subnet_ids`（ECS Task 配置先）
- `module.sg.ecs_task_sg_id`
- `module.alb.target_group_arn`
- `module.ecr.repository_url`