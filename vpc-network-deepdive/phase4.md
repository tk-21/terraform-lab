# Phase 4: カスタムPrivateLink（NLB経由）

## このフェーズのゴール

Hub VPCのサービス（Nginx on EC2）をPrivateLinkで公開し、
Spoke-Prod・Spoke-Dev から VPC Endpoint経由でプライベートにアクセスできるようにする。

これにより「VPC PeeringなしでもSpokeからHubのサービスだけを使える」
**サービスプロバイダー／コンシューマーモデル**を体験する。

**このフェーズ完了時点で説明できるようになること:**
- PrivateLinkにNLBが必要な理由（IPアドレスの固定・負荷分散）
- Endpoint ServiceとInterface Endpointの関係（プロバイダー vs コンシューマー）
- PrivateLinkがVPC Peeringと異なる点（CIDRオーバーラップが関係ない、単方向）
- ENIとNLBのターゲット登録の仕組み

---

## Previously generated（Phase 1-3で作成済み）

- `modules/vpc/` — VPCモジュール
- `modules/vpc_peering/` — Peeringモジュール
- `modules/endpoint/` — Endpointモジュール
- 3VPC + Peering + Interface/Gateway Endpoint構成

---

## 作成するファイル一覧

```
modules/
└── privatelink/
    ├── main.tf           # NLB + VPC Endpoint Service（プロバイダー側）
    ├── variables.tf
    └── outputs.tf

envs/
├── hub/
│   └── privatelink_service.tf   # Hubでサービスを公開
└── spoke_prod/
    └── privatelink_consumer.tf  # Spoke-ProdでConsumer Endpointを作成

docs/
└── adr/
    └── ADR-004_privatelink_design.md
```

---

## modules/privatelink/main.tf

```hcl
# =============================================================
# PrivateLinkのプロバイダー側（Hubに配置）
#
# 構成:
#   [Hub EC2 (Nginx)] → [NLB] → [VPC Endpoint Service]
#                                      ↓
#                           [Consumer側 Interface Endpoint]
#                                      ↓
#                         [Spoke EC2からのアクセス]
#
# NLBが必要な理由:
# PrivateLinkはNLBまたはGLB（Gateway Load Balancer）をバックエンドとして要求する
# NLBが固定のENI IPを持つことで、PrivateLinkがルーティング先を特定できる
# =============================================================

# =============================================================
# PrivateLinkのバックエンドサービス用EC2（Nginx）
# HubのプライベートサブネットにNginxを動かすEC2を配置
# =============================================================
resource "aws_security_group" "service" {
  name        = "${var.prefix}-service-sg"
  description = "PrivateLinkバックエンドNginx用SG"
  vpc_id      = var.vpc_id

  # NLBからのHTTPリクエストを許可
  # NLBはクライアントのIPをそのまま透過するため、SpokeのCIDRも許可
  ingress {
    description = "NLBからのHTTPトラフィック"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.prefix}-service-sg" })
}

data "aws_ami" "al2023_arm" {
  most_recent = true
  owners      = ["amazon"]
  filter { name = "name",         values = ["al2023-ami-*-arm64"] }
  filter { name = "architecture", values = ["arm64"] }
}

resource "aws_iam_role" "service" {
  name = "${var.prefix}-service-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.service.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "service" {
  name = "${var.prefix}-service-profile"
  role = aws_iam_role.service.name
}

resource "aws_instance" "service" {
  ami                    = data.aws_ami.al2023_arm.id
  instance_type          = "t4g.nano"
  subnet_id              = var.service_subnet_id
  iam_instance_profile   = aws_iam_instance_profile.service.name
  vpc_security_group_ids = [aws_security_group.service.id]

  # ユーザーデータでNginxを起動し、識別可能なレスポンスを返す
  user_data = base64encode(<<-EOF
    #!/bin/bash
    dnf install -y nginx
    systemctl enable --now nginx
    echo "<h1>Hub Service via PrivateLink - $(hostname)</h1>" > /usr/share/nginx/html/index.html
  EOF
  )

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"  # IMDSv2必須
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
  }

  tags = merge(var.tags, { Name = "${var.prefix}-service-ec2" })
}

# =============================================================
# Network Load Balancer
# PrivateLinkのバックエンドとして必須
# - internal = true: HubプライベートサブネットにのみENIを配置
# - cross_zone_load_balancing: マルチAZ対応
# =============================================================
resource "aws_lb" "this" {
  name               = "${var.prefix}-nlb"
  internal           = true  # インターネット向けにしない
  load_balancer_type = "network"
  subnets            = var.nlb_subnet_ids

  enable_cross_zone_load_balancing = true  # AZ間の偏りを防ぐ

  tags = merge(var.tags, { Name = "${var.prefix}-nlb" })
}

# NLBターゲットグループ（EC2をIPターゲットとして登録）
resource "aws_lb_target_group" "this" {
  name        = "${var.prefix}-tg"
  port        = 80
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    enabled             = true
    protocol            = "TCP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = merge(var.tags, { Name = "${var.prefix}-tg" })
}

resource "aws_lb_target_group_attachment" "this" {
  target_group_arn = aws_lb_target_group.this.arn
  target_id        = aws_instance.service.id
  port             = 80
}

resource "aws_lb_listener" "this" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

# =============================================================
# VPC Endpoint Service（PrivateLinkサービスの公開）
# NLBをバックエンドに指定し、ConsumerがInterface Endpointを作成できるようにする
# acceptance_required = false: Consumer側の承認なしに接続を許可（学習用）
# =============================================================
resource "aws_vpc_endpoint_service" "this" {
  acceptance_required        = false  # 本番ではtrueにして承認フローを設ける
  network_load_balancer_arns = [aws_lb.this.arn]

  # どのAWSアカウントからConsumer Endpointを作成できるかを制御
  # 同一アカウントの場合はアカウントIDを指定
  allowed_principals = var.allowed_principals

  tags = merge(var.tags, { Name = "${var.prefix}-endpoint-service" })
}
```

