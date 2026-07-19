# Phase 3: TGWルートテーブル設計 + 通信制御ポリシー実装

## このフェーズの目的
このプロジェクトの核心部分。TGWルートテーブルで「誰が誰と通信できるか」を制御する。
Spoke-A ↔ Spoke-B を遮断しながら、Hub ↔ Spoke はすべて許可する構成を実装する。

## 通信ポリシー（設計仕様）

| 送信元 | 宛先 | 許可 / 禁止 |
|--------|------|------------|
| Spoke-A | Hub | ✅ 許可 |
| Spoke-B | Hub | ✅ 許可 |
| Hub | Spoke-A | ✅ 許可 |
| Hub | Spoke-B | ✅ 許可 |
| Spoke-A | Spoke-B | ❌ 禁止 |
| Spoke-B | Spoke-A | ❌ 禁止 |
| Spoke-A/B | インターネット | Inspection VPC経由（Phase 4） |

## TGWルートテーブル設計

### ルートテーブル構成（2テーブル方式）

```
[Spoke RT]                    [Hub RT]
関連付け: Spoke-A, Spoke-B    関連付け: Hub, Inspection
伝播: Hub のみ                伝播: Spoke-A, Spoke-B, Inspection
                              (Hub自身は不要)

Spoke-AからのパケットはSpoke RTで評価 → Hubのルートしかない → Spoke-Bへは届かない
```

**なぜ2テーブルで制御できるか**: ルートテーブルに「Hubへのルートだけ」を載せることで、
Spokeからの通信先をHubのみに限定できる。

---

## タスク一覧

### 1. `modules/tgw` へルートテーブルリソースを追加

`modules/tgw/main.tf` に追記:

```hcl
# ─────────────────────────────────────────
# Spoke用ルートテーブル
# Spoke-A / Spoke-B をここに関連付ける
# 伝播はHubのみ → Spoke同士の通信を防ぐ
# ─────────────────────────────────────────
resource "aws_ec2_transit_gateway_route_table" "spoke" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags = merge(var.tags, { Name = "${var.name}-spoke-rt" })
}

# ─────────────────────────────────────────
# Hub/Inspection用ルートテーブル
# HubとInspection VPCをここに関連付ける
# すべてのSpokeへのルートを伝播で受け取る
# ─────────────────────────────────────────
resource "aws_ec2_transit_gateway_route_table" "hub" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags = merge(var.tags, { Name = "${var.name}-hub-rt" })
}
```

`modules/tgw/outputs.tf` に追加:
```hcl
output "spoke_route_table_id"
output "hub_route_table_id"
```

### 2. `modules/tgw-attach` へ関連付け・伝播リソースを追加

`modules/tgw-attach/main.tf` に追記:

```hcl
# ─────────────────────────────────────────
# ルートテーブル関連付け（Association）
# このアタッチメントが「どのルートテーブルで評価されるか」を決定する
# ─────────────────────────────────────────
resource "aws_ec2_transit_gateway_route_table_association" "this" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this.id
  transit_gateway_route_table_id = var.route_table_id
}

# ─────────────────────────────────────────
# ルート伝播（Propagation）
# このVPCのCIDRを「どのルートテーブルに広告するか」を設定する
# propagate_to_route_table_ids で複数テーブルへの伝播が可能
# ─────────────────────────────────────────
resource "aws_ec2_transit_gateway_route_table_propagation" "this" {
  for_each = toset(var.propagate_to_route_table_ids)
  
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this.id
  transit_gateway_route_table_id = each.value
}
```

`modules/tgw-attach/variables.tf` に追加:
```hcl
variable "route_table_id"              # 自分が関連付けられるルートテーブルID
variable "propagate_to_route_table_ids"  # 自分のCIDRを伝播するルートテーブルIDのリスト
```

### 3. `envs/ap-northeast-1/main.tf` でアタッチメントモジュールを更新

