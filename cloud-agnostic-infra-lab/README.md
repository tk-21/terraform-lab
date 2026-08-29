# cloud-agnostic-infra-lab

> 同一ワークロード（nginx HTTP API）を **AWS / GCP / Azure** の3クラウドで Terraform により構築し、
> 設計・コスト・運用の差異を**体験**として学ぶハンズオンプロジェクト。

---

## このハンズオンで得られること

### 技術的スキル

| 分野 | 得られること |
|------|------------|
| **マルチクラウド設計** | VPC・LB・オートスケーリングの概念が3クラウドでどう異なるかを手で実感できる |
| **Terraform** | AWS/GCP/Azure の各プロバイダーを同一の HCL 構文で扱う実践的な経験 |
| **ネットワーク設計** | IGW・ルートテーブル・セキュリティグループ・NSG・Firewall Rules の役割の違い |
| **コスト最適化** | NAT Gateway 回避・Spot/Preemptible 活用・arm64 選択という具体的なコスト削減手法 |
| **IAM の違い** | Instance Profile（AWS）・Service Account（GCP）・Managed Identity（Azure）の設計思想の差 |

### 思考の変化

```
Before: 「AWSしか触ったことがない」「他クラウドはよくわからない」

After:  「3クラウドを比較した上で、この要件ではAWSを選ぶ理由がある」
         「GCPのグローバルVPCが有利なシナリオはこういうケース」
         「AzureのResource Groupという概念は運用設計に影響する」
```

### 面接で語れるネタ

- 「他クラウドは触ったことありますか？」→ 構築体験をもとに具体的に答えられる
- 「なぜAWSを選ぶのですか？」→ 比較した上での根拠を話せる
- 「IaCはTerraform以外使えますか？」→ マルチクラウドでの実践経験を示せる
- 「コスト最適化で意識していることは？」→ NAT Gateway・Spot・arm64 を具体的に語れる

---

## 目次

