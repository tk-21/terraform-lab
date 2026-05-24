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
| VM スペック | t4g.nano Spot（arm64） | e2-micro Preemptible | B1s Spot（arm64） |
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
# まだ鍵がない場合は生成する
ssh-keygen -t ed25519 -C "cloud-agnostic-infra-lab" -f ~/.ssh/cail_key

# 公開鍵の内容を確認（後で使う）
cat ~/.ssh/cail_key.pub
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
```

### 6-2. SSH 公開鍵の準備

```bash
# 公開鍵の内容を変数に格納
SSH_PUB_KEY=$(cat ~/.ssh/cail_key.pub)
echo $SSH_PUB_KEY
# → ssh-ed25519 AAAA... cloud-agnostic-infra-lab
```

### 6-3. 初期化・計画

```bash
cd ../azure   # gcp/ から移動する場合
# または
cd azure      # プロジェクトルートから

terraform init

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
- `azurerm_linux_virtual_machine_scale_set` — VMSS（B1s Spot, arm64）

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
| Compute | t4g.nano Spot 〜$1 | e2-micro 〜$0（無料枠） | B1s Spot 〜$3 |
| ロードバランサー | ALB 〜$16 | Global LB 〜$18 | Standard LB 〜$18 |
| データ転送 | 〜$0.01 | 〜$0.01 | 〜$0.01 |
| **合計** | **〜$17** | **〜$18** | **〜$21** |

> 少量トラフィック前提。3クラウド同時起動で最大 〜$56/月。
> 検証時間を最小にして destroy することでコストを抑える。

### コスト削減の設計判断

```
❌ 禁止: NAT Gateway（月 $32 の固定費）
✅ 代替: パブリックサブネット直接配置 + IGW

❌ 禁止: x86_64 オンデマンドインスタンス
✅ 採用: arm64 + Spot（AWS） / Preemptible（GCP） / Spot（Azure）で 70〜90% 削減
```

---

## 11. トラブルシューティング

### AWS

**`curl` でタイムアウトする**
```
原因: ASGのEC2がヘルスチェックを通過するまで時間がかかっている
対処: 2〜3分待ってから再試行する
確認: EC2 → ターゲットグループ → ターゲット の Status が "healthy" になるまで待つ
```

**Spotインスタンスが起動しない**
```
原因: ap-northeast-1 で t4g.nano の Spot 在庫がない（まれ）
対処: terraform.tfvars で instance_type を "t4g.micro" に変更して再実行
```

### GCP

**`terraform apply` 後も LB に接続できない**
```
原因: Global LBのプロビジョニングには 5〜10 分かかる
対処: curl を繰り返しながら待つ（404 → 502 → 200 の順に変化する）
確認: GCPコンソール → Network Services → Load Balancing → Backend の Status が "Healthy"
```

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

**VMSSのインスタンスが LB に登録されない**
```
原因: VMSS のプロビジョニングに時間がかかっている（3〜5分）
確認: Azure Portal → Load Balancer → Backend Pools → VM が "Succeeded" になるまで待つ
```

**Spot VMが起動できない**
```
原因: japaneast で B1s の Spot 在庫がない
対処: location を "japanwest" に変更するか、priority を "Regular" に変更して再実行
```

---

## 参考リンク

| ドキュメント | 内容 |
|------------|------|
| [ARCHITECTURE.md](./ARCHITECTURE.md) | 全構成の詳細図・リソース解説・設計判断 |
| [comparison/](./comparison/) | 3クラウドの概念・コスト・運用比較表 |
| [adr/](./adr/) | Architecture Decision Records |
