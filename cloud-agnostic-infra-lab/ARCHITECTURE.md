# ARCHITECTURE.md — cloud-agnostic-infra-lab 完全理解ドキュメント

> 同一ワークロードを AWS / GCP / Azure の3クラウドで構築し、
> 設計・コスト・運用の差異を体験的に学ぶプロジェクト。

---

## 目次

1. [プロジェクト全体像](#1-プロジェクト全体像)
2. [共通ワークロード仕様](#2-共通ワークロード仕様)
3. [AWS 構成](#3-aws-構成)
4. [GCP 構成](#4-gcp-構成)
5. [Azure 構成](#5-azure-構成)
6. [3クラウド横断比較](#6-3クラウド横断比較)
7. [コスト設計](#7-コスト設計)
8. [ディレクトリ構成](#8-ディレクトリ構成)
9. [フェーズ一覧と進捗](#9-フェーズ一覧と進捗)

---

## 1. プロジェクト全体像

```
┌─────────────────────────────────────────────────────────────────┐
│                  cloud-agnostic-infra-lab                       │
│                                                                 │
│   同一ワークロード（nginx HTTP API）を3クラウドで並列構築        │
│                                                                 │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐        │
│   │     AWS      │  │     GCP      │  │    Azure     │        │
│   │  ap-northeast│  │asia-northeast│  │  japaneast   │        │
│   │      -1      │  │      1       │  │              │        │
│   └──────┬───────┘  └──────┬───────┘  └──────┬───────┘        │
│          │                 │                  │                 │
│          └─────────────────┼──────────────────┘                 │
│                            │                                    │
│                     比較・分析・ADR執筆                          │
└─────────────────────────────────────────────────────────────────┘
```

### プロジェクトの目的

| 目的 | 詳細 |
|------|------|
| 思考の偏りを破る | 「AWSしか触ったことがない」状態から脱却する |
| 比較した上で選択できる | 「なんとなくAWS」から「理由を言えるAWS」へ |
| 面接で語れるネタを作る | 体験ベースの設計判断を言語化する |

### IaC ツール統一の理由

全クラウドを **Terraform** で統一することで、クラウド固有の概念差異を「同じ構文で書いた場合の差」として直接比較できる。CloudFormation/Deployment Manager/Bicep を使うと「ツールの差」と「クラウドの差」が混在してしまう。

---

## 2. 共通ワークロード仕様

3クラウドで**まったく同じ役割**を担うコンポーネントを構築する。

```
Internet
    │
    ▼  HTTP :80
┌───────────────┐
│ Load Balancer │  ← L7（AWS/GCP）/ L4（Azure）
└───────┬───────┘
        │ HTTP :80
        ▼
┌───────────────┐
│ Auto Scaling  │  ← 最小1台・最大2台
│  nginx VM     │  ← arm64 / Spot / Preemptible
└───────────────┘
        │
   ┌────┴────┐
   │  VPC    │  ← パブリックサブネットのみ（NAT Gateway 禁止）
   └─────────┘
```

| コンポーネント | 役割 |
|--------------|------|
| ロードバランサー | 外部からのHTTPトラフィックを受け付け |
| オートスケーリング | VMの自動復旧・スケーリング |
| nginx | `<h1>cloud-agnostic-infra-lab: {cloud}</h1>` を返す |
| VPC / VNet | ネットワーク境界 |
| ファイアウォール | HTTP(80) のみ許可 |

### コスト設計の絶対ルール

```
❌ NAT Gateway 禁止（月 $32 相当の無駄）
✅ パブリックサブネット直接配置で代替

❌ x86_64 オンデマンドインスタンス禁止
✅ arm64 + Spot / Preemptible で最大 70〜80% 削減
```

---

## 3. AWS 構成

### アーキテクチャ図

```
ap-northeast-1
┌──────────────────────────────────────────────────────────────┐
│  VPC: 10.0.0.0/16                                            │
│                                                              │
│  ┌─────────────────────────┐  ┌─────────────────────────┐   │
│  │  Public Subnet AZ-a     │  │  Public Subnet AZ-c     │   │
│  │  10.0.1.0/24            │  │  10.0.2.0/24            │   │
│  │                         │  │                         │   │
│  │  ┌─────────────────┐    │  │  ┌─────────────────┐    │   │
│  │  │  EC2 t4g.nano   │    │  │  │  EC2 t4g.nano   │    │   │
│  │  │  (arm64 Spot)   │    │  │  │  (arm64 Spot)   │    │   │
│  │  │  nginx          │    │  │  │  nginx          │    │   │
│  │  └────────┬────────┘    │  │  └────────┬────────┘    │   │
│  └───────────┼─────────────┘  └───────────┼─────────────┘   │
│              │                             │                  │
│         ┌────┴─────────────────────────────┴────┐            │
│         │  ALB (Application Load Balancer)       │            │
│         │  cail-alb                              │            │
│         └────────────────────┬───────────────────┘            │
│                              │                                │
│  ┌───────────────────────────┼───────────────────────────┐   │
│  │  Internet Gateway (IGW)   │                           │   │
│  └───────────────────────────┘                           │   │
└──────────────────────────────────────────────────────────────┘
                               │
                          Internet
```

### リソース一覧

| Terraformリソース | AWSリソース | 役割 |
|-----------------|-------------|------|
| `aws_vpc` | VPC | リージョン単位のネットワーク境界 |
| `aws_subnet` × 2 | Subnet (AZ-a/c) | AZ単位で分割（AWS固有の設計） |
| `aws_internet_gateway` | IGW | VPCからインターネットへの出口 |
| `aws_route_table` | Route Table | 0.0.0.0/0 → IGW |
| `aws_security_group` × 2 | SG (ALB用/EC2用) | ステートフルなL4ファイアウォール |
| `aws_launch_template` | Launch Template | EC2起動設定のテンプレート |
| `aws_autoscaling_group` | ASG | min=1, max=2 の自動スケーリング |
| `aws_lb` | ALB | L7ロードバランサー |
| `aws_lb_target_group` | Target Group | ヘルスチェック付きバックエンド |
| `aws_lb_listener` | Listener | ポート80でALBがリッスン |

### AWS固有の設計ポイント

```
【VPCはリージョン単位】
  ap-northeast-1 の VPC は ap-northeast-1 にしか存在しない
  → 別リージョンに展開するには VPC を作り直す必要がある
  → GCP のグローバルVPCとの最大の違い

【サブネットはAZ単位】
  AZ-a と AZ-c で別々のサブネットを定義する必要がある
  → GCP/Azure はリージョン単位のサブネットなのでこの作業が不要

【セキュリティグループはENIにアタッチ】
  SGはインスタンス（正確にはENI）に紐づく
  → EC2用SGはALBからのトラフィックのみ許可（直接外部公開しない）
  → GCPのネットワークタグベースとは概念が根本的に異なる

【IGWは明示的なリソース】
  VPCを作っただけではインターネットに出られない
  → IGWを作成してRoute Tableに0.0.0.0/0を設定する必要がある
  → GCPはこの設定が不要（デフォルトルートが自動）
```

### 変数

| 変数名 | デフォルト | 説明 |
|--------|-----------|------|
| `region` | `ap-northeast-1` | AWSリージョン |
| `project` | `cail` | リソース名・タグのプレフィックス |
| `env` | `dev` | 環境名 |

### 出力

| 出力名 | 説明 |
|--------|------|
| `alb_dns_name` | ALBのDNS名（疎通確認用） |
| `vpc_id` | VPC ID |

---

## 4. GCP 構成

### アーキテクチャ図

```
Global（GCPのLBはグローバルリソース）
┌─────────────────────────────────────────────────────────────────┐
│  Global Load Balancer                                           │
│                                                                 │
│  Forwarding Rule (port 80)                                      │
│       ↓                                                         │
│  Target HTTP Proxy                                              │
│       ↓                                                         │
│  URL Map                                                        │
│       ↓                                                         │
│  Backend Service ←── Health Check (独立リソース)                 │
│       ↓                                                         │
└───────────────────────────────────┬─────────────────────────────┘
                                    │
asia-northeast1（リージョン）        │
┌───────────────────────────────────┴─────────────────────────────┐
│  VPC Network: cail-vpc（グローバルリソース！）                    │
│                                                                  │
│  Subnetwork: 10.0.1.0/24（リージョン単位）                       │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                                                          │   │
│  │  ┌─────────────────┐    ┌─────────────────┐             │   │
│  │  │  VM e2-micro    │    │  VM e2-micro    │             │   │
│  │  │  (Preemptible)  │    │  (Preemptible)  │             │   │
│  │  │  tag:nginx-server│   │  tag:nginx-server│            │   │
│  │  │  nginx          │    │  nginx          │             │   │
│  │  └─────────────────┘    └─────────────────┘             │   │
│  │                                                          │   │
│  │  Managed Instance Group (MIG) — マルチゾーン自動分散      │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
│  Firewall Rules（ネットワーク全体に適用、タグで対象を絞る）        │
│  ・allow-http-lb: 0.0.0.0/0 → tag:nginx-server :80             │
│  ・allow-iap-ssh: 35.235.240.0/20 → tag:nginx-server :22       │
└──────────────────────────────────────────────────────────────────┘
```

### リソース一覧

| Terraformリソース | GCPリソース | 役割 |
|-----------------|-------------|------|
| `google_compute_network` | VPC Network | **グローバル**リソース（AWSと最大の差異） |
| `google_compute_subnetwork` | Subnetwork | リージョン単位（AWSはAZ単位） |
| `google_compute_firewall` × 2 | Firewall Rule | ネットワークタグで対象VMを指定 |
| `google_compute_instance_template` | Instance Template | VM起動設定（AWSのLaunch Templateに相当） |
| `google_compute_health_check` | Health Check | **独立リソース**（AWSはTGに内包） |
| `google_compute_region_instance_group_manager` | MIG (Regional) | マルチゾーン自動分散（AWSのASGに相当） |
| `google_compute_backend_service` | Backend Service | MIGをLBのバックエンドとして登録 |
| `google_compute_url_map` | URL Map | URLルーティングルール |
| `google_compute_target_http_proxy` | HTTP Proxy | プロトコル終端 |
| `google_compute_global_forwarding_rule` | Forwarding Rule | グローバルIPからのトラフィック受付 |

### GCP固有の設計ポイント

```
【VPCがグローバルリソース】
  1つのVPCが全リージョンをカバーする
  → マルチリージョン構成でVPCを使い回せる
  → AWSのようにリージョンごとにVPCを作る必要がない
  → ただし「どのリージョンにあるか」の意識が薄くなりやすい

【ファイアウォールはネットワークタグで適用】
  SGをインスタンスにアタッチするAWSと違い、
  VMにタグ（nginx-server）を付けると、そのタグを持つVMに
  Firewallルールが自動適用される
  → VM群を動的にFirewallで管理できる（スケールに強い）

【LBは複数リソースの連鎖構成】
  Forwarding Rule → HTTP Proxy → URL Map → Backend Service
  → AWSのALBは1リソースでこれをカバー（シンプル）
  → GCPは部品の組み合わせで柔軟なルーティングが可能

【Health Checkが独立リソース】
  複数のMIGやBackend Serviceで1つのHealth Checkを再利用できる
  → AWSのTarget GroupはTG削除時にHealth Check設定も消える

【e2-micro 無料枠】
  月730時間まで1インスタンス無料（us-east1/us-west1/us-central1は確実）
  asia-northeast1でも無料枠が適用される場合がある
```

### 変数

| 変数名 | デフォルト | 説明 |
|--------|-----------|------|
| `project_id` | なし（必須） | GCPプロジェクトID |
| `region` | `asia-northeast1` | GCPリージョン |
| `project` | `cail` | ラベル・リソース名のプレフィックス |
| `env` | `dev` | 環境名 |

### 出力

| 出力名 | 説明 |
|--------|------|
| `lb_ip_address` | LBのグローバルIP（疎通確認用） |
| `network_name` | VPCネットワーク名 |

---

## 5. Azure 構成

### アーキテクチャ図

```
Azure Subscription
┌─────────────────────────────────────────────────────────────────┐
│  Resource Group: cail-rg（Azure固有概念 — ライフサイクル管理単位）│
│                                                                  │
│  Public IP (独立リソース)                                        │
│       ↓                                                          │
│  Load Balancer (Standard, L4)                                   │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  Frontend IP Config ← Public IP                        │    │
│  │  LB Rule: TCP :80 → Backend Pool                       │    │
│  │  Health Probe: HTTP GET / :80                          │    │
│  └─────────────────────────────┬───────────────────────────┘    │
│                                │                                 │
│  Virtual Network: 10.0.0.0/16  │                                │
│  ┌─────────────────────────────┴───────────────────────────┐    │
│  │  Subnet: 10.0.1.0/24                                    │    │
│  │  ┌─────────────────────────────────────────────────┐    │    │
│  │  │  NSG (Network Security Group)                   │    │    │
│  │  │  ・AllowHTTP: Inbound TCP :80 priority=100      │    │    │
│  │  └──────────────────────────────────────────────── ┘    │    │
│  │                                                          │    │
│  │  ┌────────────────────────────────────────────────┐     │    │
│  │  │  VMSS (Virtual Machine Scale Set)              │     │    │
│  │  │  ┌───────────────┐  ┌───────────────┐         │     │    │
│  │  │  │  B1s Spot     │  │  B1s Spot     │         │     │    │
│  │  │  │  arm64        │  │  arm64        │         │     │    │
│  │  │  │  Ubuntu 22.04 │  │  Ubuntu 22.04 │         │     │    │
│  │  │  │  nginx        │  │  nginx        │         │     │    │
│  │  │  └───────────────┘  └───────────────┘         │     │    │
│  │  └────────────────────────────────────────────────┘     │    │
│  └──────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

### リソース一覧

| Terraformリソース | Azureリソース | 役割 |
|-----------------|--------------|------|
| `azurerm_resource_group` | Resource Group | **Azure固有**：リソースのライフサイクル管理単位 |
| `azurerm_virtual_network` | VNet | リージョン単位のネットワーク境界 |
| `azurerm_subnet` | Subnet | リージョン単位（AWSのようなAZ分割は不要） |
| `azurerm_network_security_group` | NSG | 優先度番号付きのファイアウォールルール |
| `azurerm_subnet_network_security_group_association` | NSG関連付け | サブネットにNSGを適用 |
| `azurerm_public_ip` | Public IP | **独立リソース**（AWS/GCPはLBに内包） |
| `azurerm_lb` | Load Balancer | L4ロードバランサー（L7はApplication Gatewayが別途必要） |
| `azurerm_lb_backend_address_pool` | Backend Pool | LBのバックエンドVMプール |
| `azurerm_lb_probe` | Health Probe | ヘルスチェック設定 |
| `azurerm_lb_rule` | LB Rule | フロントエンドIPとバックエンドプールの紐付け |
| `azurerm_linux_virtual_machine_scale_set` | VMSS | VMのオートスケーリング（ASG/MIGに相当） |

### Azure固有の設計ポイント

```
【Resource Groupという概念】
  AWSにもGCPにもない Azure 独自の論理コンテナ
  → 「RGを削除すれば中のリソースが全部消える」という強力な特性
  → 環境（dev/staging/prod）の分離に使うのが一般的
  → これを知ると「Terraform destroyより先にRG削除」という運用も生まれる

【Public IPが独立リソース】
  LBとは別にPublic IPリソースを作成してアタッチする
  → AWS（ALBに内包）/GCP（Forwarding Ruleに内包）とは異なる「明示的管理」思想
  → IPアドレスを事前確保し、複数リソースで使い回せる

【LBはL4（Azure Load Balancer） vs L7（Application Gateway）】
  今回はコスト最小化のためL4 LBを選択
  → ALB相当の機能（パスベースルーティング等）が必要な場合は
    Application Gateway が必要（追加コスト発生）
  → AWSのALBとAzureのLBは同じに見えて役割が異なる

【NSGの優先度番号制御】
  ルールに priority=100 のような番号を付けて評価順を制御する
  → GCPのFirewallルールと同様の概念（AWSのNACLも番号制御だが SGはない）

【Spot VMのeviction_policy】
  "Deallocate"（停止してIPとストレージを保持）と
  "Delete"（削除してリソースを解放）を選択できる
  → Deallocateはデータが消えないが課金が続く場合がある点に注意
```

### 変数

| 変数名 | デフォルト | 説明 |
|--------|-----------|------|
| `subscription_id` | なし（必須） | AzureサブスクリプションID |
| `location` | `japaneast` | Azureリージョン（"location"と呼ぶ） |
| `project` | `cail` | タグ・リソース名のプレフィックス |
| `env` | `dev` | 環境名 |
| `ssh_public_key` | なし（必須） | VMSSのSSH公開鍵 |

### 出力

| 出力名 | 説明 |
|--------|------|
| `lb_public_ip` | LBのパブリックIP（疎通確認用） |
| `resource_group_name` | リソースグループ名 |

---

## 6. 3クラウド横断比較

### ネットワーク概念対応表

```
                  AWS              GCP              Azure
                  ─────────────    ─────────────    ─────────────
ネットワーク境界   VPC              VPC Network      VNet
                  ↕ リージョン単位  ↕ グローバル      ↕ リージョン単位

サブネット単位     AZ単位           リージョン単位    リージョン単位
                  ap-northeast-1a  asia-northeast1  japaneast
                  ap-northeast-1c
                  （複数必要）      （1つでOK）       （1つでOK）

インターネット接続  IGW（明示的）    自動（ルート）    内包（自動）

ファイアウォール   SG（ENIアタッチ）  Firewall（タグ）  NSG（Subnet/NIC）
                  ステートフル       ステートフル      ステートフル
                  + NACL（ステートレス）

ロードバランサー   ALB（L7, Regional）  Global LB（L7, グローバル）  LB（L4）
                                                        + App Gateway（L7）

オートスケーリング  ASG              MIG (Regional)   VMSS
```

### コンポーネント対応表

| 役割 | AWS | GCP | Azure |
|------|-----|-----|-------|
| ネットワーク境界 | VPC（リージョン） | VPC Network（グローバル） | VNet（リージョン） |
| サブネット粒度 | AZ単位 | リージョン単位 | リージョン単位 |
| ファイアウォール | Security Group + NACL | Firewall Rules（タグ） | NSG（優先度番号） |
| 仮想マシン設定テンプレート | Launch Template | Instance Template | VMSS model |
| オートスケーリング | Auto Scaling Group | Managed Instance Group | VM Scale Set |
| L7 ロードバランサー | ALB | Cloud Load Balancing | Application Gateway |
| ヘルスチェック | TG内包 | 独立リソース | Probe（LB内） |
| SSHの安全な接続 | Session Manager | IAP Tunnel | Azure Bastion |
| ログ | CloudWatch Logs | Cloud Logging | Azure Monitor |
| ARM アーキテクチャ | Graviton2 (arm64) | arm64対応 | arm64対応 |
| Spot / 割り込みVM | Spot Instance | Preemptible VM | Spot VM |
| リソースグループ概念 | なし（タグで代替） | なし（プロジェクトで代替） | Resource Group |

### IAM 概念対応表

| 概念 | AWS | GCP | Azure |
|------|-----|-----|-------|
| 権限定義の単位 | Policy（JSON） | Role（YAML） | Role Definition |
| アイデンティティ | User/Role/Group | Service Account | Service Principal / Managed Identity |
| VMへの権限付与 | Instance Profile → IAM Role | VM に SA をアタッチ | Managed Identity → VM |
| スコープ階層 | Account > Resource ARN | Org > Folder > Project > Resource | Management Group > Subscription > RG > Resource |
| クロス境界制御 | ARNで強力な制御 | リソース階層で継承 | RBAC + Azure AD（複雑だが強力） |

### LB の設計思想の違い

```
AWS ALB（シンプル）
──────────────────
  ALB
  └── Listener (port 80)
       └── Target Group
            └── EC2 × N
  → 1リソースで完結。シンプルで直感的。

GCP Global LB（部品の組み合わせ）
───────────────────────────────────
  Forwarding Rule（IPとポートの受付）
  └── Target HTTP Proxy（プロトコル処理）
       └── URL Map（ルーティングルール）
            └── Backend Service（バックエンド管理）
                 └── MIG（VMグループ）
  → 複雑だが各部品を独立して差し替え・再利用できる。
  → グローバルIPで世界中のトラフィックを処理できる。

Azure LB（L4/L7が分離）
───────────────────────
  Public IP（独立リソース）
  └── Load Balancer（L4）
       ├── Frontend IP Config
       ├── Backend Pool
       ├── Health Probe
       └── LB Rule
  → L7が必要な場合は Application Gateway を別途作成する。
  → Public IPが独立しているためIPの事前確保・共有が可能。
```

---

## 7. コスト設計

### 推定月額コスト比較

| コンポーネント | AWS | GCP | Azure |
|--------------|-----|-----|-------|
| Compute | t4g.nano Spot 〜$1 | e2-micro 〜$0（無料枠） | B1s Spot 〜$3 |
| ロードバランサー | ALB 〜$16 | Global LB 〜$18 | Standard LB 〜$18 |
| データ転送 | 〜$0.01 | 〜$0.01 | 〜$0.01 |
| **合計（概算）** | **〜$17** | **〜$18** | **〜$21** |

> 少量トラフィック前提。GCPはe2-microの無料枠が適用できる場合、Computeは0円。

### コスト削減設計の一覧

| 削減ポイント | AWS | GCP | Azure |
|------------|-----|-----|-------|
| NAT Gateway回避 | パブリックサブネット直接配置 | Cloud NAT不使用・外部IP直付け | パブリックサブネット配置 |
| Computeコスト | Spot（最大70%削減） | Preemptible（最大80%削減） | Spot（最大90%削減） |
| アーキテクチャ | arm64 Graviton2（x86比20%安） | e2-micro（無料枠対象） | arm64対応B1s |
| インスタンスサイズ | t4g.nano（最小） | e2-micro（最小） | B1s（最小） |

### NAT Gateway を使わない設計の意図

```
一般的な構成（コスト高）:
  Internet → ALB (Public) → EC2 (Private Subnet) → NAT GW → Internet
  コスト: NAT GW 固定費 $32/月 + データ処理料

このプロジェクトの構成（コスト最適）:
  Internet → ALB (Public) → EC2 (Public Subnet) → Internet Gateway
  コスト: 追加費用なし

理由: 学習・検証用途のため、EC2をパブリックサブネットに直置きして
      IGW経由でパッケージ取得する。本番ではプライベートサブネット + 
      NAT Gateway or VPCエンドポイントを検討する。
```

---

## 8. ディレクトリ構成

```
cloud-agnostic-infra-lab/
│
├── ARCHITECTURE.md          ← このファイル
├── CLAUDE.md                ← プロジェクトルール（AI向け指示書）
├── README.md                ← GitHubポートフォリオ用
├── .gitignore               ← tfstate/pem等を除外
│
├── aws/                     ← AWS構成（ベースライン）
│   ├── main.tf              ← 全リソース定義（フラット構成）
│   ├── variables.tf
│   └── outputs.tf
│
├── gcp/                     ← GCP構成
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
│
├── azure/                   ← Azure構成
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
│
├── comparison/              ← 3クラウド比較資料
│   ├── cost.md              ← コスト比較
│   ├── network-concepts.md  ← ネットワーク概念比較
│   ├── iam-concepts.md      ← IAM概念比較
│   └── operations.md        ← 運用比較
│
├── adr/                     ← Architecture Decision Records
│   ├── adr-001-why-same-workload.md     ← なぜ同一ワークロードで比較したか
│   ├── adr-002-terraform-for-all.md     ← なぜTerraformで統一したか
│   ├── adr-003-why-aws-in-production.md ← なぜ本番はAWSを選ぶか（最重要）
│   └── interview-qa.md                  ← 面接想定Q&A
│
└── phase1.md 〜 phase5.md   ← 各フェーズの実装ガイド
```

### フラット構成を選んだ理由

```
❌ modules/ に分割した場合:
  aws/modules/network/main.tf
  aws/modules/compute/main.tf
  aws/modules/loadbalancer/main.tf
  → 3クラウドで9ファイルを横断しないと全体像が見えない

✅ フラット構成:
  aws/main.tf に全リソースが並ぶ
  → 1ファイルでAWSの全構成を読める
  → 3クラウドの対応リソースを横に並べて比較しやすい
  → このプロジェクトの目的（比較学習）に最適
```

---

## 9. フェーズ一覧と進捗

| フェーズ | 内容 | 状態 | 成果物 |
|---------|------|------|--------|
| Phase 1 | AWS構築（ベースライン） | ✅ 完了 | `aws/main.tf` 他 |
| Phase 2 | GCP構築 | ✅ 完了 | `gcp/main.tf` 他 |
| Phase 3 | Azure構築 | ✅ 完了 | `azure/main.tf` 他 |
| Phase 4 | 比較レポート生成 | ✅ 完了 | `comparison/` 4ファイル |
| Phase 5 | ADR執筆 + 面接準備 | ⏳ 進行中 | `adr/` 構造完備、内容記入中 |

### Phase 5 完了チェックリスト

- [ ] `adr-001`: コンテキスト・理由・結果セクションを自分の言葉で記入
- [ ] `adr-002`: コンテキスト・却下理由・結果セクションを自分の言葉で記入
- [ ] `adr-003`: 全5セクションを自分の言葉で記入（**最重要**）
- [ ] `interview-qa.md`: Q1〜Q5の回答を自分の言葉で記入
- [ ] `comparison/` 各ファイルの「所感」セクションを記入
- [ ] ADR-003を見ずに3分で話せる
- [ ] 15分口頭説明を完走できる

---

## タグ規約

全クラウドのリソースに以下のタグ（または相当するラベル）を付与する。

```hcl
# AWS / Azure
tags = {
  Project     = "cloud-agnostic-infra-lab"
  Environment = "dev"
  ManagedBy   = "terraform"
  Cloud       = "aws"  # or "gcp" / "azure"
}

# GCP (ラベルはすべて小文字)
labels = {
  project     = "cail"
  environment = "dev"
  managed_by  = "terraform"
  cloud       = "gcp"
}
```

---

## よくある疑問

**Q: なぜモジュール分割しないのか？**
A: このプロジェクトの目的は3クラウドの比較学習。`aws/main.tf` を1ファイルで読めることが比較しやすさに直結するため、あえてフラット構成を採用した。モジュール化は再利用性が求められる本番プロジェクトで行う。

**Q: なぜ全クラウドで同じワークロードなのか？**
A: 「ツールの差」ではなく「クラウドの設計思想の差」を見るため。ワークロードが違うと比較の前提条件が揃わない。nginx というシンプルな題材を選んだことで、インフラの概念差異にフォーカスできる。

**Q: Terraform の state はどこに保存するか？**
A: ローカル（学習用途のため）。本番運用では AWS は S3+DynamoDB、GCP は Cloud Storage、Azure は Azure Blob Storage で管理する。

**Q: 実際にデプロイして動かせるか？**
A: 各クラウドのアカウントと認証設定があれば `terraform apply` で構築できる。ただし LB の固定費（〜$16〜18/月）が発生するため、検証後は速やかに `terraform destroy` すること。
