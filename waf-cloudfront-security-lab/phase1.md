# Phase 1 — 基盤構築（VPC・ECS Fargate オリジン・ALB）

## このフェーズの目的

CloudFront + WAF のオリジンとなる ECS Fargate サービスを構築する。
WAF の保護対象が「何を守るのか」を具体的に持つことで、
後続フェーズのルール設計に意味が生まれる。

## 完了条件

- [ ] VPC（パブリック/プライベートサブネット 各 2AZ）が作成されている
- [ ] ECS Fargate で Nginx コンテナが起動している
- [ ] ALB 経由で HTTP/HTTPS アクセスが通る
- [ ] ACM 証明書が発行されている（ALB 用・CloudFront 用）
- [ ] Terraform backend（S3 + DynamoDB）が初期化されている
- [ ] `terraform output` で ALB の DNS 名が確認できる

---

## 作成するファイル一覧

```
waf-cloudfront-security-lab/
├── terraform/
│   ├── backend.tf
│   ├── versions.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── main.tf
│   └── modules/
│       └── origin/
│           ├── main.tf
│           ├── variables.tf
│           └── outputs.tf
└── README.md（プロジェクト概要のみ記載）
```

---

## 実装指示

### terraform/backend.tf

```hcl
# リモートステート設定
# バケット名・DynamoDB テーブル名は事前に手動作成すること
terraform {
  backend "s3" {
    bucket         = "wcsl-tfstate-{YOUR_ACCOUNT_ID}"
    key            = "waf-cloudfront-security-lab/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "wcsl-tfstate-lock"
    encrypt        = true
  }
}
```

### terraform/versions.tf

以下の条件で作成すること：
- `required_version = ">= 1.9"`
- AWS provider `~> 5.0`、リージョン `ap-northeast-1`
- **追加**: `us-east-1` プロバイダーを `aws.use1` エイリアスで定義
  （Lambda@Edge・WAF CloudFront スコープは us-east-1 必須のため）

### terraform/variables.tf

以下の変数を定義すること：
| 変数名 | 型 | デフォルト | 説明 |
|--------|----|-----------|------|
| `project` | string | `"wcsl"` | プロジェクトプレフィックス |
| `env` | string | `"dev"` | 環境名 |
| `region` | string | `"ap-northeast-1"` | メインリージョン |
| `vpc_cidr` | string | `"10.0.0.0/16"` | VPC CIDR |
| `container_image` | string | `"nginx:alpine"` | オリジンコンテナイメージ |
| `chatwork_room_id` | string | — | Chatwork 通知先 Room ID |

### terraform/main.tf

`module "origin"` を呼び出す。以下を渡すこと：
- `project`, `env`, `vpc_cidr`, `container_image`

### modules/origin/main.tf

以下のリソースを実装すること：

**VPC・ネットワーク**
```
aws_vpc
aws_subnet（パブリック × 2、プライベート × 2）
aws_internet_gateway
aws_route_table（パブリック用）
aws_route_table_association
```

NAT Gateway は**作成しない**。
プライベートサブネットからの外部通信は VPC Endpoint を使用。

**VPC Endpoint**（プライベートサブネット内の ECS が使用）
```
aws_vpc_endpoint（ECR API: com.amazonaws.ap-northeast-1.ecr.api）
aws_vpc_endpoint（ECR DKR: com.amazonaws.ap-northeast-1.ecr.dkr）
aws_vpc_endpoint（S3 Gateway: com.amazonaws.ap-northeast-1.s3）
aws_vpc_endpoint（CloudWatch Logs: com.amazonaws.ap-northeast-1.logs）
aws_vpc_endpoint（SSM: com.amazonaws.ap-northeast-1.ssm）
```

**セキュリティグループ**
```
aws_security_group（ALB 用: 0.0.0.0/0 から 443 インバウンド）
aws_security_group（ECS 用: ALB SG からのみインバウンド許可）
```

**ACM 証明書**
```
aws_acm_certificate（ALB 用: ap-northeast-1）
aws_acm_certificate（CloudFront 用: us-east-1、provider = aws.use1）
aws_acm_certificate_validation（両方）
```
※ ドメインは variables で受け取ること。DNS 検証を使用。

**ALB**
```
aws_lb（internal = false、type = "application"）
aws_lb_target_group（type = "ip"、health_check path = "/health"）
aws_lb_listener（443、ACM 証明書使用）
aws_lb_listener（80 → 443 リダイレクト）
```

**ECS**
```
aws_ecs_cluster（wcsl-{env}-cluster）
aws_ecs_task_definition
  - family: wcsl-{env}-origin
  - cpu: 256, memory: 512
  - network_mode: awsvpc
  - requires_compatibilities: ["FARGATE"]
  - runtime_platform: LINUX/ARM64（Graviton2）
  - コンテナ: nginx:alpine、ポート 80
aws_ecs_service
  - launch_type: FARGATE
  - capacity_provider_strategy: FARGATE_SPOT（weight=4）+ FARGATE（weight=1）
  - desired_count: 2
  - load_balancer: ALB ターゲットグループに接続
```

**IAM**（ECS タスク実行ロール）
```
aws_iam_role（wcsl-{env}-ecs-task-exec: 64 文字以内）
aws_iam_role_policy_attachment（AmazonECSTaskExecutionRolePolicy）
aws_iam_policy（ECR・CloudWatch Logs への最小権限カスタムポリシー）
```

**インラインコメント**
全リソースに日本語コメントで設計意図を記述すること。
例：
```hcl
# ECS タスクを ARM64 で起動することで Graviton2 の約 20% コスト削減を実現
# FARGATE_SPOT を主軸にすることで通常 FARGATE 比さらに最大 70% 削減
```

### modules/origin/outputs.tf

以下を出力すること：
- `alb_dns_name`
- `alb_arn`
- `vpc_id`
- `private_subnet_ids`
- `public_subnet_ids`
- `ecs_cluster_arn`
- `alb_security_group_id`

---

## 動作確認手順

フェーズ完了後、以下を実行して確認すること：

```bash
# 1. Terraform 初期化・適用
cd terraform
terraform init
terraform plan
terraform apply

# 2. ALB 経由でアクセス確認
ALB_DNS=$(terraform output -raw alb_dns_name)
curl -I https://${ALB_DNS}
# → HTTP/2 200 が返ること

# 3. ヘルスチェック確認
curl https://${ALB_DNS}/health
# → 200 OK が返ること
```

---

## 口頭説明チェック（フェーズ 1 完了後）

以下を自分の言葉で説明できるか確認すること：

1. **なぜ NAT Gateway を使わないのか**
   VPC Endpoint との違い、コスト面・セキュリティ面のトレードオフ

2. **FARGATE_SPOT と通常 FARGATE の使い分け**
   Spot が中断された場合の挙動、本番での運用可否

3. **ACM を 2 リージョンで発行する理由**
   CloudFront が us-east-1 の証明書しか使えない制約の背景

4. **ALB のセキュリティグループ設計**
   CloudFront からのみ通信を許可する設計に向けた準備（フェーズ 2 で対応）

---

## 次フェーズへの引き継ぎ情報

Phase 2 で必要になる値：
- `alb_arn`（WAF WebACL のアタッチ先）
- `alb_dns_name`（CloudFront のオリジンドメイン）
- `vpc_id`（WAF ログ配信用 Kinesis のサブネット指定）