# tgw-multi-vpc-lab

Transit Gateway × Terraform で実装する Hub-and-Spoke VPC 設計ハンズオン。  
SAP-C02 で問われるマルチ VPC ネットワーク制御を、コードを書きながら体得する。

---

## このハンズオンで得られること

### 知識ではなく「設計判断の言語化」まで到達する

| 得られること | 具体的な能力 |
|------------|------------|
| **TGW の仕組みを説明できる** | Association と Propagation の違いを、図なしで口頭説明できる |
| **Spoke 間通信禁止の実装原理がわかる** | 「ルートが存在しないからドロップされる」を パケット単位で追える |
| **VPC Peering との使い分け判断ができる** | VPC 数・通信制御粒度・推移的ルーティングの観点で選択理由を説明できる |
| **NAT Gateway なし設計を実践できる** | VPC エンドポイントで SSM 接続を実現し、コスト削減の根拠を説明できる |
| **Terraform のモジュール設計ができる** | `for_each` を使った汎用モジュールを 4 VPC に再利用する設計を実装できる |
| **ADR を書ける** | 設計判断の「なぜ」を記録し、面接で即答できる水準に整理できる |

### 面接で差がつく問いへの回答が準備できる

- 「なぜ VPC Peering ではなく Transit Gateway を使ったのか？」
- 「Spoke 間通信を禁止するために何をしたか？ Security Group で実現できないのか？」
- 「NAT Gateway を置かないとどうやって EC2 にアクセスするのか？」
- 「このネットワーク構成を本番に持ち込むとしたら何を追加するか？」

---

## 構成概要

```
[Spoke-A: Dev VPC 10.1.0.0/16] ──┐
                                   ├──► [Transit Gateway]
[Spoke-B: Prod VPC 10.2.0.0/16] ─┘         │
                                             ├──► [Hub VPC 10.0.0.0/16]
                                             └──► [Inspection VPC 10.3.0.0/16]
```

### 通信ポリシー

| 通信方向 | 結果 |
|---------|------|
| Spoke-A ↔ Hub | ✅ 許可 |
| Spoke-B ↔ Hub | ✅ 許可 |
| Spoke-A ↔ Spoke-B | ❌ 禁止（TGW ルートテーブルで制御） |
| 外部通信 | Inspection VPC 経由（本ハンズオンでは未実装） |

### VPC 一覧

| VPC 名 | CIDR | 用途 |
|--------|------|------|
| hub-vpc | 10.0.0.0/16 | Shared Services（DNS、Bastion 等） |
| spoke-a-vpc | 10.1.0.0/16 | Dev 環境 |
| spoke-b-vpc | 10.2.0.0/16 | Prod 環境 |
| inspection-vpc | 10.3.0.0/16 | Network Firewall（集中検査） |

---

## 前提条件

```bash
# 確認すべきツール
terraform version   # v1.7.0 以上
aws --version       # AWS CLI v2
aws sts get-caller-identity  # 認証確認（ap-northeast-1 にアクセスできること）
```

- AWS アカウントがあり、IAM 権限（EC2・TGW・SSM・IAM の読み書き）があること
- デフォルトリージョンが `ap-northeast-1`（東京）に設定されていること

```bash
# デフォルトリージョンの確認・設定
aws configure get region
# → ap-northeast-1 でなければ設定する
aws configure set region ap-northeast-1
```

---

## ハンズオン手順

### Phase 1 — VPC モジュール + ベースネットワーク構築

**目的**: 4 つの VPC とサブネットを作成し、再利用可能な VPC モジュールを設計する。

#### ステップ 1-1. リポジトリの初期化

```bash
git clone <repository-url>
cd tgw-multi-vpc-lab
```

#### ステップ 1-2. Terraform 初期化

```bash
terraform -chdir=envs/ap-northeast-1 init
```