## modules/privatelink/variables.tf

```hcl
variable "prefix" { type = string }
variable "vpc_id" { type = string }

variable "service_subnet_id" {
  description = "NginxサービスEC2を配置するサブネットID（Hubプライベート）"
  type        = string
}

variable "nlb_subnet_ids" {
  description = "NLBのENIを配置するサブネットIDリスト（マルチAZ）"
  type        = list(string)
}

variable "allowed_cidr_blocks" {
  description = "Nginx SGへの許可CIDRリスト（NLBとSpokeのCIDR）"
  type        = list(string)
}

variable "allowed_principals" {
  description = <<-EOT
    VPC Endpoint ServiceへのアクセスをConsumerアカウントに制限。
    例: ["arn:aws:iam::123456789012:root"]
    学習用途では同一アカウントのARNを指定。
  EOT
  type = list(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}
```

## modules/privatelink/outputs.tf

```hcl
output "endpoint_service_name" {
  description = "Consumer側がInterface Endpointを作成する際に指定するService Name"
  value       = aws_vpc_endpoint_service.this.service_name
}

output "nlb_arn" {
  value = aws_lb.this.arn
}

output "service_instance_id" {
  description = "Session Managerでのログイン確認用"
  value       = aws_instance.service.id
}
```

---

## envs/hub/privatelink_service.tf

```hcl
# =============================================================
# Hub VPCでPrivateLinkサービスを公開する
# =============================================================

# 現在のAWSアカウントIDを動的に取得
data "aws_caller_identity" "current" {}

module "privatelink_service" {
  source = "../../modules/privatelink"

  prefix = "${local.prefix}-svc"

  vpc_id            = module.vpc.vpc_id
  service_subnet_id = module.vpc.subnet_ids["private-1a"]
  nlb_subnet_ids    = module.vpc.private_subnet_ids

  # Nginxへのアクセス元: NLBは自VPC CIDRから転送
  # NLBのヘルスチェックとSpokeからの転送元を許可
  allowed_cidr_blocks = [
    "10.0.0.0/16",  # Hub VPC（NLBからEC2へ）
    "10.1.0.0/16",  # Spoke-Prod（NLBの透過転送でクライアントIPが見える場合）
    "10.2.0.0/16",  # Spoke-Dev
  ]

  # 同一AWSアカウントからのConsumer Endpointを許可
  allowed_principals = [
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
  ]

  tags = local.common_tags
}

output "privatelink_service_name" {
  description = "Spoke側にEndpointを作成するときに使用するService Name"
  value       = module.privatelink_service.endpoint_service_name
}
```

---

## envs/spoke_prod/privatelink_consumer.tf

```hcl
# =============================================================
# Spoke-ProdでHub公開サービスへのConsumer Interface Endpointを作成
# VPC Peeringなしでも、このEndpoint経由でHubのNginxにアクセス可能
# =============================================================

# Hub側のTerraform stateからService Nameを取得
data "terraform_remote_state" "hub" {
  backend = "local"
  config = {
    path = "../../hub/terraform.tfstate"
  }
}

# PrivateLinkのConsumer用SG
resource "aws_security_group" "privatelink_consumer" {
  name        = "${local.prefix}-pl-consumer-sg"
  description = "PrivateLink Consumer Endpoint用SG"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "EC2からのHTTPアクセス（Hubサービスへ）"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-pl-consumer-sg"
  })
}

# Consumer側Interface Endpoint
# このENIのIPにアクセスすることでHub NLB → Nginx にパケットが届く
resource "aws_vpc_endpoint" "hub_service" {
  vpc_id              = module.vpc.vpc_id
  service_name        = data.terraform_remote_state.hub.outputs.privatelink_service_name
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnet_ids
  security_group_ids  = [aws_security_group.privatelink_consumer.id]

  # カスタムPrivateLinkではDNSの自動解決が効かないため
  # private_dns_enabled = false にしてENIのIPで直接アクセスする
  # （Hub側でRoute53プライベートホストゾーンを設定すれば名前解決も可能）
  private_dns_enabled = false

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-hub-service-endpoint"
  })
}

output "hub_service_endpoint_dns" {
  description = "Hub Nginxにアクセスする際のDNS名（curlで確認）"
  value       = aws_vpc_endpoint.hub_service.dns_entry
}
```

