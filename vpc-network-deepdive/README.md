# vpc-network-deepdive

AWSネットワーク設計を実務レベルで体得するための Terraform ハンズオン。
Hub-Spoke VPC 構成から始まり、VPC Peering・VPC Endpoint・カスタム PrivateLink を段階的に構築する。

---

## このハンズオンで得られること

### 技術スキル

| スキル | 詳細 |
|---|---|
| **Hub-Spoke VPC 設計** | 環境ごとに VPC を分割し、爆発半径を最小化する設計パターンを習得する |
| **VPC Peering とルーティング** | ルートテーブルへの双方向エントリ追加、Non-transitive の制約を体験で理解する |
| **Gateway 型 Endpoint** | コストゼロで S3/DynamoDB へプライベートアクセスする仕組みを理解する |
| **Interface 型 Endpoint** | ENI と DNS 上書きの仕組みを理解し、NAT Gateway なしで SSM Session Manager を動かす |
| **カスタム PrivateLink** | NLB + VPC Endpoint Service によるサービスプロバイダー/コンシューマーモデルを構築する |
| **Terraform モジュール設計** | 1 モジュール = 1 責務の原則、`for_each` によるマルチ AZ 対応、State 間の cross-reference を習得する |
| **セキュリティ設計** | IMDSv2 強制・default SG 無効化・SG 間参照・最小権限 IAM の実装パターンを身につける |

### 説明できるようになること

このハンズオン完了後、以下の問いに自分の言葉で答えられるようになる。

- 「Hub-Spoke 構成と Transit Gateway の使い分けは？」
- 「VPC Peering でなぜルートテーブルに両方向エントリが必要なのか？」
- 「Gateway 型 Endpoint と Interface 型 Endpoint は技術的にどう違うのか？」
- 「Session Manager はなぜ NAT Gateway なしで動くのか？」
- 「PrivateLink で NLB が必要な理由は？VPC Peering との本質的な違いは？」

---

## 前提条件

| 要件 | 詳細 |
|---|---|
| AWS アカウント | 有効な AWS アカウント（管理者権限推奨） |
| Terraform | `>= 1.9.0`（`terraform --version` で確認） |
| AWS CLI | `>= 2.0`（設定済み・`aws sts get-caller-identity` で確認） |
| Session Manager Plugin | AWS CLI 用プラグイン（EC2 接続に使用） |
| リージョン | `ap-northeast-1`（東京）固定 |

### AWS CLI 設定確認

```bash
# 認証情報の確認
aws sts get-caller-identity
# 出力例: { "Account": "123456789012", "Arn": "arn:aws:iam::123456789012:..." }

# リージョン確認
aws configure get region
# ap-northeast-1 であること
```

### Session Manager Plugin のインストール

```bash
# macOS
brew install --cask session-manager-plugin

# Linux (x86_64)
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" \
  -o "/tmp/session-manager-plugin.deb"
sudo dpkg -i /tmp/session-manager-plugin.deb

# 確認
session-manager-plugin --version
```

---

## ディレクトリ構成

```
vpc-network-deepdive/
├── README.md                  # このファイル
├── CLAUDE.md                  # プロジェクト固有のコーディング規約
│
├── phase1.md                  # Phase 1 実装プロンプト（参考）
├── phase2.md                  # Phase 2 実装プロンプト（参考）
├── phase3.md                  # Phase 3 実装プロンプト（参考）
├── phase4.md                  # Phase 4 実装プロンプト（参考）
│
├── modules/
│   ├── vpc/                   # VPC・サブネット・IGW 汎用モジュール
│   ├── vpc_peering/           # Peering と双方向ルート汎用モジュール
│   ├── endpoint/              # Gateway/Interface Endpoint 汎用モジュール
│   └── privatelink/           # NLB + VPC Endpoint Service 汎用モジュール
│
├── envs/
│   ├── hub/                   # Hub VPC 環境
│   ├── spoke_prod/            # Spoke-Prod VPC 環境
│   └── spoke_dev/             # Spoke-Dev VPC 環境
│
└── docs/
    ├── architecture.md        # アーキテクチャ完全解説
    └── adr/                   # Architecture Decision Records
        ├── ADR-001_cidr_design.md
        ├── ADR-002_peering_vs_tgw.md
        ├── ADR-003_endpoint_strategy.md
        └── ADR-004_privatelink_design.md
```