出力例:
```
Initializing modules...
Initializing provider plugins...
- Finding hashicorp/aws versions matching ">= 5.0.0"...
Terraform has been successfully initialized!
```

#### ステップ 1-3. プラン確認

```bash
terraform -chdir=envs/ap-northeast-1 plan
```

作成されるリソース（抜粋）:
- `aws_vpc` × 4（Hub / Spoke-A / Spoke-B / Inspection）
- `aws_subnet` × 16（各 VPC に Private × 2 + TGW 専用 × 2）
- `aws_vpc_endpoint` × 9（ssm / ssmmessages / ec2messages × 3 VPC）

#### ステップ 1-4. 適用

```bash
terraform -chdir=envs/ap-northeast-1 apply
```

> プロンプトに `yes` を入力して実行する。VPC エンドポイントの作成に 1〜2 分かかる。

#### ステップ 1-5. 完了確認

```bash
# 4 つの VPC が存在すること
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=tgw-multi-vpc-lab" \
  --query 'Vpcs[*].{ID:VpcId,CIDR:CidrBlock,Name:Tags[?Key==`Name`].Value|[0]}' \
  --output table

# TGW 専用サブネットが計 8 つ存在すること
aws ec2 describe-subnets \
  --filters "Name=tag:Type,Values=tgw" \
  --query 'Subnets[*].{SubnetId:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone}' \
  --output table
```

期待値:

```
------------------------------------------------------
|                   DescribeVpcs                     |
+------+-------------------+-------------------------+
| CIDR |        ID         |          Name           |
+------+-------------------+-------------------------+
| 10.0.0.0/16 | vpc-xxx  | hub-vpc                  |
| 10.1.0.0/16 | vpc-xxx  | spoke-a-vpc              |
| 10.2.0.0/16 | vpc-xxx  | spoke-b-vpc              |
| 10.3.0.0/16 | vpc-xxx  | inspection-vpc           |
+------+-------------------+-------------------------+
```

#### Phase 1 の理解チェック

- [ ] TGW 専用サブネットをプライベートサブネットから分離する理由を説明できる
- [ ] `for_each` を `count` より優先する理由を説明できる
- [ ] VPC エンドポイントをどのサブネットに配置するか、なぜかを説明できる

---

### Phase 2 — Transit Gateway + アタッチメント作成

**目的**: TGW 本体を作成し、4 VPC をアタッチする。この時点ではまだ VPC 間通信はできない（ルートテーブルの関連付けがないため）。

#### ステップ 2-1. プラン確認

```bash
terraform -chdir=envs/ap-northeast-1 plan
```

追加されるリソース:
- `aws_ec2_transit_gateway` × 1
- `aws_ec2_transit_gateway_vpc_attachment` × 4（Hub / Spoke-A / Spoke-B / Inspection）

> **ポイント**: TGW の `default_route_table_association = "disable"` が重要。有効のままだとすべてのアタッチメントが同じルートテーブルに自動登録され、Phase 3 で行う細かい通信制御が不可能になる。

#### ステップ 2-2. 適用

```bash
terraform -chdir=envs/ap-northeast-1 apply
```

> TGW の作成に 2〜3 分、アタッチメントの `available` 状態への移行にさらに 1〜2 分かかる。

#### ステップ 2-3. 完了確認

```bash
TGW_ID=$(terraform -chdir=envs/ap-northeast-1 output -raw tgw_id)

# TGW が 1 つ、State = available であること
aws ec2 describe-transit-gateways \
  --transit-gateway-ids $TGW_ID \
  --query 'TransitGateways[*].{ID:TransitGatewayId,State:State}' \
  --output table

# アタッチメントが 4 つ、すべて available であること
aws ec2 describe-transit-gateway-vpc-attachments \
  --filters "Name=transit-gateway-id,Values=$TGW_ID" \
  --query 'TransitGatewayVpcAttachments[*].{Name:Tags[?Key==`Name`].Value|[0],State:State}' \
  --output table
```

