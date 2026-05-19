# Phase 2: VPC Peering + ルーティング設計

## このフェーズのゴール

Hub↔Spoke-Prod、Hub↔Spoke-Dev の VPC Peeringを構築し、
双方向のルーティングを正確に設定する。
**SpokeどうしはPeeringしない**（ハブ経由でも転送不可）という
Transit GatewayとPeeringの本質的な違いを体験する。

**このフェーズ完了時点で説明できるようになること:**
- VPC PeeringがTransitiveにならない理由（パケット転送の仕組み）
- ルートテーブルへの明示的な追記が必要な理由
- Peering接続は申請側・承認側で非対称なAPIコールになる理由
- このハンズオンでTGWを使わない設計判断の根拠（ADR-002）

---

## Previously generated（Phase 1で作成済み）

- `modules/vpc/` — VPCモジュール
- `envs/hub/`, `envs/spoke_prod/`, `envs/spoke_dev/` — 各VPC環境

---

## 作成・変更するファイル一覧

```
modules/
└── vpc_peering/
    ├── main.tf
    ├── variables.tf
    └── outputs.tf

envs/
└── hub/
    └── peering.tf      # HubがPeeringの申請・承認を一元管理

docs/
├── architecture.md     # Phase2追記（Peeringを図に追加）
└── adr/
    └── ADR-002_peering_vs_tgw.md
```

---

## modules/vpc_peering/main.tf

```hcl
# =============================================================
# VPC Peering Connection
# 申請側（requester）と承認側（accepter）は同一AWSアカウント内のため
# auto_accept = true で即時承認。クロスアカウントの場合は別途手順が必要。
# =============================================================
resource "aws_vpc_peering_connection" "this" {
  vpc_id      = var.requester_vpc_id   # 申請側（Hub）
  peer_vpc_id = var.accepter_vpc_id    # 承認側（Spoke）
  auto_accept = true                   # 同一アカウントのため自動承認

  # DNS解決をPeering越しに有効化
  # → SpokeからHubのInterface EndpointのプライベートDNS名を解決できるようになる
  accepter {
    allow_remote_vpc_dns_resolution = true
  }

  requester {
    allow_remote_vpc_dns_resolution = true
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-peering"
  })
}

# =============================================================
# 申請側（Hub）ルートテーブルへのルート追加
# Hub → Spoke方向: Spoke CIDRへのトラフィックをPeering経由に向ける
# =============================================================
resource "aws_route" "requester_to_accepter" {
  for_each = var.requester_route_table_ids

  route_table_id            = each.value
  destination_cidr_block    = var.accepter_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}

# =============================================================
# 承認側（Spoke）ルートテーブルへのルート追加
# Spoke → Hub方向: Hub CIDRへのトラフィックをPeering経由に向ける
# 双方向のルート設定が必要な理由: PeeringはL3接続であり、
# ルートテーブルへの明示的な追記なしには通信できない
# =============================================================
resource "aws_route" "accepter_to_requester" {
  for_each = var.accepter_route_table_ids

  route_table_id            = each.value
  destination_cidr_block    = var.requester_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}
```

## modules/vpc_peering/variables.tf

```hcl
variable "name_prefix" {
  description = "Peering接続名のプレフィックス（例: vnd-hub-to-prod）"
  type        = string
}

variable "requester_vpc_id" {
  description = "申請側VPC ID（Hub）"
  type        = string
}

variable "requester_vpc_cidr" {
  description = "申請側VPC CIDR（承認側のルートテーブルに追加するdestination）"
  type        = string
}

variable "requester_route_table_ids" {
  description = <<-EOT
    申請側のルートテーブルIDマップ。
    全tierのRTBを渡すこと（public/private両方）。
    例: { "private" = "rtb-xxx", "public" = "rtb-yyy" }
  EOT
  type        = map(string)
}

variable "accepter_vpc_id" {
  description = "承認側VPC ID（Spoke）"
  type        = string
}

variable "accepter_vpc_cidr" {
  description = "承認側VPC CIDR（申請側のルートテーブルに追加するdestination）"
  type        = string
}

variable "accepter_route_table_ids" {
  description = "承認側のルートテーブルIDマップ"
  type        = map(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}
```

## modules/vpc_peering/outputs.tf

```hcl
output "peering_connection_id" {
  description = "VPC Peering Connection ID"
  value       = aws_vpc_peering_connection.this.id
}

output "peering_status" {
  description = "Peeringのステータス（active であることを確認）"
  value       = aws_vpc_peering_connection.this.accept_status
}
```

---

## envs/hub/peering.tf

Hub環境にPeeringモジュールの呼び出しを追加。
Hub側のoutputsからVPC ID/CIDRを参照し、Spoke側はdata sourceで取得する。