---

## CIDR 設計

| VPC | CIDR | 用途 |
|---|---|---|
| Hub | `10.0.0.0/16` | 共有サービス・PrivateLink 公開元 |
| Spoke-Prod | `10.1.0.0/16` | 本番相当ワークロード |
| Spoke-Dev | `10.2.0.0/16` | 開発相当ワークロード |

---

## ハンズオン実行手順

### Phase 1: Hub-Spoke VPC 基盤

**ゴール**: 3 つの VPC（Hub / Spoke-Prod / Spoke-Dev）とサブネット・ルートテーブルを構築する。

#### 1-1. Spoke-Prod を初期化・apply

```bash
cd envs/spoke_prod
terraform init
terraform plan   # 作成されるリソースを確認
terraform apply
```

<details>
<summary>作成されるリソース（クリックで展開）</summary>

- `aws_vpc` — Spoke-Prod VPC（`10.1.0.0/16`）
- `aws_subnet` × 2 — private-1a / private-1c
- `aws_route_table` × 1 — private-rtb
- `aws_route_table_association` × 2
- `aws_default_security_group` — 全ルール削除（セキュリティハードニング）

</details>

#### 1-2. Spoke-Dev を初期化・apply

```bash
cd ../spoke_dev
terraform init
terraform plan
terraform apply
```

#### 1-3. Hub を初期化・apply

```bash
cd ../hub
terraform init
terraform plan
terraform apply
```

<details>
<summary>作成されるリソース（クリックで展開）</summary>

- `aws_vpc` — Hub VPC（`10.0.0.0/16`）
- `aws_subnet` × 4 — public-1a / public-1c / private-1a / private-1c
- `aws_route_table` × 2 — public-rtb / private-rtb
- `aws_internet_gateway` — Hub のみ IGW を作成
- `aws_route` — public-rtb に `0.0.0.0/0 → igw` を追加

</details>

#### 1-4. 動作確認

```bash
# Hub VPC が作成されていることを確認
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=vpc-network-deepdive" \
  --query "Vpcs[*].{VPC:VpcId,CIDR:CidrBlock,Name:Tags[?Key=='Name']|[0].Value}" \
  --output table

# 期待出力: 3 VPC（10.0.0.0/16, 10.1.0.0/16, 10.2.0.0/16）が表示される
```

**Phase 1 完了チェックリスト**
- [ ] 3 つの VPC が作成されている
- [ ] Hub のみ IGW がアタッチされている
- [ ] Spoke に public サブネットがない（private のみ）
- [ ] 口頭説明: 「なぜ Hub-Spoke 構成にするのか？TGW との違いは？」

---

### Phase 2: VPC Peering + ルーティング設計

**ゴール**: Hub ↔ Spoke-Prod、Hub ↔ Spoke-Dev の VPC Peering を構築し、双方向ルーティングを設定する。

> **注意**: Phase 1 で Spoke の `terraform.tfstate` が生成されていることが必須。
> Hub の `peering.tf` が `data "terraform_remote_state"` で Spoke の outputs を参照するため。

#### 2-1. Hub を apply（Peering を追加）

```bash
cd envs/hub
terraform plan   # peering.tf が新規追加されていることを確認
terraform apply
```

<details>
<summary>作成されるリソース（クリックで展開）</summary>

- `aws_vpc_peering_connection` × 2 — Hub↔Prod / Hub↔Dev
- `aws_route` × 4 — Hub の public/private RTB に Spoke の CIDR を追加
- `aws_route` × 2 — 各 Spoke の private RTB に Hub の CIDR を追加

</details>

#### 2-2. ルートテーブルの確認