期待値:
```
------------------------------------
|  TransitGatewayVpcAttachments    |
+--------------------+-------------+
|       Name         |    State    |
+--------------------+-------------+
|  hub-attach        |  available  |
|  spoke-a-attach    |  available  |
|  spoke-b-attach    |  available  |
|  inspection-attach |  available  |
+--------------------+-------------+
```

#### Phase 2 の理解チェック

- [ ] `default_route_table_association = "disable"` にする理由を具体的に説明できる
- [ ] アタッチメント後に VPC 間通信できない理由を図で説明できる
- [ ] TGW の ASN（64512）は何のためにあるかを説明できる

---

### Phase 3 — TGWルートテーブル設計 + 通信制御ポリシー実装

**目的**: このハンズオンの核心。TGW ルートテーブルで「誰が誰と通信できるか」を宣言的に制御する。

#### TGW ルートテーブルの設計（2 テーブル方式）

```
[Spoke Route Table]
  Association : spoke-a-attach, spoke-b-attach
  Routes（伝播）: 10.0.0.0/16 → hub-attach      ← Hub のみ
                  10.3.0.0/16 → inspection-attach

[Hub Route Table]
  Association : hub-attach, inspection-attach
  Routes（伝播）: 10.1.0.0/16 → spoke-a-attach   ← Spoke-A
                  10.2.0.0/16 → spoke-b-attach   ← Spoke-B
                  10.3.0.0/16 → inspection-attach
```

**Spoke 間通信が禁止される仕組み**:  
Spoke-A のパケットは Spoke Route Table で評価される。  
Spoke RT には Spoke-B の `10.2.0.0/16` が存在しない（伝播していない）ため、パケットはドロップされる。

#### ステップ 3-1. プラン確認

```bash
terraform -chdir=envs/ap-northeast-1 plan
```

追加されるリソース:
- `aws_ec2_transit_gateway_route_table` × 2（Spoke RT / Hub RT）
- `aws_ec2_transit_gateway_route_table_association` × 4
- `aws_ec2_transit_gateway_route_table_propagation` × 4
- `aws_route` × 4（各 VPC のプライベートサブネット RTB に TGW 向けルートを追加）

#### ステップ 3-2. 適用

```bash
terraform -chdir=envs/ap-northeast-1 apply
```

#### ステップ 3-3. TGW ルートテーブルの内容確認

```bash
SPOKE_RT_ID=$(terraform -chdir=envs/ap-northeast-1 output -raw spoke_route_table_id)
HUB_RT_ID=$(terraform -chdir=envs/ap-northeast-1 output -raw hub_route_table_id)

# Spoke RT のルート確認（10.0.0.0/16 のみ存在するはず）
echo "=== Spoke Route Table ==="
aws ec2 search-transit-gateway-routes \
  --transit-gateway-route-table-id "$SPOKE_RT_ID" \
  --filters "Name=state,Values=active" \
  --query 'Routes[*].{CIDR:DestinationCidrBlock,Via:TransitGatewayAttachments[0].ResourceId}' \
  --output table

# Hub RT のルート確認（Spoke-A / Spoke-B / Inspection が存在するはず）
echo "=== Hub Route Table ==="
aws ec2 search-transit-gateway-routes \
  --transit-gateway-route-table-id "$HUB_RT_ID" \
  --filters "Name=state,Values=active" \
  --query 'Routes[*].{CIDR:DestinationCidrBlock,Via:TransitGatewayAttachments[0].ResourceId}' \
  --output table
```

