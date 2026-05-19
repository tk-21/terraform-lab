# Phase 3: VPC Endpoint（Gateway型 + Interface型）

## このフェーズのゴール

Spoke VPC内のEC2（完全プライベート・NAT GWなし）が
S3・SSM・SSM Messages・EC2 Messagesへアクセスできる環境を構築する。

**このフェーズ完了時点で説明できるようになること:**
- Gateway型とInterface型の技術的な実装差異（ルートテーブル vs ENI）
- Interface EndpointでDNS設定（enable_dns_hostnames）が必要な理由
- EndpointにSecurity Groupが必要な理由（Interface型のみ）
- Session ManagerがNAT GW不要でインターネット接続なしに動作する仕組み

---

## Previously generated（Phase 1-2で作成済み）

- `modules/vpc/` — VPCモジュール
- `modules/vpc_peering/` — Peeringモジュール
- 3VPC + Peering構成

---

## 作成するファイル一覧

```
modules/
└── endpoint/
    ├── main.tf
    ├── variables.tf
    └── outputs.tf

envs/
├── spoke_prod/
│   └── endpoints.tf     # Spoke-Prod用Endpoint定義
├── spoke_dev/
│   └── endpoints.tf     # Spoke-Dev用Endpoint定義（prod流用）
└── spoke_prod/
    └── ec2_bastion.tf   # 疎通確認用EC2（Session Manager経由で接続）

docs/
└── adr/
    └── ADR-003_endpoint_strategy.md
```

---

## modules/endpoint/main.tf

```hcl
# =============================================================
# Gateway型 VPC Endpoint（S3・DynamoDB）
# 実装: ルートテーブルにPrefix Listへのルートを自動追加する
# ENIを作成しないため、Security Groupは不要・追加コストゼロ
# Prefix List: pl-xxxxxx（AWSマネージドのIPレンジ集合）
# =============================================================
resource "aws_vpc_endpoint" "gateway" {
  for_each = var.gateway_endpoints

  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type = "Gateway"

  # 対象のルートテーブルにPrefix Listへのルートを自動追加
  # privateサブネットのRTBを指定（publicは通常不要）
  route_table_ids = var.route_table_ids

  # ポリシーでアクセスを制限（デフォルトは全許可）
  # 本番ではS3バケット・DynamoDBテーブルを特定のARNに絞る
  policy = each.value.policy

  tags = merge(var.tags, {
    Name = "${var.prefix}-${each.key}-endpoint"
    Type = "Gateway"
  })
}

# =============================================================
# Interface型 VPC Endpoint（SSM・SSM Messages・EC2 Messages等）
# 実装: 指定サブネットにENI（Elastic Network Interface）を作成する
# → VPC内のプライベートIPでAWSサービスのAPIに到達可能になる
# → DNS名 (*.region.amazonaws.com) がENIのIPに解決される
#
# NAT GW不要でインターネット接続なしにAWS APIを呼べる理由:
# パケットがAWSバックボーンネットワーク内で完結するため
# =============================================================
resource "aws_vpc_endpoint" "interface" {
  for_each = var.interface_endpoints

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.subnet_ids
  security_group_ids  = [aws_security_group.endpoint.id]

  # private_dns_enabled = true にすることで
  # ssm.ap-northeast-1.amazonaws.com がENIのプライベートIPに解決される
  # この設定にはVPCの enable_dns_hostnames = true が前提条件
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.prefix}-${each.key}-endpoint"
    Type = "Interface"
  })
}

# =============================================================
# Interface Endpoint用セキュリティグループ
# EC2からのHTTPS（443）のみ許可
# Endpoint側のSGで制御することでEC2側SG変更が不要
# =============================================================
resource "aws_security_group" "endpoint" {
  name        = "${var.prefix}-endpoint-sg"
  description = "VPC Interface Endpoint用SG - EC2からのHTTPS通信を許可"
  vpc_id      = var.vpc_id

  ingress {
    description = "EC2からのHTTPS（AWS API呼び出し）"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]  # VPC CIDR内からのみ許可
  }

  # Egress: AWSマネージドサービスへの通信はAWSバックボーン内で完結
  # 明示的なEgressルールは不要だが、デフォルトを削除しない
  egress {
    description = "Endpointからの応答トラフィック"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.prefix}-endpoint-sg"
  })
}
```