```hcl
# =============================================================
# Spoke側のTerraform stateからoutputsを参照
# Spokeは別ディレクトリで管理されているため、
# terraform_remote_state でoutputsを読み取る
# =============================================================
data "terraform_remote_state" "spoke_prod" {
  backend = "local"
  config = {
    path = "../../spoke_prod/terraform.tfstate"
  }
}

data "terraform_remote_state" "spoke_dev" {
  backend = "local"
  config = {
    path = "../../spoke_dev/terraform.tfstate"
  }
}

# =============================================================
# Hub ↔ Spoke-Prod Peering
# =============================================================
module "peering_hub_to_prod" {
  source = "../../modules/vpc_peering"

  name_prefix = "vnd-hub-to-prod"

  # Hub側（申請者）
  requester_vpc_id          = module.vpc.vpc_id
  requester_vpc_cidr        = module.vpc.vpc_cidr
  requester_route_table_ids = module.vpc.route_table_ids  # hub側全RTB

  # Spoke-Prod側（承認者）
  accepter_vpc_id          = data.terraform_remote_state.spoke_prod.outputs.vpc_id
  accepter_vpc_cidr        = data.terraform_remote_state.spoke_prod.outputs.vpc_cidr
  accepter_route_table_ids = data.terraform_remote_state.spoke_prod.outputs.route_table_ids

  tags = local.common_tags
}

# =============================================================
# Hub ↔ Spoke-Dev Peering
# =============================================================
module "peering_hub_to_dev" {
  source = "../../modules/vpc_peering"

  name_prefix = "vnd-hub-to-dev"

  requester_vpc_id          = module.vpc.vpc_id
  requester_vpc_cidr        = module.vpc.vpc_cidr
  requester_route_table_ids = module.vpc.route_table_ids

  accepter_vpc_id          = data.terraform_remote_state.spoke_dev.outputs.vpc_id
  accepter_vpc_cidr        = data.terraform_remote_state.spoke_dev.outputs.vpc_cidr
  accepter_route_table_ids = data.terraform_remote_state.spoke_dev.outputs.route_table_ids

  tags = local.common_tags
}

# =============================================================
# ⚠️ Spoke-Prod ↔ Spoke-Dev のPeeringは意図的に作成しない
# 理由: Spoke間通信はHub経由でも不可（PeeringはTransitiveでない）
# この制約こそがHub-Spoke + Peeringの本質的な限界であり、
# TGWが必要になる理由（ADR-002参照）
# =============================================================
```

---

## docs/adr/ADR-002_peering_vs_tgw.md

```markdown
# ADR-002: VPC PeeringをTransit Gatewayの代わりに採用する理由

## ステータス
採用（学習目的のトレードオフとして意図的に選択）

## コンテキスト
Hub-Spoke構成の相互接続手段として、以下の2択があった：
1. VPC Peering（Peeringのみ）
2. Transit Gateway（TGW）

## 決定
**VPC Peering を採用する**

## 理由

### VPC Peeringを選んだ理由
1. **ネットワークルーティングの基礎を体験できる**
   - PeeringはRoutableでない（Non-transitive）
   - ルートテーブルへの明示的な追記が必要 → ルーティングの本質を学べる
   - TGWはこれを抽象化してしまう

2. **コスト**
   - Peering接続自体は無料（データ転送料はかかる）
   - TGWは $0.05/時/Attachment = 2 Attachment × 24h × 30日 = $72/月 → 予算オーバー

3. **Spoke数が少ない**
   - Spoke 2本程度ならPeeringで管理可能（Spoke 10本超えたらTGWが現実的）

### VPC Peeringの本質的な限界（TGWが必要になるケース）
- **Non-transitive**: Hub→Prod→DevのようなSpoke間転送は不可
- **N対N問題**: Spoke 10本の場合、フルメッシュで45 Peering接続が必要
- **オーバーラップCIDR不可**: Spoke間でCIDRが重複するとPeering設定自体ができない

## 結論
学習目的では「制約を体験すること」自体に価値がある。
TGWへの移行パスは別プロジェクト（transit-gateway-deepdive）で扱う予定。
```

---

## 実行手順

```bash
# Spoke側を先にapplyしてからHubのPeeringをapply
# （Hub側でSpoke stateを参照するため）
cd envs/spoke_prod && terraform apply
cd ../spoke_dev && terraform apply

# Hub環境にpeering.tfを追加してapply
cd ../hub
terraform apply
```

## 検証ポイント

```bash
# Peering接続のステータス確認（active であること）
aws ec2 describe-vpc-peering-connections \
  --filters "Name=tag:Project,Values=vpc-network-deepdive" \
  --query 'VpcPeeringConnections[].{ID:VpcPeeringConnectionId,Status:Status.Code,Requester:RequesterVpcInfo.CidrBlock,Accepter:AccepterVpcInfo.CidrBlock}' \
  --output table

# Hub側ルートテーブルにSpokeへのルートが追加されているか確認
aws ec2 describe-route-tables \
  --filters "Name=tag:Project,Values=vpc-network-deepdive" \
              "Name=tag:Environment,Values=hub" \
  --query 'RouteTables[].Routes[?VpcPeeringConnectionId!=null]' \
  --output table
```

## Phase 2 完了チェックリスト

- [ ] Hub↔Prod のPeering ConnectionがActiveになっている
- [ ] Hub↔Dev のPeering ConnectionがActiveになっている
- [ ] HubのルートテーブルにProd・DevのCIDRへのルートが追加されている
- [ ] Prod・DevのルートテーブルにHubのCIDRへのルートが追加されている
- [ ] Prod↔Dev のPeeringが存在しない（意図的）
- [ ] 口頭説明: 「PeeringがTransitiveでない理由」を図を描いて説明できる