期待値:
```
=== Spoke Route Table ===
+--------------+---------------+
|     CIDR     |      Via      |
+--------------+---------------+
| 10.0.0.0/16  | vpc-xxx (Hub) |
| 10.3.0.0/16  | vpc-xxx (Ins) |
+--------------+---------------+

=== Hub Route Table ===
+--------------+------------------+
|     CIDR     |       Via        |
+--------------+------------------+
| 10.1.0.0/16  | vpc-xxx (Spo-A)  |
| 10.2.0.0/16  | vpc-xxx (Spo-B)  |
| 10.3.0.0/16  | vpc-xxx (Ins)    |
| 10.0.0.0/16  | vpc-xxx (Hub)    |
+--------------+------------------+
```

> **重要**: Spoke RT に `10.1.0.0/16` も `10.2.0.0/16` も存在しないことを確認する。これが Spoke 間通信禁止の根拠。

#### ステップ 3-4. Association の確認

```bash
# Spoke RT に spoke-a と spoke-b が関連付けられていること
aws ec2 get-transit-gateway-route-table-associations \
  --transit-gateway-route-table-id "$SPOKE_RT_ID" \
  --query 'Associations[*].{AttachmentId:TransitGatewayAttachmentId,State:State}' \
  --output table
```

#### Phase 3 の理解チェック

- [ ] Association と Propagation の違いを口頭で説明できる
- [ ] Spoke-A → Spoke-B が届かない理由をパケット単位で追跡できる
- [ ] Spoke RT に Spoke-B の CIDR を手動追加したら何が起きるかを説明できる

---

### Phase 4 — テスト用 EC2 + 疎通確認

**目的**: 「設定した」から「動作を確認した」へ。EC2 を使って通信ポリシーが正しく機能していることを実証する。

#### ステップ 4-1. プラン確認

```bash
terraform -chdir=envs/ap-northeast-1 plan
```

追加されるリソース:
- `aws_instance` × 3（Hub / Spoke-A / Spoke-B）
- `aws_iam_role` × 3（SSM 接続用）
- `aws_security_group` × 3（ICMP 許可）

#### ステップ 4-2. 適用

```bash
terraform -chdir=envs/ap-northeast-1 apply
```

#### ステップ 4-3. SSM 接続の確認

EC2 起動後、SSM エージェントが起動するまで **2〜3 分** 待つ。

```bash
SPOKE_A_ID=$(terraform -chdir=envs/ap-northeast-1 output -raw test_spoke_a_instance_id)

# インスタンスが SSM に登録されているか確認
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$SPOKE_A_ID" \
  --query 'InstanceInformationList[*].{ID:InstanceId,Status:PingStatus,Agent:AgentVersion}' \
  --output table
```

`PingStatus = Online` になれば接続準備完了。

#### ステップ 4-4. 疎通確認スクリプトの実行

```bash
bash tests/connectivity_check.sh
```

期待される出力:
```
=== 疎通確認開始 ===
Hub IP:     10.0.1.xxx
Spoke-B IP: 10.2.1.xxx

[Spoke-A → Hub]     Ping 10.0.1.xxx ... PASS（通信OK、期待通り）
[Spoke-A → Spoke-B] Ping 10.2.1.xxx ... PASS（通信NG、期待通り遮断）

=== 確認完了: 全テストPASS ===
```

> スクリプトは SSM Send Command を使って Spoke-A EC2 からリモートで ping を実行する。結果が `PASS` であれば、TGW ルートテーブルによる通信制御が正しく機能している。

#### ステップ 4-5. 手動での疎通確認（推奨）

スクリプトに加えて、SSM Session Manager で直接ログインして確認するとより深く理解できる。

```bash
SPOKE_A_ID=$(terraform -chdir=envs/ap-northeast-1 output -raw test_spoke_a_instance_id)
HUB_IP=$(terraform -chdir=envs/ap-northeast-1 output -raw test_hub_private_ip)
SPOKE_B_IP=$(terraform -chdir=envs/ap-northeast-1 output -raw test_spoke_b_private_ip)

# Spoke-A EC2 にログイン
aws ssm start-session --target $SPOKE_A_ID
```