## modules/endpoint/variables.tf

```hcl
variable "prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  description = "Endpoint SGのIngressに使用するVPC CIDR"
  type        = string
}

variable "region" {
  description = "AWSリージョン（サービス名の組み立てに使用）"
  type        = string
  default     = "ap-northeast-1"
}

variable "subnet_ids" {
  description = "Interface EndpointのENIを配置するサブネットIDリスト（マルチAZ推奨）"
  type        = list(string)
}

variable "route_table_ids" {
  description = "Gateway EndpointのPrefix Listルートを追加するルートテーブルIDリスト"
  type        = list(string)
}

variable "gateway_endpoints" {
  description = <<-EOT
    Gateway型Endpointの定義マップ。
    例: { "s3" = { policy = null }, "dynamodb" = { policy = null } }
  EOT
  type = map(object({
    policy = optional(string, null)
  }))
  default = {}
}

variable "interface_endpoints" {
  description = <<-EOT
    Interface型Endpointのサービス名セット。
    例: ["ssm", "ssmmessages", "ec2messages"]
  EOT
  type    = set(string)
  default = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
```

## modules/endpoint/outputs.tf

```hcl
output "gateway_endpoint_ids" {
  description = "Gateway Endpoint IDマップ"
  value       = { for k, v in aws_vpc_endpoint.gateway : k => v.id }
}

output "interface_endpoint_ids" {
  description = "Interface Endpoint IDマップ"
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.id }
}

output "endpoint_security_group_id" {
  description = "Interface Endpoint用SG ID"
  value       = aws_security_group.endpoint.id
}
```

---

## envs/spoke_prod/endpoints.tf

```hcl
# =============================================================
# Spoke-Prod VPC に VPC Endpointを配置
# EC2がNAT GW・インターネットなしにAWS APIを使えるようにする
# =============================================================

module "endpoints" {
  source = "../../modules/endpoint"

  prefix   = local.prefix
  vpc_id   = module.vpc.vpc_id
  vpc_cidr = module.vpc.vpc_cidr

  # Interface EndpointのENIをマルチAZで配置
  subnet_ids = module.vpc.private_subnet_ids

  # Gateway EndpointのルートはprivateサブネットのRTBに追加
  route_table_ids = values(module.vpc.route_table_ids)

  # ==========================================================
  # Gateway型: S3・DynamoDB
  # コストゼロ・ルートテーブルへの自動追加で動作
  # ==========================================================
  gateway_endpoints = {
    "s3" = {
      # S3アクセス制限ポリシー（本番では特定バケットに絞る）
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Effect    = "Allow"
          Principal = "*"
          Action    = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
          Resource  = "*"
        }]
      })
    }
    "dynamodb" = {
      policy = null  # デフォルト（全許可）
    }
  }

  # ==========================================================
  # Interface型: SSM関連3サービス（Session Manager動作に必須）
  # - ssm: SSM APIエンドポイント
  # - ssmmessages: Session Managerのデータチャネル
  # - ec2messages: Run Commandのメッセージング
  # この3つが揃わないとSession Managerが接続できない
  # ==========================================================
  interface_endpoints = toset([
    "ssm",
    "ssmmessages",
    "ec2messages",
  ])

  tags = local.common_tags
}
```

---

## envs/spoke_prod/ec2_bastion.tf

疎通確認用EC2。Session Manager経由でアクセスし、
S3・SSMが到達可能かを確認する。