```bash
# Hub private-rtb のルートを確認（10.1.0.0/16 と 10.2.0.0/16 が追加されているはず）
HUB_VPC_ID=$(cd envs/hub && terraform output -raw vpc_id)

aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=${HUB_VPC_ID}" \
  --query "RouteTables[*].Routes[?DestinationCidrBlock!='10.0.0.0/16'].[DestinationCidrBlock,VpcPeeringConnectionId]" \
  --output table

# Spoke-Prod の RTB に Hub CIDR が追加されているか確認
PROD_VPC_ID=$(cd envs/spoke_prod && terraform output -raw vpc_id)

aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=${PROD_VPC_ID}" \
  --query "RouteTables[*].Routes[?DestinationCidrBlock=='10.0.0.0/16'].[DestinationCidrBlock,VpcPeeringConnectionId]" \
  --output table
```

#### 2-3. Peering 接続のステータス確認

```bash
aws ec2 describe-vpc-peering-connections \
  --filters "Name=tag:Project,Values=vpc-network-deepdive" \
  --query "VpcPeeringConnections[*].{Name:Tags[?Key=='Name']|[0].Value,Status:Status.Code}" \
  --output table

# 期待出力: StatusCode が "active" であること
```

**Phase 2 完了チェックリスト**
- [ ] Peering 接続が 2 本 `active` になっている
- [ ] Hub の RTB に `10.1.0.0/16` と `10.2.0.0/16` のルートがある
- [ ] 各 Spoke の RTB に `10.0.0.0/16` のルートがある
- [ ] Spoke-Prod → Spoke-Dev の直接 Peering がないことを確認
- [ ] 口頭説明: 「Peering のルーティングで対称性が必要な理由は？」

---

### Phase 3: VPC Endpoint（Gateway 型 + Interface 型）

**ゴール**: Spoke VPC の EC2 が NAT Gateway・インターネットなしで S3 / SSM にアクセスできるようにする。
Spoke-Prod に疎通確認用の Bastion EC2 を配置し、Session Manager で接続確認まで行う。

#### 3-1. Spoke-Prod を apply（Endpoint + Bastion EC2 を追加）

```bash
cd envs/spoke_prod
terraform plan   # endpoints.tf と ec2_bastion.tf が新規追加を確認
terraform apply
```

<details>
<summary>作成されるリソース（クリックで展開）</summary>

**Gateway Endpoint**
- `aws_vpc_endpoint` (S3) — private-rtb に Prefix List ルート自動追加
- `aws_vpc_endpoint` (DynamoDB) — 同上

**Interface Endpoint**
- `aws_vpc_endpoint` (ssm) — private-1a / private-1c に ENI 作成
- `aws_vpc_endpoint` (ssmmessages) — 同上
- `aws_vpc_endpoint` (ec2messages) — 同上
- `aws_security_group` (endpoint-sg) — Ingress :443 ← VPC CIDR

**Bastion EC2**
- `aws_iam_role` / `aws_iam_instance_profile` — SSM 用ロール
- `aws_security_group` (bastion-sg) — Inbound 全拒否 / Outbound :443 → endpoint-sg
- `aws_instance` (bastion) — t4g.nano arm64 / IMDSv2 / encrypted gp3

</details>

#### 3-2. Spoke-Dev を apply（Endpoint のみ）

```bash
cd ../spoke_dev
terraform plan
terraform apply
```

#### 3-3. EC2 の起動完了を待つ

```bash
BASTION_ID=$(cd envs/spoke_prod && terraform output -raw bastion_instance_id)
echo "Bastion Instance ID: ${BASTION_ID}"

# SSM エージェントが起動するまで 1〜2 分待つ
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=${BASTION_ID}" \
  --query "InstanceInformationList[0].PingStatus" \
  --output text

# "Online" になるまで繰り返す（30 秒おきに再実行）
```

#### 3-4. Session Manager で Bastion EC2 に接続

```bash
BASTION_ID=$(cd envs/spoke_prod && terraform output -raw bastion_instance_id)

aws ssm start-session --target ${BASTION_ID}
# シェルが開く（SSH 不要・Inbound SG ルール不要）
```