セッション内で:
```bash
# Hub への ping（通るはず）
ping -c 3 $HUB_IP

# Spoke-B への ping（タイムアウトするはず）
ping -c 3 -W 2 $SPOKE_B_IP

# Hub への経路確認
traceroute $HUB_IP
```

#### Phase 4 の理解チェック

- [ ] Spoke-A → Hub 行きパケットの完全な経路を説明できる（EC2 → VPC RTB → TGW ENI → Spoke RT → Hub RT → Hub EC2）
- [ ] SSM Session Manager が NAT GW なしで接続できる仕組みを説明できる（VPC エンドポイント経由）
- [ ] テストが FAIL した場合のトラブルシューティング手順を説明できる

---

### Phase 5 — ドキュメント整備

**目的**: 実装したネットワーク設計を「面接で話せるレベル」に昇華させる。

#### 作成済みドキュメント

| ファイル | 内容 |
|--------|------|
| `ARCHITECTURE.md` | 設計の完全理解ドキュメント（構造・仕組み・パケット追跡） |
| `docs/architecture.md` | Mermaid ネットワーク構成図 |
| `docs/runbook.md` | 確認コマンド・トラブルシューティング手順 |
| `docs/adr/001-tgw-vs-vpc-peering.md` | ADR: なぜ TGW を選んだか |
| `docs/adr/002-tgw-route-table-design.md` | ADR: なぜ 2 テーブル構成にしたか |
| `docs/adr/003-no-nat-gateway.md` | ADR: なぜ NAT GW を使わないか |
| `docs/interview-star.md` | 面接用 STAR 形式回答テンプレート |
| `docs/zenn-outline.md` | Zenn 記事アウトライン |

#### 自分で記入が必要な箇所

以下のセクションは **自分の言葉で記述すること**（AI 生成禁止）。  
実装を通じて得た「なぜそう判断したか」を記録することがこのフェーズの本質。

```
docs/adr/001-tgw-vs-vpc-peering.md    → ## 決定理由
docs/adr/002-tgw-route-table-design.md → ## 決定理由
docs/adr/003-no-nat-gateway.md         → ## 決定理由
docs/interview-star.md                 → ### Action, ### Result, 深掘り質問の回答
```

---

## コストと後片付け

### 稼働中のコスト概算

| リソース | 数量 | 単価 | 1 時間あたり |
|---------|------|------|------------|
| TGW アタッチメント | 4 本 | $0.05/h | $0.20 |
| VPC Interface Endpoint | 9 個 | $0.014/h | $0.13 |
| EC2 t4g.nano Spot | 3 台 | ~$0.002/h | ~$0.01 |
| **合計** | | | **~$0.34/h** |

ハンズオン全体（数時間）で **$1〜2 程度**。実習後は必ず削除すること。

### リソース削除

```bash
# すべてのリソースを削除（実行前にプランを確認すること）
terraform -chdir=envs/ap-northeast-1 destroy
```

> TGW の削除には 5〜10 分かかる。アタッチメントが先に削除されてから TGW 本体が削除される。

#### 削除完了の確認

```bash
# TGW が存在しないことを確認
aws ec2 describe-transit-gateways \
  --filters "Name=tag:Project,Values=tgw-multi-vpc-lab" \
  --query 'TransitGateways[*].{ID:TransitGatewayId,State:State}' \
  --output table
# → 空または State = deleted であること

# VPC が存在しないことを確認
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=tgw-multi-vpc-lab" \
  --query 'Vpcs[*].VpcId' \
  --output table
# → 空であること
```

---

## ディレクトリ構成

