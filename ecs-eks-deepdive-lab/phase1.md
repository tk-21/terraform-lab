# Phase 1: Foundation — 共通インフラ構築 + アプリコンテナ Build

## このフェーズの目標

ECS/EKS 両方が使用する共通インフラを Terraform で構築し、
FastAPI API + SQS Worker コンテナを ECR へプッシュする。

---

## 前提確認

以下をチェックしてから開始すること:
```bash
aws sts get-caller-identity          # AWS CLI 認証確認
terraform version                    # >= 1.6 であること
docker buildx inspect                # arm64 ビルド可能か確認
which kubectl helm                   # Phase 3 で使用
```

---

## Step 1: アプリケーションコードの作成

### app/api/requirements.txt を作成すること
```
fastapi==0.115.0
uvicorn==0.32.0
boto3==1.35.0
structlog==24.4.0
pydantic==2.9.0
```

### app/api/main.py を作成すること

以下の仕様で実装すること:
- `POST /jobs` : pydantic モデル `JobRequest(payload: str)` を受け取り、SQS に送信
  - `job_id = str(uuid.uuid4())` を生成して MessageAttribute に含める
  - 成功時: `{"job_id": job_id, "status": "queued"}`
  - SQS 送信失敗時: HTTPException(status_code=503)
- `GET /health` : `{"status": "ok"}` を返す（ECS ヘルスチェック用、常時 200）
- 環境変数: `SQS_QUEUE_URL`, `AWS_REGION`
- structlog で JSON 構造化ログ（`job_created` / `job_send_failed` イベント）
- アプリ起動時に structlog を JSON モードで設定すること

### app/api/Dockerfile を作成すること

```dockerfile
FROM python:3.12-slim
WORKDIR /app

# セキュリティ: root 以外で実行
RUN useradd -m -u 1000 appuser

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .
USER appuser
EXPOSE 8080

# ECS の HEALTHY ヘルスチェック条件に使われる
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')" || exit 1

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
```

### app/worker/requirements.txt を作成すること
```
boto3==1.35.0
structlog==24.4.0
```

### app/worker/main.py を作成すること

以下の仕様で実装すること:
- SQS ロングポーリング: `WaitTimeSeconds=20`, `MaxNumberOfMessages=10`
- **SIGTERM ハンドラー必須**: `signal.signal(signal.SIGTERM, handler)` で
  グローバルフラグを `False` にして現在ループを最後まで実行してから終了
  （ECS Fargate Spot 中断・Karpenter ノード退避の両方に対応するため）
- メッセージ処理: `job_id` を MessageAttribute から取得してログ出力
  `time.sleep(2)` で処理をシミュレート
- 成功時: `sqs.delete_message()` でキューから削除
- 失敗時: delete しない（DLQ に流す）
- structlog で JSON ログ: `job_processing`, `job_completed`, `job_failed`, `worker_stopped`
- 環境変数: `SQS_QUEUE_URL`, `AWS_REGION`

### app/worker/Dockerfile を作成すること

api/Dockerfile と同様の構成（HEALTHCHECK なし）、
`CMD ["python", "main.py"]`

---

## Step 2: terraform/foundation/ の作成

### terraform/foundation/main.tf を作成すること

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # ラボ環境のためローカルステートを使用
  # 本番: S3 backend + DynamoDB ロック
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = "ecs-eks-deepdive"
      Environment = "lab"
      ManagedBy   = "terraform"
    }
  }
}

variable "region" {
  description = "AWS リージョン"
  default     = "ap-northeast-1"
}