#### 3-5. EC2 内での疎通確認

Session Manager のシェル内で以下を実行する。

```bash
# --- S3 Gateway Endpoint の確認 ---
# S3 へのアクセスがインターネット経由でないことを確認
aws s3 ls --region ap-northeast-1
# エラーなく一覧が返れば OK（バケットがなくても空のリストが返る）

# --- SSM Interface Endpoint の確認 ---
# Parameter Store にアクセス（値がなくても API 疎通の確認になる）
aws ssm get-parameter --name /nonexistent 2>&1 | grep -E "ParameterNotFound|error"
# "ParameterNotFound" が返れば SSM Endpoint 経由でアクセスできている

# --- インターネット到達不可の確認 ---
# タイムアウトすれば正しく NAT GW なしの設定になっている
curl --max-time 5 https://example.com 2>&1 | grep -E "timed out|Could not"
# "Connection timed out" が返ればインターネット接続がないことを確認できる

# セッション終了
exit
```

**Phase 3 完了チェックリスト**
- [ ] Session Manager で Bastion EC2 に接続できる（SSH なし）
- [ ] EC2 内から `aws s3 ls` が応答する（Gateway Endpoint 経由）
- [ ] EC2 内から `aws ssm get-parameter` に API 疎通がある（Interface Endpoint 経由）
- [ ] EC2 内から `curl https://example.com` がタイムアウトする（インターネット到達不可）
- [ ] 口頭説明: 「Gateway 型と Interface 型の技術的違いは？」

---

### Phase 4: カスタム PrivateLink（NLB 経由）

**ゴール**: Hub VPC の Nginx（EC2）を PrivateLink で公開し、Spoke-Prod から VPC Peering なしでもアクセスできることを確認する。

#### 4-1. Hub を apply（PrivateLink Service を追加）

```bash
cd envs/hub
terraform plan   # privatelink_service.tf が新規追加を確認
terraform apply
```

<details>
<summary>作成されるリソース（クリックで展開）</summary>

- `aws_security_group` (service-sg) — Ingress :80 ← Hub/Prod/Dev CIDR
- `aws_iam_role` / `aws_iam_instance_profile` — Nginx EC2 用 SSM ロール
- `aws_instance` (service-ec2) — t4g.nano arm64 / Nginx インストール済み
- `aws_lb` (NLB internal) — cross-zone 有効 / private-1a・private-1c に ENI
- `aws_lb_target_group` — TCP:80 / instance ターゲット
- `aws_lb_listener` — TCP:80 → Target Group
- `aws_vpc_endpoint_service` — NLB をバックエンドに指定 / `acceptance_required=false`

</details>

#### 4-2. Service Name を確認

```bash
cd envs/hub
terraform output privatelink_service_name
# 出力例: com.amazonaws.vpce.ap-northeast-1.vpce-svc-0123456789abcdef0
# この値は Spoke 側の terraform_remote_state 経由で自動参照される
```

#### 4-3. Spoke-Prod を apply（Consumer Endpoint を追加）

```bash
cd ../spoke_prod
terraform plan   # privatelink_consumer.tf が新規追加を確認
terraform apply
```

<details>
<summary>作成されるリソース（クリックで展開）</summary>

- `aws_security_group` (pl-consumer-sg) — Ingress :80 ← VPC CIDR
- `aws_vpc_endpoint` (hub_service) — Interface 型 / `private_dns_enabled=false`
  - Spoke-Prod の private-1a・private-1c に ENI を作成

</details>

#### 4-4. Endpoint のステータス確認

Consumer Endpoint が `available` になるまで 1〜2 分かかる。