```
tgw-multi-vpc-lab/
├── README.md               ← このファイル
├── ARCHITECTURE.md         ← 設計の完全理解ドキュメント
├── modules/
│   ├── vpc/                ← VPC モジュール（4 VPC 共通）
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── versions.tf
│   ├── tgw/                ← Transit Gateway 本体 + ルートテーブル
│   ├── tgw-attach/         ← アタッチメント + Association + Propagation
│   └── test-ec2/           ← 疎通確認用 EC2（t4g.nano Spot）
├── envs/
│   └── ap-northeast-1/
│       ├── main.tf          ← モジュール呼び出し・VPC ルート定義
│       ├── variables.tf
│       ├── outputs.tf
│       └── terraform.tfvars
├── tests/
│   └── connectivity_check.sh  ← 疎通確認スクリプト
├── docs/
│   ├── architecture.md     ← Mermaid 構成図
│   ├── runbook.md          ← 確認コマンド・トラブルシューティング
│   ├── interview-star.md   ← 面接用 STAR 形式回答
│   ├── zenn-outline.md     ← 記事アウトライン
│   └── adr/
│       ├── 001-tgw-vs-vpc-peering.md
│       ├── 002-tgw-route-table-design.md
│       └── 003-no-nat-gateway.md
└── phase1.md 〜 phase5.md  ← 各フェーズの詳細タスク
```

---

## トラブルシューティング

### SSM で接続できない

```bash
# 1. VPC エンドポイントが存在するか確認
aws ec2 describe-vpc-endpoints \
  --filters "Name=tag:Project,Values=tgw-multi-vpc-lab" \
  --query 'VpcEndpoints[*].{Service:ServiceName,State:State}' \
  --output table

# 2. EC2 の IAM ロールに AmazonSSMManagedInstanceCore が付与されているか確認
INSTANCE_ID=$(terraform -chdir=envs/ap-northeast-1 output -raw test_spoke_a_instance_id)
aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[*].Instances[*].IamInstanceProfile.Arn' \
  --output text

# 3. EC2 が SSM に登録されているか確認（起動後 2〜3 分待つ）
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[*].PingStatus' \
  --output text
```

### Spoke-A → Hub に ping が通らない

```bash
# 1. TGW アタッチメントが available か確認
TGW_ID=$(terraform -chdir=envs/ap-northeast-1 output -raw tgw_id)
aws ec2 describe-transit-gateway-vpc-attachments \
  --filters "Name=transit-gateway-id,Values=$TGW_ID" \
  --query 'TransitGatewayVpcAttachments[*].{Name:Tags[?Key==`Name`].Value|[0],State:State}'

# 2. Spoke RT に Hub へのルートが存在するか確認
SPOKE_RT_ID=$(terraform -chdir=envs/ap-northeast-1 output -raw spoke_route_table_id)
aws ec2 search-transit-gateway-routes \
  --transit-gateway-route-table-id "$SPOKE_RT_ID" \
  --filters "Name=state,Values=active"

# 3. Spoke-A VPC のルートテーブルに TGW へのルートが存在するか確認
aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=spoke-a-rtb-private" \
  --query 'RouteTables[*].Routes'
```

### terraform apply でタイムアウトする

TGW の作成・削除は時間がかかる。タイムアウトした場合は再実行する。

```bash
terraform -chdir=envs/ap-northeast-1 apply
# → 「Already exists」エラーが出る場合は状態が不整合。`terraform refresh` を試みる
terraform -chdir=envs/ap-northeast-1 refresh
```

---

## 参考リンク

- [Transit Gateway の概要 — AWS ドキュメント](https://docs.aws.amazon.com/ja_jp/vpc/latest/tgw/what-is-transit-gateway.html)
- [Transit Gateway ルートテーブル](https://docs.aws.amazon.com/ja_jp/vpc/latest/tgw/tgw-route-tables.html)
- [VPC エンドポイントで Systems Manager を使用する](https://docs.aws.amazon.com/ja_jp/systems-manager/latest/userguide/setup-create-vpc.html)
- 設計の詳細: [`ARCHITECTURE.md`](./ARCHITECTURE.md)
- 口頭チェック質問: [`phase3.md`](./phase3.md) / [`phase4.md`](./phase4.md)