1. [アーキテクチャ概要](#1-アーキテクチャ概要)
2. [前提条件](#2-前提条件)
3. [リポジトリのセットアップ](#3-リポジトリのセットアップ)
4. [AWS 構築手順](#4-aws-構築手順)
5. [GCP 構築手順](#5-gcp-構築手順)
6. [Azure 構築手順](#6-azure-構築手順)
7. [3クラウド比較の確認](#7-3クラウド比較の確認)
8. [後片付け（リソース削除）](#8-後片付けリソース削除)
9. [ディレクトリ構成](#9-ディレクトリ構成)
10. [コスト設計](#10-コスト設計)
11. [トラブルシューティング](#11-トラブルシューティング)

---

## 1. アーキテクチャ概要

3クラウドで**まったく同じ役割**のコンポーネントを構築する。

```
Internet
    │  HTTP :80
    ▼
┌──────────────────────────────────────────────────────────────┐
│                   Load Balancer                              │
│   AWS: ALB（L7, Regional）                                   │
│   GCP: Global Load Balancer（L7, グローバル）                 │
│   Azure: Standard Load Balancer（L4, Regional）              │
└──────────────────────────┬───────────────────────────────────┘
                           │  HTTP :80
                           ▼
┌──────────────────────────────────────────────────────────────┐
│                Auto Scaling Group / MIG / VMSS               │
│                                                              │
│  ┌──────────────────┐        ┌──────────────────┐           │
│  │  nginx VM        │        │  nginx VM        │           │
│  │  arm64 / Spot    │        │  arm64 / Spot    │           │
│  └──────────────────┘        └──────────────────┘           │
└──────────────────────────────────────────────────────────────┘
                           │
             VPC / VNet（パブリックサブネットのみ）
                           │
                    Internet Gateway
```

| コンポーネント | AWS | GCP | Azure |
|--------------|-----|-----|-------|
| ネットワーク | VPC（リージョン） | VPC Network（グローバル） | VNet（リージョン） |
| ロードバランサー | ALB | Global LB | Standard LB |
| オートスケーリング | ASG | MIG（Regional） | VMSS |
| VM スペック | t4g.nano Spot（arm64） | e2-micro Preemptible | D2s v5 Regular（x64） |
| ファイアウォール | Security Group | Firewall Rules（タグ） | NSG |

---

## 2. 前提条件

### 必須ツール

```bash
# バージョン確認コマンド
terraform --version   # >= 1.6 が必要
aws --version         # AWS CLI v2
gcloud --version      # Google Cloud SDK
az --version          # Azure CLI

# curl（疎通確認用）
curl --version
```

### クラウドアカウント

| クラウド | 必要なもの | 注意事項 |
|---------|-----------|---------|
| **AWS** | AWSアカウント + IAMユーザー（AdministratorAccess） | LB固定費 〜$16/月が発生 |
| **GCP** | GCPプロジェクト + 課金アカウント | e2-micro 無料枠内に収まる可能性あり |
| **Azure** | Azureサブスクリプション | LB固定費 〜$18/月が発生 |

> **注意**: LBは起動しているだけで課金が発生します。確認後は速やかに `terraform destroy` してください。

### SSH キーペア（Azure のみ必要）

```bash
# Azure VMSS 用の RSA 鍵を生成する（Ed25519 はこの構成で使用不可）
ssh-keygen -t rsa -b 4096 -C "cloud-agnostic-infra-lab-azure" -f ~/.ssh/cail_azure_rsa

# 公開鍵の内容を確認（後で使う）
cat ~/.ssh/cail_azure_rsa.pub
# → ssh-rsa AAAA... cloud-agnostic-infra-lab-azure
```

---

## 3. リポジトリのセットアップ

```bash
# クローン
git clone <このリポジトリのURL>
cd cloud-agnostic-infra-lab

# ディレクトリ構成を確認
ls -la
# aws/  gcp/  azure/  comparison/  adr/  README.md  ARCHITECTURE.md
```

---

## 4. AWS 構築手順

### 4-1. 認証設定

```bash
# AWS CLI の認証確認
aws sts get-caller-identity
# {
#   "UserId": "AIDA...",
#   "Account": "123456789012",
#   "Arn": "arn:aws:iam::123456789012:user/yourname"
# }
# → AccountとArnが表示されればOK
```

認証されていない場合:

```bash
# アクセスキーで設定する場合
aws configure
# AWS Access Key ID: <入力>
# AWS Secret Access Key: <入力>
# Default region name: ap-northeast-1
# Default output format: json
```

### 4-2. 初期化・計画

```bash
cd aws

# プロバイダーのダウンロード
terraform init

# 作成されるリソースを確認（実際には何も変更しない）
terraform plan
```

`plan` の出力で以下を確認する:

```
Plan: 11 to add, 0 to change, 0 to destroy.
```

作成される主なリソース:
- `aws_vpc` — VPC
- `aws_subnet` × 2 — パブリックサブネット（AZ-a / AZ-c）
- `aws_internet_gateway` — IGW
- `aws_security_group` × 2 — ALB用・EC2用
- `aws_launch_template` — EC2起動設定（t4g.nano Spot）
- `aws_autoscaling_group` — ASG（min=1, max=2）
- `aws_lb` — ALB
- `aws_lb_target_group` + `aws_lb_listener`

### 4-3. デプロイ

```bash
# ユーザー自身が実行すること（Claude Codeは実行しない）
terraform apply
# Do you want to perform these actions? → yes と入力
```

> ALB の起動には 2〜3 分かかります。

### 4-4. 疎通確認

```bash
# ALBのDNS名を取得
ALB_DNS=$(terraform output -raw alb_dns_name)
echo $ALB_DNS
# → cail-alb-xxxxxxxxxx.ap-northeast-1.elb.amazonaws.com

# HTTPリクエストを送信（ALB起動直後はしばらく待つ）
curl http://$ALB_DNS
# → <h1>cloud-agnostic-infra-lab: AWS</h1> が返ればOK
```

応答がすぐ返らない場合は 1〜2 分待ってから再実行する（EC2の起動とヘルスチェック通過に時間がかかる）。
`502 Bad Gateway` が続く場合は、ターゲットグループの状態を確認し、`healthy` になるまで待つ。

### 4-5. コンソールで確認すべきポイント

| 確認項目 | 確認場所 | 期待値 |
|---------|---------|--------|
| EC2がSpot起動しているか | EC2 → インスタンス → ライフサイクル | `スポット` |
| ASGが正常か | EC2 → Auto Scaling グループ | `InService: 1` |
| ALBのターゲットが Healthy か | EC2 → ターゲットグループ → ターゲット | `healthy` |
| NAT Gatewayが作成されていないか | VPC → NAT Gateway | リソースなし |

### 4-6. 口頭説明チェック（Phase 1 完了後に実施）

以下を**見ずに**答えられるか確認する:

1. AWSのVPCとGCPのVPCの最大の違いは何か
2. セキュリティグループとNACLの役割の違いは何か
3. なぜNAT Gatewayを使わなかったか。代替手段は何か
4. ALBとGCP Cloud Load Balancingのアーキテクチャ上の違いは何か

<details>
<summary>回答例を表示</summary>

1. AWS の VPC はリージョン単位で、サブネットは AZ 単位に作る。一方、GCP の VPC はグローバルリソースで、サブネットだけがリージョン単位である。そのため GCP は複数リージョンでネットワーク境界を共有しやすい。
2. Security Group は ENI に関連付けるステートフルな許可型ファイアウォールで、戻り通信を自動許可する。NACL はサブネットに関連付けるステートレスなルールで、番号順に allow/deny を評価し、戻り通信も明示的に許可する必要がある。
3. 学習・検証用途で NAT Gateway の固定費を避けるためである。EC2 をパブリックサブネットに配置し、パブリック IP と IGW を経由してパッケージを取得する。本番では EC2 をプライベートサブネットに置き、NAT Gateway または VPC Endpoint を使う。
4. ALB は Listener、Rule、Target Group を 1 サービスで提供するリージョン L7 LB である。GCP Cloud Load Balancing は Forwarding Rule、HTTP Proxy、URL Map、Backend Service を組み合わせるグローバル L7 LB で、各部品を独立して差し替え・再利用できる。

</details>

---

## 5. GCP 構築手順

### 5-1. 認証設定

```bash
# GCPにログイン
gcloud auth application-default login
# ブラウザが開くので Google アカウントでログイン

# 使用するプロジェクトを確認
gcloud projects list
# PROJECT_ID         NAME                PROJECT_NUMBER
# my-project-123456  My Project          123456789

# プロジェクトを設定
gcloud config set project <YOUR_PROJECT_ID>
```

### 5-2. 必要なAPIを有効化

```bash
gcloud services enable compute.googleapis.com
# Operation ... done.
```

### 5-3. 初期化・計画

```bash
cd ../gcp   # aws/ から移動する場合
# または
cd gcp      # プロジェクトルートから

terraform init

# project_id は必須変数のためコマンドラインで渡す
terraform plan -var="project_id=<YOUR_PROJECT_ID>"
```

`plan` の出力で以下を確認する:

```
Plan: 10 to add, 0 to change, 0 to destroy.
```

作成される主なリソース:
- `google_compute_network` — VPC Network（**グローバルリソース**）
- `google_compute_subnetwork` — サブネット（リージョン単位）
- `google_compute_firewall` × 2 — HTTP許可・IAP SSH許可
- `google_compute_instance_template` — VMテンプレート（e2-micro Preemptible）
- `google_compute_health_check` — ヘルスチェック（**独立リソース**）
- `google_compute_region_instance_group_manager` — MIG（マルチゾーン自動分散）
- `google_compute_backend_service` + `google_compute_url_map` + `google_compute_target_http_proxy` + `google_compute_global_forwarding_rule` — Global LB の連鎖構成

### 5-4. デプロイ

```bash
# ユーザー自身が実行すること
terraform apply -var="project_id=<YOUR_PROJECT_ID>"
# Do you want to perform these actions? → yes と入力
```

> GCPのGlobal LBはプロビジョニングに **5〜10 分**かかります。

### 5-5. 疎通確認

```bash
# LBのグローバルIPを取得
LB_IP=$(terraform output -raw lb_ip_address)
echo $LB_IP
# → 34.xxx.xxx.xxx

# HTTPリクエストを送信（LBのプロビジョニング完了まで待つ）
curl http://$LB_IP
# → <h1>cloud-agnostic-infra-lab: GCP</h1> が返ればOK
```

> GCPのLBは `plan` 完了後も 5〜10 分ほど 404 や接続エラーが出ることがある。
> `curl` を繰り返し実行して待つ。

5〜10 分後も応答しない場合は、バックエンドが `HEALTHY` か確認する。

```bash
gcloud compute backend-services get-health cail-backend --global
```

### 5-6. AWSとの差異を観察するポイント

| 観察ポイント | AWS | GCP |
|------------|-----|-----|
| VPCのスコープ | リージョン（ap-northeast-1） | グローバル（全リージョン共通） |
| サブネット数 | AZごとに2つ作成 | リージョン単位で1つだけ |
| LBの構成要素 | ALB 1リソース | Forwarding Rule → Proxy → URL Map → Backend の連鎖 |
| ヘルスチェック | Target Group に内包 | 独立したリソース（再利用可能） |
| ファイアウォールの適用 | SGをインスタンスにアタッチ | ネットワークタグで対象を指定 |

### 5-7. 口頭説明チェック（Phase 2 完了後に実施）

1. GCPのVPCが「グローバルリソース」であることの実務上のメリットは何か
2. GCPのFirewall RulesとAWSのSGの「適用方式の違い」を説明できるか
3. GCPのLBが複数リソースの連鎖構成である理由は何か

<details>
<summary>回答例を表示</summary>

1. 1 つの VPC を複数リージョンで共有できるため、アドレス空間・Firewall Rules・ピアリングを一貫して管理しやすい。リージョンごとに VPC を作って接続する運用を減らせる。ただしサブネットはリージョン単位で設計する。
2. GCP Firewall Rules はネットワーク全体に定義し、ネットワークタグまたはサービスアカウントで対象 VM を選ぶ。AWS Security Group は ENI に直接関連付ける。どちらもステートフルだが、GCP は同じタグを持つ VM 群に一括適用しやすく、AWS はリソース単位で明示的に適用する。
3. 受付、プロトコル処理、URL ルーティング、バックエンド管理を分離し、用途に応じて個別に構成・再利用するためである。これによりグローバルな負荷分散と柔軟なパスベースルーティングを実現する。

</details>

---

## 6. Azure 構築手順

### 6-1. 認証設定

```bash
# Azureにログイン
az login
# ブラウザが開くので Microsoftアカウントでログイン

# サブスクリプション一覧を確認
az account list --output table
# Name              CloudName    SubscriptionId                        State
# My Subscription   AzureCloud   xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx  Enabled

# 使用するサブスクリプションを設定
az account set --subscription "<YOUR_SUBSCRIPTION_ID>"

# 設定を確認
az account show --query "{name:name, id:id}" --output table

# 必要な Azure Resource Provider を登録する（初回のみ）
az provider register --namespace Microsoft.Network
az provider register --namespace Microsoft.Compute
az provider register --namespace Microsoft.Resources
```

### 6-2. SSH 公開鍵の準備

```bash
# RSA 公開鍵の内容を変数に格納する
SSH_PUB_KEY=$(cat ~/.ssh/cail_azure_rsa.pub)
echo $SSH_PUB_KEY
# → ssh-rsa AAAA... cloud-agnostic-infra-lab-azure
```

### 6-3. 初期化・計画

```bash
cd ../azure   # gcp/ から移動する場合
# または
cd azure      # プロジェクトルートから

terraform init

# VM 容量を確保しやすい Japan West を明示する
export TF_VAR_location="japanwest"

# subscription_id と ssh_public_key は必須変数
terraform plan \
  -var="subscription_id=<YOUR_SUBSCRIPTION_ID>" \
  -var="ssh_public_key=${SSH_PUB_KEY}"
```

`plan` の出力で以下を確認する:

```
Plan: 11 to add, 0 to change, 0 to destroy.
```

作成される主なリソース:
- `azurerm_resource_group` — **Azure固有の概念**（RGを削除すれば中身が全部消える）
- `azurerm_virtual_network` + `azurerm_subnet` — VNet / サブネット
- `azurerm_network_security_group` — NSG（優先度番号付きルール）
- `azurerm_public_ip` — **独立リソース**（AWS/GCPとの大きな違い）
- `azurerm_lb` — Standard Load Balancer（L4）
- `azurerm_lb_backend_address_pool` + `azurerm_lb_probe` + `azurerm_lb_rule`
- `azurerm_linux_virtual_machine_scale_set` — VMSS（D2s v5 Regular, x64）

> `Standard_D2s_v5` の容量が不足する場合は、別の利用可能な SKU を選択する。VM サイズと Ubuntu イメージはどちらも x64 にする必要がある。

### 6-4. デプロイ

```bash
# ユーザー自身が実行すること
terraform apply \
  -var="subscription_id=<YOUR_SUBSCRIPTION_ID>" \
  -var="ssh_public_key=${SSH_PUB_KEY}"
# Do you want to perform these actions? → yes と入力
```

### 6-5. 疎通確認

```bash
# LBのパブリックIPを取得
LB_IP=$(terraform output -raw lb_public_ip)
echo $LB_IP
# → 20.xxx.xxx.xxx

# HTTPリクエストを送信
curl http://$LB_IP
# → <h1>cloud-agnostic-infra-lab: Azure</h1> が返ればOK
```

> VMSSのインスタンスがLBのバックエンドプールに登録されるまで 3〜5 分かかります。

### 6-6. AWSとの差異を観察するポイント

| 観察ポイント | AWS | Azure |
|------------|-----|-------|
| リソースのグルーピング | タグ（Project=cail）で論理グループ化 | Resource Group（`cail-rg`）で物理グループ化 |
| パブリックIPの扱い | ALBに内包 | 独立した `azurerm_public_ip` リソース |
| L7 LBの要否 | ALB 1つで完結 | L7が必要なら Application Gateway が別途必要 |
| ファイアウォールのルール制御 | SGは「許可のみ」（拒否は暗黙） | NSGは優先度番号で順序制御 |
| SSH接続の仕組み | Session Manager（鍵不要） | Azure Bastion（鍵が必要） |

### 6-7. 口頭説明チェック（Phase 3 完了後に実施）

1. Resource Groupという概念を知って、AWSのリソース管理と何が違うと感じたか
2. AzureのLBがL4で、L7にApplication Gatewayが別途必要な設計判断の背景は何か
3. NSGの「優先度番号」による制御は、AWSのどの概念に近いか

<details>
<summary>回答例を表示</summary>

1. Azure Resource Group はリソースの配置・RBAC・削除をまとめて扱う明示的なライフサイクル単位である。AWS では通常、アカウント、タグ、CloudFormation スタックなどを組み合わせて論理的に管理するため、同じ強制的な入れ物はない。
2. Azure Load Balancer は TCP/UDP を扱う L4 サービスで、低コストで単純な負荷分散に向く。HTTP のパスベースルーティング、TLS 終端、WAF などの L7 機能が必要な場合だけ Application Gateway を選び、機能とコストを分離する。AWS の ALB はこの L7 の役割を 1 サービスで提供する。
3. AWS の NACL に近い。どちらも番号で評価順を制御し、先に一致したルールが適用される。AWS Security Group は許可ルールのみで優先度を持たない点が異なる。

</details>

---

## 7. 3クラウド比較の確認

3クラウドの構築が完了したら、以下のファイルを読んで比較を言語化する。

```bash
# 比較資料のディレクトリ
ls comparison/
# cost.md             ← コスト比較
# network-concepts.md ← ネットワーク概念比較
# iam-concepts.md     ← IAM概念比較
# operations.md       ← 運用比較

# ADR（架決記録）
ls adr/
# adr-001-why-same-workload.md
# adr-002-terraform-for-all.md
# adr-003-why-aws-in-production.md  ← 最重要
# interview-qa.md                   ← 面接想定Q&A
```

### 比較観点チェックリスト

- [ ] 3クラウドそれぞれの LB エンドポイントに `curl` が成功する
- [ ] `comparison/network-concepts.md` の表を見ながら差異を口頭で説明できる
- [ ] `adr-003` の「AWSを選ぶ理由」を自分の言葉で3分間話せる
- [ ] `interview-qa.md` の5問すべてに答えを書いた

---

## 8. 後片付け（リソース削除）

**LBは稼働中に課金が発生します。確認が終わったら必ず削除してください。**

```bash
# AWS の削除
cd aws
terraform destroy
# Do you really want to destroy all resources? → yes と入力

# GCP の削除
cd ../gcp
terraform destroy -var="project_id=<YOUR_PROJECT_ID>"
# Do you really want to destroy all resources? → yes と入力

# Azure の削除
cd ../azure
terraform destroy \
  -var="subscription_id=<YOUR_SUBSCRIPTION_ID>" \
  -var="ssh_public_key=${SSH_PUB_KEY}"
# Do you really want to destroy all resources? → yes と入力
```

### 削除後の確認

| クラウド | 確認方法 |
|---------|---------|
| AWS | コンソール → EC2 / VPC / ALB にリソースがないこと |
| GCP | コンソール → Compute Engine / VPC Network にリソースがないこと |
| Azure | コンソール → Resource Group `cail-rg` が消えていること |

> Azureは Resource Group が削除されると中のリソースが一括削除されます。
> Resource Groupの削除が確認できれば他の確認は不要です。

---

## 9. ディレクトリ構成

```
cloud-agnostic-infra-lab/
│
├── README.md                        ← このファイル
├── ARCHITECTURE.md                  ← 完全理解ドキュメント（図入り）
├── CLAUDE.md                        ← プロジェクトルール
├── .gitignore
│
├── aws/
│   ├── main.tf                      ← VPC・SG・ALB・ASGをフラットに定義
│   ├── variables.tf                 ← region / project / env
│   └── outputs.tf                   ← alb_dns_name / vpc_id
│
├── gcp/
│   ├── main.tf                      ← VPC・Firewall・MIG・Global LBを定義
│   ├── variables.tf                 ← project_id（必須） / region / project / env
│   └── outputs.tf                   ← lb_ip_address / network_name
│
├── azure/
│   ├── main.tf                      ← RG・VNet・NSG・LB・VMSSを定義
│   ├── variables.tf                 ← subscription_id（必須） / ssh_public_key（必須） / location / project / env
│   └── outputs.tf                   ← lb_public_ip / resource_group_name
│
├── comparison/
│   ├── cost.md                      ← 推定月額コスト比較
│   ├── network-concepts.md          ← VPC・SG・LBの概念対応表
│   ├── iam-concepts.md              ← IAM設計思想の違い
│   └── operations.md                ← デプロイ・障害対応・ログの比較
│
├── adr/
│   ├── adr-001-why-same-workload.md ← なぜ同一ワークロードで比較したか
│   ├── adr-002-terraform-for-all.md ← なぜTerraformで統一したか
│   ├── adr-003-why-aws-in-production.md ← なぜ本番はAWSを選ぶか
│   └── interview-qa.md              ← 面接想定Q&A 5問
│
└── phase1.md 〜 phase5.md           ← 各フェーズの実装ガイド
```

---

## 10. コスト設計

### 推定月額コスト

| コンポーネント | AWS | GCP | Azure |
|--------------|-----|-----|-------|
| Compute | t4g.nano Spot 〜$1 | e2-micro 〜$0（無料枠） | D2s v5 Regular（料金はリージョン・契約で要確認） |
| ロードバランサー | ALB 〜$16 | Global LB 〜$18 | Standard LB 〜$18 |
| データ転送 | 〜$0.01 | 〜$0.01 | 〜$0.01 |
| **合計** | **〜$17** | **〜$18** | **料金要確認** |

> 少量トラフィック前提。Azure は D2s v5 Regular を使うため、料金計算ツールで現在のリージョン・契約に基づく見積もりを確認する。
> 検証時間を最小にして destroy することでコストを抑える。

### コスト削減の設計判断

```
❌ 禁止: NAT Gateway（月 $32 の固定費）
✅ 代替: パブリックサブネット直接配置 + IGW

AWS: arm64 + Spot を採用
GCP: Preemptible を採用
Azure: 容量確保を優先し、Regular x64（D2s v5）を採用
```

---

## 11. トラブルシューティング

### AWS

**ALB が `502 Bad Gateway` を返す**

```
原因: ターゲット EC2 で nginx が起動していない、またはヘルスチェックが未完了
確認: EC2 → ターゲットグループ → ターゲット の Status が "healthy" になるまで待つ
```

まず 2〜3 分待って再試行する。`unhealthy` が続く場合は、ターゲットの状態を確認する。

```bash
TG_ARN=$(jq -r '.resources[] | select(.type == "aws_lb_target_group" and .name == "nginx") | .instances[0].attributes.arn' terraform.tfstate)
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --output table
```

**ALB ターゲットが `Target.FailedHealthChecks` のまま**

```
原因: AMI の名前フィルターが広すぎて ECS 最適化 AL2023 AMI を選択し、
      t4g.nano で Docker / containerd と dnf がメモリを競合した
結果: OOM Killer が dnf を停止し、nginx がインストールされない
対処: 通常の AL2023 arm64 AMI に限定する
```

```hcl
values = ["al2023-ami-2023.*-kernel-6.1-arm64"]
```

修正を apply した後は、ASG の Instance refresh で既存インスタンスを新しい Launch Template のものへ置き換える。

**Spotインスタンスが起動しない**
```
原因: ap-northeast-1 で t4g.nano の Spot 在庫がない（まれ）
対処: terraform.tfvars で instance_type を "t4g.micro" に変更して再実行
```

### GCP

**`terraform apply` 後も LB に接続できない**
```
原因: Global LBのプロビジョニングには 5〜10 分かかる
対処: curl を繰り返しながら待つ（接続リセットや 5xx が一時的に出ることがある）
確認: GCPコンソール → Network Services → Load Balancing → Backend の Status が "Healthy"
```

バックエンドの状態は次でも確認できる。

```bash
gcloud compute backend-services get-health cail-backend --global
```

`HEALTHY` なら VM と nginx は正常であり、LB の反映待ちである。

**`compute.googleapis.com` が有効化されていないエラー**
```
対処:
gcloud services enable compute.googleapis.com
```

### Azure

**`terraform apply` で "subscription_id" エラー**
```
原因: -var="subscription_id=..." が渡されていない
対処: az account show でIDを確認し、コマンドに追加する
```

**Resource Provider の登録エラー**

```
原因: 必要な Azure Resource Provider の自動登録が未完了、または処理を中断した
対処: Provider を手動登録し、状態が Registered になってから plan を再実行する
```

```bash
az provider register --namespace Microsoft.Network
az provider register --namespace Microsoft.Compute
az provider register --namespace Microsoft.Resources
```

**`ssh-ed25519 SSH key is not supported`**

```
原因: この VMSS 構成は Ed25519 公開鍵を受け付けない
対処: Azure 用の RSA 鍵を作成して TF_VAR_ssh_public_key に設定する
```

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/azure_vmss_rsa -C "azure-vmss"
export TF_VAR_ssh_public_key="$(cat ~/.ssh/azure_vmss_rsa.pub)"
```

**VM サイズとイメージの CPU アーキテクチャが一致しない**

```
原因: x64 専用 SKU に Arm64 イメージを指定した
対処: VM サイズと同じアーキテクチャのイメージを選ぶ
```

この構成では `Standard_D2s_v5` と Ubuntu 22.04 Gen2（x64）の組み合わせを使用する。

```hcl
sku = "Standard_D2s_v5"

source_image_reference {
  publisher = "Canonical"
  offer     = "0001-com-ubuntu-server-jammy"
  sku       = "22_04-lts-gen2"
  version   = "latest"
}
```

**VMSSのインスタンスが LB に登録されない**
```
原因: VMSS のプロビジョニングに時間がかかっている（3〜5分）
確認: Azure Portal → Load Balancer → Backend Pools → VM が "Succeeded" になるまで待つ
```

**`SkuNotAvailable` で VMSS を作成できない**

```
原因: 対象リージョンで指定 VM サイズの空き容量を確保できない
対処: 別リージョンまたは別 SKU を選ぶ。クォータと容量不足は別問題である
```

```bash
az vm list-usage --location japanwest --output table
```

SKU を変更する場合は x64 イメージとの互換性を維持する。Resource Group の location を変更する場合は、既存リソースが置き換えになるため plan を必ず確認する。

**`Provider produced inconsistent result after apply` / `already exists`**

```
原因: Azure の非同期作成中に provider の読み取りが 404 となり、
      Azure に作成済みのリソースが Terraform state に記録されなかった
対処: まず Azure の実体を確認し、残存リソースは import する
```

例えば VNet と Load Balancer が残っている場合は、ユーザー自身で次を実行する。

```bash
SUBSCRIPTION_ID=$(az account show --query id --output tsv)

terraform import azurerm_virtual_network.main \
  "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/cail-rg/providers/Microsoft.Network/virtualNetworks/cail-vnet"

terraform import azurerm_lb.main \
  "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/cail-rg/providers/Microsoft.Network/loadBalancers/cail-lb"

terraform import azurerm_public_ip.lb \
  "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/cail-rg/providers/Microsoft.Network/publicIPAddresses/cail-pip-lb"

terraform import azurerm_subnet_network_security_group_association.public \
  "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/cail-rg/providers/Microsoft.Network/virtualNetworks/cail-vnet/subnets/cail-subnet-public"
```

部分作成リソースが多い場合は、`cail-rg` が lab 専用であることを確認して Resource Group を削除し、削除完了後に `terraform apply -refresh-only` → `terraform plan` → `terraform apply` の順に作り直す。

---

## 参考リンク

| ドキュメント | 内容 |
|------------|------|
| [ARCHITECTURE.md](./ARCHITECTURE.md) | 全構成の詳細図・リソース解説・設計判断 |
| [comparison/](./comparison/) | 3クラウドの概念・コスト・運用比較表 |
| [adr/](./adr/) | Architecture Decision Records |