```bash
cd envs/spoke_prod
terraform output hub_service_endpoint_dns
# 出力例:
# [
#   {
#     "dns_name" = "vpce-xxx.vpce-svc-xxx.ap-northeast-1.vpce.amazonaws.com",
#     "hosted_zone_id" = "Z2E726K9Y6EB4W"
#   },
#   ...
# ]

# DNS 名を変数に取得（最初のエントリを使用）
ENDPOINT_DNS=$(terraform output -json hub_service_endpoint_dns | \
  jq -r '.[0].dns_name')
echo "Endpoint DNS: ${ENDPOINT_DNS}"
```

#### 4-5. Hub Nginx の起動確認（Session Manager）

```bash
HUB_NGINX_ID=$(cd envs/hub && terraform output -raw privatelink_service_instance_id)

aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=${HUB_NGINX_ID}" \
  --query "InstanceInformationList[0].PingStatus" \
  --output text
# "Online" になるまで待つ（1〜2 分）

# Nginx が起動していることを確認
aws ssm start-session --target ${HUB_NGINX_ID}
```

Hub Nginx の Session Manager シェル内で確認する。

```bash
systemctl status nginx
# Active: active (running) であること

curl localhost
# <h1>Hub Service via PrivateLink - ip-10-0-xx-xx</h1> が返ること

exit
```

#### 4-6. PrivateLink 経由のアクセス確認（Spoke-Prod Bastion から）

```bash
BASTION_ID=$(cd envs/spoke_prod && terraform output -raw bastion_instance_id)
aws ssm start-session --target ${BASTION_ID}
```

Spoke-Prod Bastion の Session Manager シェル内で確認する。

```bash
# Endpoint DNS 名を使って Hub の Nginx にアクセス
# ※ DNS 名は前の手順で確認した値を使う
curl http://<endpoint-dns-name>
# 期待出力: <h1>Hub Service via PrivateLink - ip-10-0-xx-xx</h1>

# VPC Peering 経由でなく PrivateLink 経由であることの確認
# → traceroute の最初のホップが Endpoint ENI の IP（10.1.x.x）であること
traceroute -m 5 <endpoint-dns-name>
# 1  10.1.10.z (PrivateLink Consumer Endpoint ENI)  → これ以降はブラックホール（正常）

exit
```

#### 4-7. PrivateLink とペアリングの違いを体感する（応用）

```bash
# Spoke-Prod Bastion から Hub の Nginx EC2 に直接 Peering 経由でアクセス試みる
NGINX_PRIVATE_IP=$(cd envs/hub && \
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=vnd-hub-svc-service-ec2" \
    --query "Reservations[0].Instances[0].PrivateIpAddress" \
    --output text)

# Peering があるため IP 到達性はあるが、SG でブロックされる
curl --max-time 5 http://${NGINX_PRIVATE_IP}
# タイムアウト → service-sg が Spoke の CIDR を許可していても Peering ルートが通る
# ※ PrivateLink は特定サービスのみ公開でき、直接 IP アクセスとは別経路
```

**Phase 4 完了チェックリスト**
- [ ] Hub VPC に NLB（internal）が作成されている
- [ ] Hub VPC に VPC Endpoint Service が `available` になっている
- [ ] Spoke-Prod に Consumer Interface Endpoint が `available` になっている
- [ ] Spoke-Prod の Bastion から `curl` で Nginx レスポンスが返る
- [ ] `traceroute` の第 1 ホップが Endpoint ENI の IP（PrivateLink 経由の確認）
- [ ] 口頭説明: 「PrivateLink と VPC Peering の本質的な違い」を説明できる

---

## リソース削除（コスト管理）

**コスト発生リソースは検証後に必ず削除すること。**

### 削除順序

Consumer を先に削除してから Provider を削除する必要がある。逆順にすると Endpoint Service が Consumer Endpoint を持つ状態で削除できず失敗する。

```bash
# Step 1: Spoke-Prod（Consumer Endpoint を含む）
cd envs/spoke_prod
terraform destroy
# "Do you really want to destroy all resources?" → yes と入力

# Step 2: Spoke-Dev
cd ../spoke_dev
terraform destroy

# Step 3: Hub（NLB・Nginx EC2・Endpoint Service を含む）
cd ../hub
terraform destroy
```

### 削除確認