variable "project" {
  description = "プロジェクト名（全リソースの命名プレフィックス）"
  default     = "deepdive"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
```

### terraform/foundation/vpc.tf を作成すること

以下の仕様で実装すること（`for_each` を使用）:

**VPC**:
- CIDR: `10.0.0.0/16`
- `enable_dns_support = true`
- `enable_dns_hostnames = true`（EKS の必須要件）

**Public Subnets**（ALB 配置用）:
```
for_each を使い以下を作成:
  "1a" = { cidr = "10.0.0.0/24",   az = "ap-northeast-1a" }
  "1c" = { cidr = "10.0.1.0/24",   az = "ap-northeast-1c" }
```
タグに `"kubernetes.io/role/elb" = "1"` を追加（AWS LBC が Public ALB 配置に参照する）

**Private Subnets**（ECS Tasks / EKS Nodes 配置用）:
```
for_each を使い以下を作成:
  "1a" = { cidr = "10.0.128.0/24", az = "ap-northeast-1a" }
  "1c" = { cidr = "10.0.129.0/24", az = "ap-northeast-1c" }
```
タグに `"kubernetes.io/role/internal-elb" = "1"` を追加

**Internet Gateway**（Public Subnet 専用）

**NAT Gateway**:
- ap-northeast-1a の Public Subnet に **1 台のみ**
- EIP を割り当てる
- コメントに「なぜ NAT GW が必要か」を記述すること:
  「EKS アドオン(Karpenter/KEDA)のコンテナイメージが ECR Public から pull されるため。
   本番では ECR pull-through cache で置き換え、NAT GW を廃止する」

**Route Tables**:
- Public: `0.0.0.0/0` → IGW
- Private: `0.0.0.0/0` → NAT GW（両 AZ のプライベートサブネットに関連付け）

**Outputs**:
```hcl
vpc_id, public_subnet_ids (list), private_subnet_ids (list),
public_subnet_id_1a, private_subnet_id_1a, private_subnet_id_1c
```

### terraform/foundation/endpoints.tf を作成すること

以下の VPC Endpoint を作成すること。
**Interface Endpoints**（for_each で一括作成、セキュリティグループ共通）:

```
エンドポイントサービス名をキーに for_each:
  "ecr.api"     : ECR API（イメージプッシュ・メタデータ）
  "ecr.dkr"     : ECR Docker レジストリ（実際のレイヤー転送）
  "logs"        : CloudWatch Logs（ECS/EKS コンテナログ送信）
  "ssm"         : SSM Parameter Store（シークレット取得）
  "ssmmessages" : ECS Exec / SSM Session Manager 通信
  "ec2messages" : SSM エージェント ↔ Systems Manager 通信
  "sts"         : IAM STS（Pod Identity / タスクロール認証トークン取得）
  "sqs"         : SQS API（ワーカーのキュー操作）
  "ec2"         : Karpenter が EC2 インスタンスを作成・削除するために必要
```

各 Interface Endpoint の設定:
- `private_dns_enabled = true`（サービス名で名前解決できるように）
- subnet_ids: private_subnet_ids
- security_group: HTTPS/443 inbound from VPC CIDR のみ

**Gateway Endpoints**（for_each で作成、ルートテーブルへの追加も忘れずに）:
```
  "s3" : ECR レイヤーストレージ・EKS Bootstrap スクリプト
```

### terraform/foundation/sqs.tf を作成すること

**Dead Letter Queue**:
- name: `${var.project}-job-dlq`
- `message_retention_seconds = 1209600`（14 日）

**Job Queue**:
- name: `${var.project}-job-queue`
- `visibility_timeout_seconds = 300`
  コメント: 「ワーカーの最大処理時間に合わせる。これより短いと処理中に可視化され二重処理が起きる」
- `message_retention_seconds = 86400`（1 日）
- `receive_wait_time_seconds = 20`
  コメント: 「ロングポーリングでポーリング回数を減らしコスト削減」
- redrive_policy: `maxReceiveCount = 3` → DLQ

**Outputs**: `sqs_queue_url`, `sqs_queue_arn`, `sqs_dlq_url`

### terraform/foundation/ecr.tf を作成すること

`for_each` を使い以下 2 リポジトリを作成:
- `api-server`
- `job-worker`

各リポジトリ:
- `image_tag_mutability = "MUTABLE"`（ラボ用。本番は IMMUTABLE）
- `scan_on_push = true`
- lifecycle_policy: `untagged` イメージを 7 日後に削除

**Outputs**: `ecr_repository_urls` (map), `ecr_api_url`, `ecr_worker_url`, `aws_account_id`

### terraform/foundation/iam.tf を作成すること

**1. ECS タスク実行ロール**（ロール名 `${var.project}-ecs-exec-role`、≤64 文字）:
- Trust: `ecs-tasks.amazonaws.com`
- Managed: `AmazonECSTaskExecutionRolePolicy`
- Inline: SSM Parameter Store 読み取り `/deepdive/*` のパスのみ許可

**2. ECS タスクロール**（ロール名 `${var.project}-ecs-task-role`、≤64 文字）:
- Trust: `ecs-tasks.amazonaws.com`
- Inline SQS 権限（対象 ARN は sqs_queue_arn のみ）:
  `sqs:SendMessage, ReceiveMessage, DeleteMessage, GetQueueAttributes, GetQueueUrl`
- Inline ECS Exec 権限（SSM Session Manager 通信）:
  `ssmmessages:CreateControlChannel, CreateDataChannel, OpenControlChannel, OpenDataChannel`

**3. EKS ノードロール**（ロール名 `${var.project}-eks-node-role`、≤64 文字）:
- Trust: `ec2.amazonaws.com`
- Managed: `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly`, `AmazonEKS_CNI_Policy`
- Instance profile も合わせて作成すること

**Outputs**: 各ロールの ARN

### terraform/foundation/ssm.tf を作成すること

以下のパラメータを作成:
- `/deepdive/sqs-queue-url` : SQS Queue URL（SecureString でなく String で可）
- `/deepdive/aws-region`    : `ap-northeast-1`

### terraform/foundation/outputs.tf を作成すること

上記全モジュールの重要な値を output すること（Phase 2/3 の Terraform が参照する）

---

## Step 3: Terraform 実行

```bash
cd terraform/foundation
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

エラーが発生した場合は原因を特定して修正し、再度 apply すること。

---

## Step 4: アプリコンテナのビルドと ECR プッシュ

Foundation の outputs から ECR URL を取得してビルド・プッシュすること:

```bash
cd terraform/foundation

ACCOUNT_ID=$(terraform output -raw aws_account_id)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.ap-northeast-1.amazonaws.com"
ECR_API=$(terraform output -raw ecr_api_url)
ECR_WORKER=$(terraform output -raw ecr_worker_url)

# ECR ログイン
aws ecr get-login-password --region ap-northeast-1 | \
  docker login --username AWS --password-stdin ${ECR_REGISTRY}

# API Server: arm64 でビルドしてプッシュ
docker buildx build \
  --platform linux/arm64 \
  --tag ${ECR_API}:latest \
  ../../app/api/ \
  --push

# Job Worker: arm64 でビルドしてプッシュ
docker buildx build \
  --platform linux/arm64 \
  --tag ${ECR_WORKER}:latest \
  ../../app/worker/ \
  --push
```

x86_64 マシンで buildx が使えない場合:
```bash
docker buildx create --use  # ビルダー作成
```

---

## Step 5: 動作確認

以下を全て確認してから Phase 2 に進むこと:

```bash
# VPC Endpoint の確認（9 件あること）
VPC_ID=$(cd terraform/foundation && terraform output -raw vpc_id)
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'VpcEndpoints[*].ServiceName' \
  --output table

# SQS キューの確認
aws sqs list-queues --queue-name-prefix deepdive

# ECR イメージの確認
aws ecr describe-images --repository-name api-server \
  --query 'imageDetails[*].{tag:imageTags[0],pushed:imagePushedAt}'
aws ecr describe-images --repository-name job-worker \
  --query 'imageDetails[*].{tag:imageTags[0],pushed:imagePushedAt}'

# SSM パラメータの確認
aws ssm get-parameters-by-path --path /deepdive/
```

---

## Phase 1 完了チェック

- [ ] `terraform apply` がエラーなく完了
- [ ] VPC Endpoint が 9 件（Interface 8 + Gateway 1）確認できる
- [ ] SQS キュー 2 件（job-queue + job-dlq）がある
- [ ] ECR に `api-server:latest` と `job-worker:latest` がある
- [ ] SSM パラメータ 2 件がある

## 口頭確認（1 分で答えられること）
「なぜ NAT Gateway を 1 台に限定し、かつ VPC Endpoint を 9 件も設定したのか？」