```hcl
# Spoke-Aアタッチメント
# 評価: Spoke RT（Hub CIDRしかないのでHubにしか行けない）
# 伝播: Hub RT（Spoke-AのCIDRをHubが知れるようにする）
module "spoke_a_attach" {
  source          = "../../modules/tgw-attach"
  tgw_id          = module.tgw.tgw_id
  vpc_id          = module.spoke_a_vpc.vpc_id
  tgw_subnet_ids  = values(module.spoke_a_vpc.tgw_subnet_ids)
  attachment_name = "spoke-a"
  
  route_table_id              = module.tgw.spoke_route_table_id
  propagate_to_route_table_ids = [module.tgw.hub_route_table_id]
  
  tags = local.common_tags
}

# Spoke-Bアタッチメント（Spoke-Aと同じ構成）
module "spoke_b_attach" {
  source          = "../../modules/tgw-attach"
  tgw_id          = module.tgw.tgw_id
  vpc_id          = module.spoke_b_vpc.vpc_id
  tgw_subnet_ids  = values(module.spoke_b_vpc.tgw_subnet_ids)
  attachment_name = "spoke-b"
  
  route_table_id              = module.tgw.spoke_route_table_id
  propagate_to_route_table_ids = [module.tgw.hub_route_table_id]
  
  tags = local.common_tags
}

# Hubアタッチメント
# 評価: Hub RT（すべてのSpokeへのCIDRが伝播されている）
# 伝播: Spoke RT（HubのCIDRをSpokeに知らせる）
module "hub_attach" {
  source          = "../../modules/tgw-attach"
  tgw_id          = module.tgw.tgw_id
  vpc_id          = module.hub_vpc.vpc_id
  tgw_subnet_ids  = values(module.hub_vpc.tgw_subnet_ids)
  attachment_name = "hub"
  
  route_table_id              = module.tgw.hub_route_table_id
  propagate_to_route_table_ids = [module.tgw.spoke_route_table_id]
  
  tags = local.common_tags
}

# Inspectionアタッチメント
# 評価: Hub RT
# 伝播: Spoke RT（Inspection経由でSpokeの外部通信を受け取る想定）
module "inspection_attach" {
  source          = "../../modules/tgw-attach"
  tgw_id          = module.tgw.tgw_id
  vpc_id          = module.inspection_vpc.vpc_id
  tgw_subnet_ids  = values(module.inspection_vpc.tgw_subnet_ids)
  attachment_name = "inspection"
  
  route_table_id              = module.tgw.hub_route_table_id
  propagate_to_route_table_ids = [module.tgw.spoke_route_table_id]
  
  tags = local.common_tags
}
```

### 4. VPC側のルートテーブルへTGWルートを追加

各VPCのプライベートサブネットから、他VPCへの通信がTGWを経由するように、
VPC側のルートテーブルに `0.0.0.0/0` または特定CIDRへのルートを追加する。

`envs/ap-northeast-1/main.tf` に追記:

```hcl
# Spoke-AのプライベートサブネットRT → TGW経由で10.0.0.0/8へ
resource "aws_route" "spoke_a_to_tgw" {
  for_each = toset(module.spoke_a_vpc.private_route_table_ids)
  
  route_table_id         = each.value
  destination_cidr_block = "10.0.0.0/8"  # 全プライベートレンジをTGW経由に
  transit_gateway_id     = module.tgw.tgw_id
  
  depends_on = [module.spoke_a_attach]
}

# Spoke-B、Hub、Inspectionも同様に追加
resource "aws_route" "spoke_b_to_tgw" { ... }
resource "aws_route" "hub_to_tgw" { ... }
resource "aws_route" "inspection_to_tgw" { ... }
```

### 5. `terraform apply` の実行

```bash
terraform -chdir=envs/ap-northeast-1 plan
terraform -chdir=envs/ap-northeast-1 apply
```

---

## 完了確認

### TGWルートテーブルの内容を確認

```bash
TGW_ID=$(terraform -chdir=envs/ap-northeast-1 output -raw tgw_id)

# Spoke RTのルートを確認（Hubへのルートだけが存在するはず）
SPOKE_RT=$(terraform -chdir=envs/ap-northeast-1 output -raw spoke_route_table_id)
aws ec2 search-transit-gateway-routes \
  --transit-gateway-route-table-id $SPOKE_RT \
  --filters "Name=state,Values=active" \
  --query 'Routes[*].{CIDR:DestinationCidrBlock,Attach:TransitGatewayAttachments[0].ResourceId}' \
  --output table

# Hub RTのルートを確認（SpokeとInspectionへのルートが存在するはず）
HUB_RT=$(terraform -chdir=envs/ap-northeast-1 output -raw hub_route_table_id)
aws ec2 search-transit-gateway-routes \
  --transit-gateway-route-table-id $HUB_RT \
  --filters "Name=state,Values=active" \
  --query 'Routes[*].{CIDR:DestinationCidrBlock,Attach:TransitGatewayAttachments[0].ResourceId}' \
  --output table
```

**期待値**:
- Spoke RT: `10.0.0.0/16`（Hub）のルートのみ
- Hub RT: `10.1.0.0/16`（Spoke-A）と `10.2.0.0/16`（Spoke-B）と `10.3.0.0/16`（Inspection）

---

## 口頭説明チェック（15分目安）

1. **AssociationとPropagationの違いを説明せよ**
   「関連付け」と「伝播」それぞれが何を決めるか、図を使って説明できるか？

2. **Spoke-AからSpoke-Bへの通信が届かない理由をパケットの動きで説明せよ**
   Spoke-AのパケットがTGWに届いてから、どのテーブルで評価されて、どこで止まるか？

3. **Spoke RTに `10.1.0.0/16` と `10.2.0.0/16` を手動で追加したら何が起きるか？**
   この設計の「意図的な欠如」が通信制御になっている点を説明できるか？

4. **今の構成でHub VPCがSingle Point of Failureになっているか？なるとすればどこ？**

---

## 次のフェーズ
Phase 4: テスト用EC2 + 疎通確認スクリプト