```hcl
# =============================================================
# 疎通確認用EC2（完全プライベート）
# - SSHポート開放なし（Session Manager経由でアクセス）
# - NAT GW なし（VPC Endpoint経由でAWS APIに到達）
# - arm64（Graviton）でコスト最小化
# =============================================================

# SSM Session Manager使用のためのIAMロール
resource "aws_iam_role" "bastion" {
  name = "${local.prefix}-bastion-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

# Session Manager使用に必要な最低限のポリシー
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${local.prefix}-bastion-profile"
  role = aws_iam_role.bastion.name
}

# EC2用セキュリティグループ（Inbound全拒否）
resource "aws_security_group" "bastion" {
  name        = "${local.prefix}-bastion-sg"
  description = "疎通確認用EC2 - SSMアウトバウンドのみ許可"
  vpc_id      = module.vpc.vpc_id

  # Inbound: 全拒否（SSHポート不要）
  # Outbound: Endpoint SGへのHTTPS通信のみ許可
  egress {
    description     = "SSM Endpoint（Interface）への通信"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [module.endpoints.endpoint_security_group_id]
  }

  egress {
    description = "S3 Endpoint（Gateway）への通信"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    prefix_list_ids = [
      # S3 Gateway EndpointのPrefix Listを参照
      # aws ec2 describe-prefix-lists で確認可能
    ]
  }

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-bastion-sg"
  })
}

# 最新Amazon Linux 2023 AMI（arm64）
data "aws_ami" "al2023_arm" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-arm64"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.al2023_arm.id
  instance_type          = "t4g.nano"  # arm64最小インスタンス（$0.0052/時）
  subnet_id              = module.vpc.subnet_ids["private-1a"]
  iam_instance_profile   = aws_iam_instance_profile.bastion.name
  vpc_security_group_ids = [aws_security_group.bastion.id]

  # IMDSv2必須（セキュリティベストプラクティス）
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"  # IMDSv1を無効化
    http_put_response_hop_limit = 1
  }

  # EBSの暗号化
  root_block_device {
    encrypted = true
    volume_type = "gp3"
  }

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-bastion"
  })
}

output "bastion_instance_id" {
  description = "Session Managerで接続する際のインスタンスID"
  value       = aws_instance.bastion.id
}
```

---

## docs/adr/ADR-003_endpoint_strategy.md

```markdown
# ADR-003: VPC Endpoint戦略（Gateway vs Interface）

## ステータス
採用

## 決定

| サービス | Endpoint型 | 理由 |
|---|---|---|
| S3 | Gateway | 無料・ルーティング自動・十分な機能 |
| DynamoDB | Gateway | 無料・S3と同じ理由 |
| SSM | Interface | Gateway型が存在しない |
| SSM Messages | Interface | Session Managerに必須 |
| EC2 Messages | Interface | Run Commandに必須 |

## Gateway型の仕組みと採用理由
- ルートテーブルに `pl-xxxxxx → vpce-xxx` のルートを自動追加
- ENIを作成しないためコストゼロ
- S3・DynamoDBのみ対応（AWSによる制限）
- Security Groupは不要（ポリシーでアクセス制御）

## Interface型の仕組みと採用理由
- 指定サブネットにENI（プライベートIP）を作成
- DNS名が自動的にENIのIPに解決される（private_dns_enabled = true）
- 時間課金: $0.014/時/AZ（今回は各Spoke 2AZ = $0.028/時）
- SSM等Gateway型が存在しないサービスに必要

## NAT GW不採用の理由
- Interface EndpointでAWS APIにアクセス可能
- コスト: NAT GW $0.062/時 vs Interface Endpoint $0.014/時/AZ
- セキュリティ: インターネット経路を持たないことでアタックサーフェス削減
```

---

## 実行手順

```bash
cd envs/spoke_prod
terraform apply  # endpoints.tf, ec2_bastion.tf を追加後

# spoke_devも同様（endpoints.tfをコピー・prefix変更）
cd ../spoke_dev
terraform apply
```

## 検証手順（Session Manager経由）

```bash
# Session Managerで接続
aws ssm start-session --target $(terraform output -raw bastion_instance_id)

# EC2内でS3へのアクセス確認（Gateway Endpoint経由）
aws s3 ls --region ap-northeast-1

# SSM Parameter Storeへのアクセス確認（Interface Endpoint経由）
aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
  --region ap-northeast-1

# Endpointを使っているかトレース（curlで名前解決確認）
curl -v https://ssm.ap-northeast-1.amazonaws.com 2>&1 | grep "Trying"
# プライベートIPアドレス（10.x.x.x）に解決されていることを確認
```

## Phase 3 完了チェックリスト

- [ ] Spoke-Prod に S3・DynamoDB Gateway Endpointが作成されている
- [ ] Spoke-Prod に SSM・SSMMessages・EC2Messages Interface Endpointが作成されている
- [ ] EC2（t4g.nano）がSession Manager経由で接続できる
- [ ] EC2内から `aws s3 ls` が成功する（インターネット経由なし）
- [ ] Endpoint SGのIngressが443/TCPのVPC CIDRに限定されている
- [ ] 口頭説明: 「Gateway型とInterface型の技術的な差異」を5分で説明できる
```