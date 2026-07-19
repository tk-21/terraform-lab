# Phase 2: Transit Gateway + アタッチメント作成

## このフェーズの目的
Transit Gateway本体を作成し、Phase 1で作成した4つのVPCをアタッチする。
この時点ではまだデフォルトルートテーブルにすべてのアタッチメントが紐づく。
「アタッチするだけでは通信制御にならない」ことを理解するための布石。

## 前提条件
- Phase 1完了済み（4つのVPCとTGW専用サブネットが存在する）
- `terraform output` でVPC IDとサブネットIDが取得できること

---

## タスク一覧

### 1. `modules/tgw` モジュールの作成

```
modules/
└── tgw/
    ├── main.tf
    ├── variables.tf
    └── outputs.tf
```

**main.tf** で作成するリソース:

```hcl
# Transit Gateway本体
resource "aws_ec2_transit_gateway" "this" {
  description                     = var.description
  amazon_side_asn                 = var.amazon_side_asn  # デフォルト: 64512
  auto_accept_shared_attachments  = "disable"
  default_route_table_association = "disable"  # 重要: 後でルートテーブルを手動管理するため無効化
  default_route_table_propagation = "disable"  # 同上
  dns_support                     = "enable"
  vpn_ecmp_support               = "enable"
  tags = merge(var.tags, { Name = var.name })
}
```

**なぜ `default_route_table_association = "disable"` にするか**: 
コード内に日本語コメントで理由を記述すること。

**variables.tf**:
```hcl
variable "name"
variable "description"
variable "amazon_side_asn"  # デフォルト 64512
variable "tags"
```

**outputs.tf**:
```hcl
output "tgw_id"
output "tgw_arn"
```

### 2. `modules/tgw-attach` モジュールの作成

```
modules/
└── tgw-attach/
    ├── main.tf
    ├── variables.tf
    └── outputs.tf
```

**main.tf** で作成するリソース:

```hcl
# VPCアタッチメント（TGW専用サブネットにENIが配置される）
resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  transit_gateway_id = var.tgw_id
  vpc_id             = var.vpc_id
  subnet_ids         = var.tgw_subnet_ids  # TGW専用サブネットのIDリスト
  
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = merge(var.tags, { Name = "${var.attachment_name}-attach" })
}
```

**variables.tf**:
```hcl
variable "tgw_id"
variable "vpc_id"
variable "tgw_subnet_ids"   # list(string)
variable "attachment_name"  # 例: "hub", "spoke-a"
variable "tags"
```

**outputs.tf**:
```hcl
output "attachment_id"
output "vpc_id"
output "attachment_name"
```

### 3. `envs/ap-northeast-1/main.tf` へ追記

TGW本体を1つ作成し、4つのアタッチメントを作成:

```hcl
module "tgw" {
  source      = "../../modules/tgw"
  name        = "tgw-${var.project}"
  description = "Transit Gateway for ${var.project}"
  tags        = local.common_tags
}

module "hub_attach" {
  source          = "../../modules/tgw-attach"
  tgw_id          = module.tgw.tgw_id
  vpc_id          = module.hub_vpc.vpc_id
  tgw_subnet_ids  = values(module.hub_vpc.tgw_subnet_ids)
  attachment_name = "hub"
  tags            = local.common_tags
}

module "spoke_a_attach" {
  source          = "../../modules/tgw-attach"
  tgw_id          = module.tgw.tgw_id
  vpc_id          = module.spoke_a_vpc.vpc_id
  tgw_subnet_ids  = values(module.spoke_a_vpc.tgw_subnet_ids)
  attachment_name = "spoke-a"
  tags            = local.common_tags
}

module "spoke_b_attach" {
  source          = "../../modules/tgw-attach"
  tgw_id          = module.tgw.tgw_id
  vpc_id          = module.spoke_b_vpc.vpc_id
  tgw_subnet_ids  = values(module.spoke_b_vpc.tgw_subnet_ids)
  attachment_name = "spoke-b"
  tags            = local.common_tags
}

module "inspection_attach" {
  source          = "../../modules/tgw-attach"
  tgw_id          = module.tgw.tgw_id
  vpc_id          = module.inspection_vpc.vpc_id
  tgw_subnet_ids  = values(module.inspection_vpc.tgw_subnet_ids)
  attachment_name = "inspection"
  tags            = local.common_tags
}
```

### 4. `terraform apply` の実行

```bash
terraform -chdir=envs/ap-northeast-1 plan
terraform -chdir=envs/ap-northeast-1 apply
```

---

## 完了確認

### CLIで確認

```bash
# TGWが1つ作成されていること
aws ec2 describe-transit-gateways \
  --filters "Name=tag:Project,Values=tgw-multi-vpc-lab" \
  --query 'TransitGateways[*].{ID:TransitGatewayId,State:State,ASN:Options.AmazonSideAsn}' \
  --output table

# アタッチメントが4つ、すべてavailableであること
aws ec2 describe-transit-gateway-vpc-attachments \
  --filters "Name=transit-gateway-id,Values=$(terraform -chdir=envs/ap-northeast-1 output -raw tgw_id)" \
  --query 'TransitGatewayVpcAttachments[*].{ID:TransitGatewayAttachmentId,VPC:VpcId,State:State,Name:Tags[?Key==`Name`].Value|[0]}' \
  --output table

# デフォルトルートテーブルへの自動関連付けがないことを確認
aws ec2 describe-transit-gateway-route-tables \
  --filters "Name=transit-gateway-id,Values=$(terraform -chdir=envs/ap-northeast-1 output -raw tgw_id)" \
  --query 'TransitGatewayRouteTables[*].{ID:TransitGatewayRouteTableId,Default:DefaultAssociationRouteTable}' \
  --output table
```

### この時点の通信状態
- アタッチメントは存在するが、ルートテーブルに関連付けられていない
- VPC間の通信は **まだできない**（これが正しい状態）

---

## 口頭説明チェック（15分目安）

1. **`default_route_table_association = "disable"` にする意図は何か？**
   デフォルト有効のままだと何が困るか具体的に説明できるか？

2. **TGWアタッチメントのサブネットはなぜ複数AZに配置するか？**

3. **アタッチメント作成後、すぐに通信できない理由は何か？**
   （ルートテーブルの関連付けがない状態を図で説明できるか）

4. **TGWのASN（64512）は何のために必要か？BGPとの関係は？**

---

## 次のフェーズ
Phase 3: TGWルートテーブル設計 + 通信制御ポリシーの実装