```bash
# 全リソースが削除されたか確認
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=vpc-network-deepdive" \
  --query "Vpcs[*].VpcId" \
  --output text
# 何も返らなければ削除完了
```

---

## トラブルシューティング

### Session Manager で接続できない

```
An error occurred (TargetNotConnected) when calling the StartSession operation
```

**原因と対処**:

1. **EC2 の起動から時間が経っていない** — EC2 が起動してから SSM エージェントが SSM Service に登録されるまで 1〜3 分かかる。再度確認する。

   ```bash
   aws ssm describe-instance-information \
     --filters "Key=InstanceIds,Values=i-xxxxxxxxxx" \
     --query "InstanceInformationList[0].PingStatus"
   # Online になるまで待つ
   ```

2. **Interface Endpoint が起動していない** — Endpoint の作成から `available` になるまで 1〜2 分かかる。

   ```bash
   aws ec2 describe-vpc-endpoints \
     --filters "Name=tag:Project,Values=vpc-network-deepdive" \
     --query "VpcEndpoints[*].{Service:ServiceName,State:State}" \
     --output table
   ```

3. **SSM・SSMMessages・EC2Messages の 3 エンドポイントが揃っているか確認** — 1 つでも欠けると接続できない。

### PrivateLink Consumer Endpoint が `pending` のまま

**原因**: Hub 側の Endpoint Service が `acceptance_required = true` になっている場合（このハンズオンでは `false` を設定しているため通常は発生しない）。

```bash
# Endpoint Service のステータス確認
aws ec2 describe-vpc-endpoint-service-configurations \
  --query "ServiceConfigurations[*].{Name:ServiceName,AcceptanceRequired:AcceptanceRequired,State:ServiceState}" \
  --output table
```

### `terraform_remote_state` が失敗する

```
Error: Unable to read remote state
```

**原因**: 参照先の `terraform.tfstate` がまだ存在しない。

```bash
# Spoke の tfstate が存在するか確認
ls -la envs/spoke_prod/terraform.tfstate
ls -la envs/spoke_dev/terraform.tfstate

# 存在しない場合は Spoke を先に apply する
cd envs/spoke_prod && terraform apply
cd ../spoke_dev && terraform apply
```

### `terraform plan` で Provider プラグインエラー

```
failed to instantiate provider: Unrecognized remote plugin message
```

**原因**: ダウンロード済みのプロバイダーバイナリがこの OS アーキテクチャで動作しない（例: WSL2 環境で x86_64 以外のバイナリ）。

```bash
# .terraform ディレクトリを削除して再 init
rm -rf .terraform .terraform.lock.hcl
terraform init
```

---

## コスト目安

フェーズごとに **検証後即 destroy** を前提とした場合の 2 時間あたりの費用。

| フェーズ | 追加リソース | 2 時間コスト |
|---|---|---|
| Phase 1〜2 | VPC・Peering | $0 |
| Phase 3 | Interface Endpoint × 6（Prod+Dev）| $0.17 |
| Phase 4 | NLB + Consumer Endpoint + EC2 | $0.12 |
| **合計** | | **$0.29** |

> Interface Endpoint と NLB は時間課金のため、使い終わったら `terraform destroy` を忘れずに実行すること。

---

## 参考ドキュメント

| ドキュメント | 内容 |
|---|---|
| [docs/architecture.md](docs/architecture.md) | アーキテクチャ全体解説・Mermaid 図・通信フロー詳細 |
| [docs/adr/ADR-001](docs/adr/ADR-001_cidr_design.md) | CIDR 設計の判断根拠 |
| [docs/adr/ADR-002](docs/adr/ADR-002_peering_vs_tgw.md) | VPC Peering を TGW の代わりに採用した理由 |
| [docs/adr/ADR-003](docs/adr/ADR-003_endpoint_strategy.md) | VPC Endpoint 戦略（Gateway vs Interface） |
| [docs/adr/ADR-004](docs/adr/ADR-004_privatelink_design.md) | カスタム PrivateLink の設計判断 |