---

## docs/adr/ADR-004_privatelink_design.md

```markdown
# ADR-004: カスタムPrivateLinkの設計判断

## ステータス
採用

## コンテキスト
HubがホストするWebサービス（Nginx）をSpokeに安全に公開したい。

## 決定
**PrivateLink（NLB + VPC Endpoint Service）を採用する**

## PrivateLinkとVPC Peeringの本質的な違い

| 観点 | VPC Peering | PrivateLink |
|---|---|---|
| 通信方向 | 双方向（お互いのVPC全体にルーティング） | 単方向（公開サービスのみ） |
| CIDRオーバーラップ | 不可 | 可（関係ない） |
| 公開粒度 | VPC全体 | 特定サービス（NLBポート）のみ |
| コスト | 無料（転送量のみ） | $0.014/時/AZ + 処理データ量 |
| ユースケース | 社内VPC間の自由な通信 | SaaSモデル・最小権限サービス公開 |

## NLBが必要な理由

PrivateLinkはバックエンドとしてNLBまたはGLBを要求する。

理由:
1. **IPアドレスの固定**: NLBはENIに固定IPを割り当てる。
   PrivateLinkはそのIPをConsumer側ENIのルーティング先として使用する。
2. **ヘルスチェック**: NLBが背後のEC2の健全性を確認する。
   不健全なターゲットへのルーティングを回避できる。
3. **スケーラビリティ**: EC2が増えてもNLBがトラフィックを分散する。

## acceptance_required = false の採用理由
学習用途のため承認フロー不要。
本番では `true` にし、`aws ec2 accept-vpc-endpoint-connections` で手動承認する。
```

---

## 実行手順

```bash
# Hub側でサービスを公開
cd envs/hub
terraform apply  # privatelink_service.tf を追加後

# Service Nameを確認（Spoke側設定に必要）
terraform output privatelink_service_name

# Spoke-Prod側でConsumer Endpointを作成
cd ../spoke_prod
terraform apply  # privatelink_consumer.tf を追加後

# Endpoint DNSを確認
terraform output hub_service_endpoint_dns
```

## 検証手順

```bash
# Spoke-ProdのEC2にSession Managerで接続
aws ssm start-session --target $(terraform -chdir=envs/spoke_prod output -raw bastion_instance_id)

# EC2内でPrivateLink経由のNginxへアクセス（EndpointのDNS名を使用）
# PrivateLinkのDNS名は terraform output hub_service_endpoint_dns で確認
curl http://<endpoint-dns-name>
# → "<h1>Hub Service via PrivateLink - ip-10-0-xx-xx</h1>" が返ればOK

# VPC Peering経由でなくPrivateLink経由であることの確認
# → Hubの10.0.x.x ではなく、Endpoint ENIのIPに向いていることをtracerouteで確認
traceroute <endpoint-dns-name>
```

## コスト見積もり（Phase4追加分）

| リソース | 単価 | 想定時間 | コスト |
|---|---|---|---|
| NLB | $0.0243/時 | 2時間 | $0.05 |
| Endpoint Service (NLB) | 無料 | — | $0 |
| Consumer Interface Endpoint | $0.014/時/AZ × 2AZ | 2時間 | $0.06 |
| EC2 t4g.nano（Hub service） | $0.0052/時 | 2時間 | $0.01 |
| **合計** | | | **$0.12** |

## Phase 4 完了チェックリスト

- [ ] Hub VPCにNLBが作成されている（internal）
- [ ] Hub VPCにVPC Endpoint Serviceが作成されている
- [ ] Spoke-ProdにConsumer Interface Endpointが作成されている
- [ ] Spoke-ProdのEC2からcurlでNginxレスポンスが返る
- [ ] VPC PeeringがなくてもPrivateLink経由でアクセスできることを確認
- [ ] 口頭説明: 「PrivateLinkとVPC Peeringの本質的な違い」を図付きで説明できる

## 全フェーズ完了後のリソース削除

```bash
# コスト発生リソースを逆順で削除
cd envs/spoke_prod && terraform destroy
cd ../spoke_dev && terraform destroy
cd ../hub && terraform destroy
```