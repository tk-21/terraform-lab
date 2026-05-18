# ARCHITECTURE.md — iac-trilogy-lab 完全理解ガイド

> 同一AWSインフラを Terraform / CDK / Pulumi の3ツールで実装し、
> IaC設計哲学の差異を体感・言語化する比較検証ラボの全体像を記述する。

---

## 目次

1. [プロジェクト概要](#1-プロジェクト概要)
2. [AWSインフラ構成図](#2-awsインフラ構成図)
3. [ディレクトリ構造](#3-ディレクトリ構造)
4. [Stateバックエンド設計](#4-stateバックエンド設計)
5. [Phase 1: Terraform実装](#5-phase-1-terraform実装)
6. [Phase 2: AWS CDK実装](#6-phase-2-aws-cdk実装)
7. [Phase 3: Pulumi実装](#7-phase-3-pulumi実装)
8. [3実装の横断比較](#8-3実装の横断比較)
9. [設計判断の根拠](#9-設計判断の根拠)
10. [セキュリティ設計](#10-セキュリティ設計)
11. [コスト設計](#11-コスト設計)
12. [検証手順](#12-検証手順)

---

## 1. プロジェクト概要

### 目的

```
「とりあえずTerraform」という思考の偏りを、
あえて慣れていないツールで同じインフラを3回書くことで解体する。
```

| 項目 | 内容 |
|---|---|
| プレフィックス | `itl`（iac-trilogy-lab） |
| 環境 | `dev` のみ（検証ラボ） |
| リージョン | `ap-northeast-1`（東京） |
| 命名パターン | `itl-dev-{role}` |
| コスト目標 | ~$1/月/実装、~$3/月（3実装同時） |

### 4フェーズの構成

```
Phase 1 ──→ Phase 2 ──→ Phase 3 ──→ Phase 4
Terraform   AWS CDK    Pulumi     ADR + 比較マトリクス
(HCL)       (TypeScript) (Python)  （Takuyaが総括を記入）
```

各フェーズで **infra-spec.md** が定義する同一インフラを実装する。
実装ツールが変わっても「作られるもの」は完全に同一でなければならない。

---

## 2. AWSインフラ構成図

### 全体構成

```
┌─────────────────────────────────────────────────────────┐
│                        Internet                          │
└──────────────────────────┬──────────────────────────────┘
                           │
                    ┌──────▼──────┐
                    │     IGW     │  itl-dev-igw
                    └──────┬──────┘
                           │
┌──────────────────────────▼──────────────────────────────┐
│  VPC: itl-dev-vpc  (10.10.0.0/16)                       │
│                                                          │
│  ┌────────────────────────────────────────────────────┐ │
│  │  Public Subnet: itl-dev-public-1a                  │ │
│  │  CIDR: 10.10.1.0/24 / AZ: ap-northeast-1a         │ │
│  │                                                    │ │
│  │  ┌─────────────────────────────────────────────┐  │ │
│  │  │  EC2: itl-dev-app                           │  │ │
│  │  │  Instance Type : t4g.nano (arm64/Graviton2) │  │ │
│  │  │  AMI           : Amazon Linux 2023 (arm64)  │  │ │
│  │  │  IMDSv2        : required                   │  │ │
│  │  │  Public IP     : 自動付与（IGW疎通用）        │  │ │
│  │  │                                             │  │ │
│  │  │  ┌─────────────────────────┐               │  │ │
│  │  │  │  IAM Instance Profile   │               │  │ │
│  │  │  │  itl-dev-ec2-profile    │               │  │ │
│  │  │  │  ├ SSM接続ポリシー       │               │  │ │
│  │  │  │  └ S3アクセスポリシー    │               │  │ │
│  │  │  └─────────────────────────┘               │  │ │
│  │  │                                             │  │ │
│  │  │  ┌─────────────────────────┐               │  │ │
│  │  │  │  Security Group         │               │  │ │
│  │  │  │  itl-dev-app-sg         │               │  │ │
│  │  │  │  Ingress: なし（SSH禁止）│               │  │ │
│  │  │  │  Egress : 全許可         │               │  │ │
│  │  │  └─────────────────────────┘               │  │ │
│  │  └─────────────────────────────────────────────┘  │ │
│  └────────────────────────────────────────────────────┘ │
│                                                          │
│  ┌─────────────────────────────────────────────────┐    │
│  │  Route Table: itl-dev-public-rt                 │    │
│  │  0.0.0.0/0 → itl-dev-igw                       │    │
│  └─────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘

        ┌──────────────────────────────────────────┐
        │  S3: itl-dev-artifacts-{account_id}      │
        │  ├ Versioning: Enabled                   │
        │  ├ Public Access Block: ALL              │
        │  ├ Encryption: SSE-S3 (AES256)           │
        │  └ Ownership: BucketOwnerEnforced        │
        └──────────────────────────────────────────┘

        ┌──────────────────────────────────────────┐
        │  監視・コスト管理                          │
        │  ├ SNS: itl-dev-alerts (KMS暗号化)       │
        │  │      └ Email: takuya@example.com      │
        │  ├ AWS Budgets: $10/月 (80%, 100%通知)   │
        │  └ CloudWatch Alarm: CPU > 80% → SNS    │
        └──────────────────────────────────────────┘
```

### SSM接続フロー（SSH禁止の代替）

```
開発者のPC
    │
    │  Session Manager（HTTPS/443）
    ▼
AWS Systems Manager エンドポイント
    │
    │  ssm-agent（EC2内部で起動）
    ▼
EC2 itl-dev-app
    │
    │  Instance Profile を通じて
    ▼
IAM Role itl-dev-ec2-role
    └── AmazonSSMManagedInstanceCore（SSM接続権限）
    └── S3 インラインポリシー（バケット操作権限）
```

### ネットワーク経路（NAT Gateway不使用）

```
EC2 (10.10.1.x)
    │
    │  アウトバウンド通信（Internet疎通が必要な場合）
    ▼
Route Table: 0.0.0.0/0 → IGW
    │
    ▼
Internet Gateway
    │
    ▼
Internet（AWS API, SSM エンドポイント等）

注: SSM接続はポート22不要。EC2のパブリックIPはSGでIngressゼロのため
    外部からの接続は完全にブロックされる。
```

---

## 3. ディレクトリ構造

```
iac-trilogy-lab/
│
├── CLAUDE.md                   # プロジェクト規則（Claude Code自動ロード）
├── ARCHITECTURE.md             # このファイル
├── README.md                   # プロジェクト概要・クイックスタート
├── infra-spec.md               # 3実装共通の「正解定義」
├── phase1.md ~ phase4.md       # 各フェーズの実装ガイド
│
├── terraform/                  # Phase 1: Terraform (HCL)
│   ├── main.tf                 # Terraformバージョン・プロバイダー設定
│   ├── backend.tf              # S3バックエンド + DynamoDBロック
│   ├── locals.tf               # プレフィックス・タグ・CIDR定数
│   ├── variables.tf            # 入力変数（account_id, email）
│   ├── vpc.tf                  # VPC / Subnet / IGW / RouteTable (5リソース)
│   ├── ec2.tf                  # EC2 / IAM / AMIデータソース (8リソース)
│   ├── security_group.tf       # SG (1リソース)
│   ├── s3.tf                   # S3 + 設定リソース群 (5リソース)
│   ├── monitoring.tf           # SNS / Budgets / CloudWatch (3リソース)
│   ├── outputs.tf              # 9つの出力値
│   ├── terraform.tfvars        # account_id・通知メール（要書き換え）
│   └── .terraform.lock.hcl    # プロバイダー依存ロック
│
├── cdk/                        # Phase 2: AWS CDK (TypeScript)
│   ├── bin/
│   │   └── itl-app.ts          # エントリーポイント（App + Stack初期化）
│   ├── lib/
│   │   ├── itl-dev-stack.ts    # スタック定義・タグ伝播・Outputs
│   │   └── constructs/
│   │       ├── network.ts      # Network Construct (ec2.Vpc L2)
│   │       ├── compute.ts      # Compute Construct (ec2.Instance + L1エスケープ)
│   │       ├── storage.ts      # Storage Construct (s3.Bucket L2)
│   │       └── monitoring.ts   # Monitoring Construct (SNS/Budgets/Alarm)
│   ├── cdk.json                # CDKコンテキスト設定
│   ├── package.json            # aws-cdk-lib: ^2.254.0
│   └── tsconfig.json           # TypeScript設定
│
├── pulumi/                     # Phase 3: Pulumi (Python)
│   ├── __main__.py             # エントリーポイント（関数呼び出し + Outputs）
│   ├── config.py               # 共通設定（タグ・CIDR・Secretアクセス）
│   ├── network.py              # create_network() → (Vpc, Subnet)
│   ├── compute.py              # create_compute() → (Instance, SG)
│   ├── storage.py              # create_storage() → BucketV2
│   ├── monitoring.py           # create_monitoring() → void
│   ├── Pulumi.yaml             # プロジェクト定義（runtime: python）
│   ├── Pulumi.itl-dev.yaml     # スタック設定（region・secretref）
│   └── requirements.txt        # pulumi>=3.0.0, pulumi-aws>=6.0.0
│
├── adr/                        # 設計判断記録
│   ├── adr-001-terraform-baseline.md  # Phase 1の「当たり前」言語化
│   ├── adr-002-cdk-vs-terraform.md    # L2抽象化の価値と限界
│   ├── adr-003-pulumi-vs-hcl.md       # Output[T]型の理解と感想
│   └── adr-004-iac-selection-guide.md # 3実装比較総括（Takuya記入待ち）
│
└── docs/
    └── comparison-matrix.md    # 客観的比較 + 主観評価マトリクス
```

---

## 4. Stateバックエンド設計

### Terraform（S3 + DynamoDB）

```
┌──────────────────────────────────────────────────────┐
│  Terraform State Backend                              │
│                                                       │
│  S3 Bucket: itl-tfstate-{account_id}                 │
│  ├── Key: iac-trilogy-lab/terraform/terraform.tfstate │
│  └── Encryption: SSE-S3                              │
│                                                       │
│  DynamoDB Table: itl-tfstate-lock                    │
│  └── LockID: 排他制御（同時実行防止）                  │
└──────────────────────────────────────────────────────┘
```

```hcl
# backend.tf
terraform {
  backend "s3" {
    bucket         = "itl-tfstate-{account_id}"
    key            = "iac-trilogy-lab/terraform/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "itl-tfstate-lock"
    encrypt        = true
  }
}
```

### CDK（CloudFormation管理）

```
┌──────────────────────────────────────────────────────┐
│  CDK State = CloudFormation Stack                    │
│                                                       │
│  Stack Name: ItlDevStack                             │
│  State管理: AWSマネージド（CloudFormationサービス）    │
│  ロック機構: CloudFormation組み込み                   │
│                                                       │
│  CDK Bootstrap（1回だけ実行）:                        │
│  npx cdk bootstrap aws://{account_id}/ap-northeast-1  │
│  → CDKToolkit スタックが作成される                    │
└──────────────────────────────────────────────────────┘
```

### Pulumi（Pulumi Cloud または S3）

```
┌──────────────────────────────────────────────────────┐
│  Pulumi State Backend                                │
│                                                       │
│  デフォルト: Pulumi Cloud (SaaS)                      │
│  ローカル代替: pulumi login --local                   │
│  S3代替: pulumi login s3://itl-tfstate-{account_id}  │
│                                                       │
│  リソース識別: URN形式                                │
│  例: urn:pulumi:itl-dev::itl-trilogy-lab::            │
│       aws:ec2/instance:Instance::itl-dev-app         │
│                                                       │
│  Secret管理: state内に暗号化して保存（Terraformにない機能）│
└──────────────────────────────────────────────────────┘
```

### 3つのState管理の比較

| 観点 | Terraform | CDK | Pulumi |
|---|---|---|---|
| State保存先 | S3（自分で準備） | CloudFormation（AWSが管理） | Pulumi Cloud または S3 |
| Stateロック | DynamoDB（自分で準備） | 組み込み | 組み込み（Cloud）/ なし（ローカル） |
| Stateの視認性 | `terraform.tfstate`（JSON） | AWSコンソールで確認 | `pulumi stack export`（JSON） |
| Secret暗号化 | なし（別途SOPSが必要） | CloudFormationの仕組みに依存 | State内に暗号化して保存可能 |
| リソース識別子 | `resource_type.name` | CloudFormation 論理ID | URN（スタック+プロジェクト+型含む） |

---

## 5. Phase 1: Terraform実装

### ファイル構成と役割

```
terraform/
│
├── main.tf             ← Terraformバージョン制約・プロバイダー設定
│                          default_tags で全リソースへタグを一括適用
│
├── backend.tf          ← S3 + DynamoDB バックエンド定義
│
├── locals.tf           ← 全ファイルで参照する定数
│   prefix              = "itl-dev"
│   vpc_cidr            = "10.10.0.0/16"
│   subnet_cidr         = "10.10.1.0/24"
│   common_tags         = { Project, Env, ManagedBy, CostOwner }
│
├── variables.tf        ← 外部から受け取る値（tfvarsで注入）
│   aws_account_id      (12桁バリデーション付き)
│   notification_email  (メール形式バリデーション付き)
│
├── vpc.tf              ← ネットワーク層 (5リソース)
├── ec2.tf              ← コンピューティング層 (8リソース: AMIデータソース含む)
├── security_group.tf   ← SG (1リソース)
├── s3.tf               ← ストレージ層 (5リソース: 分離定義)
├── monitoring.tf       ← 監視・コスト管理 (3リソース)
└── outputs.tf          ← 9つの出力（SSMコマンド含む）
```

### リソース一覧（計22宣言）

```
vpc.tf (5リソース)
  aws_vpc.main
  aws_subnet.public
  aws_internet_gateway.main
  aws_route_table.public
  aws_route_table_association.public

ec2.tf (8宣言)
  data.aws_ami.al2023_arm64          ← AMIをコードで動的検索
  aws_iam_role.ec2
  aws_iam_role_policy_attachment.ec2_ssm
  aws_iam_role_policy.ec2_s3         ← インラインポリシー（S3操作）
  aws_iam_instance_profile.ec2
  aws_instance.app

security_group.tf (1リソース)
  aws_security_group.app             ← Ingress: なし、Egress: 全許可

s3.tf (5リソース)
  aws_s3_bucket.artifacts
  aws_s3_bucket_versioning.artifacts
  aws_s3_bucket_public_access_block.artifacts
  aws_s3_bucket_server_side_encryption_configuration.artifacts
  aws_s3_bucket_ownership_controls.artifacts

monitoring.tf (3リソース)
  aws_sns_topic.alerts
  aws_sns_topic_subscription.alerts_email
  aws_budgets_budget.monthly
  aws_cloudwatch_metric_alarm.ec2_cpu
```

### 重要なコードパターン

**IMDSv2強制（Terraform版 — 最もシンプル）**

```hcl
resource "aws_instance" "app" {
  instance_type = "t4g.nano"
  # ...
  metadata_options {
    http_tokens                 = "required"  # IMDSv2強制
    http_put_response_hop_limit = 1
    http_endpoint               = "enabled"
  }
}
```

**default_tags（書き忘れ防止）**

```hcl
provider "aws" {
  region = "ap-northeast-1"
  default_tags {
    tags = local.common_tags  # 全リソースへ自動付与
  }
}
```

**S3の分離定義（5ファイルに分かれる理由）**

```hcl
# Terraform の aws_s3_bucket は「バケット本体」のみ。
# 各設定（バージョニング・PAB・暗号化）は独立リソースとして定義する。
resource "aws_s3_bucket" "artifacts"                                  { ... }
resource "aws_s3_bucket_versioning" "artifacts"                       { ... }
resource "aws_s3_bucket_public_access_block" "artifacts"              { ... }
resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" { ... }
resource "aws_s3_bucket_ownership_controls" "artifacts"               { ... }
```

---

## 6. Phase 2: AWS CDK実装

### Constructの階層と責務

```
bin/itl-app.ts（エントリーポイント）
  └── ItlDevStack（スタック）
        ├── Network Construct
        │     └── ec2.Vpc L2（内部で6リソース自動生成）
        │           ├── VPC
        │           ├── Public Subnet
        │           ├── Internet Gateway
        │           ├── Route Table
        │           └── Route Table Association
        │
        ├── Storage Construct
        │     └── s3.Bucket L2（PAB・暗号化を一括設定）
        │
        ├── Compute Construct
        │     ├── ec2.SecurityGroup L2
        │     ├── iam.Role L2
        │     ├── iam.CfnInstanceProfile L1
        │     └── ec2.Instance L2 + L1エスケープハッチ（IMDSv2）
        │
        └── Monitoring Construct
              ├── sns.Topic L2
              ├── sns.Subscription L2
              ├── budgets.CfnBudget L1（L2未対応）
              └── cloudwatch.Alarm L2
```

### L1 / L2 / L3 Constructの違い

| レベル | 別名 | 概要 | 例 |
|---|---|---|---|
| L1 | Cfn Resource | CloudFormationリソースを1:1でラップ | `ec2.CfnInstance` |
| L2 | Resource | AWSリソースの高レベル抽象化（推奨） | `ec2.Instance` |
| L3 | Pattern | 複数L2を組み合わせた高レベルパターン | `ecs_patterns.ApplicationLoadBalancedFargateService` |

### L1エスケープハッチ（CDK独自の設計課題）

CDKのL2 Constructがサポートしていない設定は、L1（CloudFormationレベル）に直接アクセスする必要がある。

```typescript
// IMDSv2強制 — L2の ec2.Instance が MetadataOptions を持たないため
const cfnInstance = this.instance.node.defaultChild as ec2.CfnInstance;
cfnInstance.addPropertyOverride('MetadataOptions.HttpTokens', 'required');
cfnInstance.addPropertyOverride('MetadataOptions.HttpPutResponseHopLimit', 1);

// ↑ Terraformでは 1行、PulumiはArgs型で直接設定できるが、
//   CDKは「L2の型体系を抜け出してCFnのプロパティ名を把握する」追加コストがかかる
```

### Subnet CIDR問題（CDK特有の落とし穴）

```typescript
// CDKのec2.Vpc L2はSubnetCIDRを直接指定できない。
// infra-spec.md の 10.10.1.0/24 を確保するため、
// ダミーの reserved サブネットで 10.10.0.0/24 をスキップする。

subnetConfiguration: [
  {
    name: 'reserved',
    subnetType: ec2.SubnetType.PRIVATE_ISOLATED,
    cidrMask: 24,
    reserved: true,  // ← 10.10.0.0/24 をスキップ
  },
  {
    name: 'itl-dev-public',
    subnetType: ec2.SubnetType.PUBLIC,
    cidrMask: 24,    // ← 結果として 10.10.1.0/24 が割り当てられる
  },
],

// Terraformなら: cidr_block = "10.10.1.0/24" と直接書けばよい
```

### CDKの隠蔽リソース数

```
コード上の Construct 宣言数:  約 5〜7 個
CloudFormation 生成リソース数: 23 個

"コードは少ない、でも作られるものは多い" という逆転現象。
本番コスト見積もりや監査では cdk.out/*.template.json を確認すること。
```

---

## 7. Phase 3: Pulumi実装

### 関数ベースのモジュール構成

```
__main__.py（エントリーポイント）
  │
  ├── create_network()  → (vpc: aws.ec2.Vpc, subnet: aws.ec2.Subnet)
  │     network.py
  │     └── Vpc / Subnet / InternetGateway / RouteTable / RouteTableAssociation
  │
  ├── create_compute(vpc, subnet)  → (instance, sg)
  │     compute.py
  │     └── IAMRole / RolePolicy / InstanceProfile
  │         SecurityGroup / EC2 Instance
  │
  ├── create_storage()  → bucket: aws.s3.BucketV2
  │     storage.py
  │     └── BucketV2 / BucketVersioningV2 / PublicAccessBlock
  │         ServerSideEncryptionV2 / OwnershipControls
  │
  └── create_monitoring(instance)  → None
        monitoring.py
        └── SNS Topic / TopicSubscription / Budget / MetricAlarm
```

### Output[T] 型の理解（最重要概念）

Pulumiはリソースを**並列で非同期作成**するため、`instance.id` のような値は作成完了まで確定しない。この「まだ確定していない値」を `Output[T]` 型で表現する。

```
┌─────────────────────────────────────────────────────────┐
│  Output[T] = 「将来解決される値の約束（Promise）」        │
│                                                         │
│  Pulumiエンジン                                          │
│       │                                                 │
│       ├── VPC 作成中 ─────→ vpc.id: Output[str]        │
│       ├── Subnet 作成中 ──→ subnet.id: Output[str]     │
│       └── EC2 作成中 ─────→ instance.id: Output[str]  │
│                                                         │
│  EC2が完成した瞬間、 instance.id が "i-0abc123..." に確定 │
└─────────────────────────────────────────────────────────┘
```

**apply() が必要な場面と不要な場面**

```python
# ─── apply() 不要 ───────────────────────────────────────
# Pulumiリソースのコンストラクタ引数に渡す場合
# → エンジンが依存グラフを自動解決する

aws.cloudwatch.MetricAlarm(
    "cpu-alarm",
    alarm_actions=[topic.arn],  # ← Output[str] をそのまま渡せる
    ...
)

# ─── apply() 必要 ────────────────────────────────────────
# Python の「値」として使いたい場合（dict組み立て、文字列操作等）

# ❌ これは動かない（Output[str] を dict value として使っている）
dimensions = {"InstanceId": instance.id}

# ✅ apply() で str に解決してから dict を構築
dimensions = instance.id.apply(lambda id: {"InstanceId": id})

# ✅ pulumi.Output.concat() で文字列結合
message = pulumi.Output.concat("Instance ID: ", instance.id)
```

### Secretの管理方法

```yaml
# Pulumi.itl-dev.yaml
config:
  aws:region: ap-northeast-1
  # 以下は pulumi config set --secret で暗号化して保存
  # itl-trilogy-lab:notificationEmail: （暗号化済み）
  # itl-trilogy-lab:awsAccountId: （暗号化済み）
```

```python
# config.py — Secretをコードで読み出す
config = pulumi.Config()
NOTIFICATION_EMAIL: pulumi.Output[str] = config.require_secret("notificationEmail")
AWS_ACCOUNT_ID: str = config.require("awsAccountId")
```

Terraform の `terraform.tfvars`（plaintext）と比べて、Pulumiは**state内に暗号化**して保存できる点が優れている。

---

## 8. 3実装の横断比較

### 同一リソースの書き方比較

#### IMDSv2の設定（セキュリティ要件）

```hcl
# Terraform — 最もシンプル
metadata_options {
  http_tokens = "required"
}
```

```typescript
// CDK — L1エスケープハッチが必要（L2が未対応）
const cfnInstance = instance.node.defaultChild as ec2.CfnInstance;
cfnInstance.addPropertyOverride('MetadataOptions.HttpTokens', 'required');
```

```python
# Pulumi — Terraformに近い直接指定
metadata_options=aws.ec2.InstanceMetadataOptionsArgs(
    http_tokens="required",
    http_put_response_hop_limit=1,
)
```

#### タグ管理

```hcl
# Terraform — provider レベルで全リソースへ一括適用
provider "aws" {
  default_tags { tags = local.common_tags }
}
```

```typescript
// CDK — Stack レベルで全 Construct へ伝播
Object.entries(commonTags).forEach(([key, value]) => {
  cdk.Tags.of(this).add(key, value);
});
```

```python
# Pulumi — 各リソースに dict 展開で付与
tags={**COMMON_TAGS, "Name": f"{PREFIX}-vpc"}
```

#### S3の設定（分離 vs 統合）

```hcl
# Terraform — 設定ごとに独立リソース（明示的だが冗長）
resource "aws_s3_bucket" "artifacts" { ... }
resource "aws_s3_bucket_versioning" "artifacts" { ... }
resource "aws_s3_bucket_public_access_block" "artifacts" { ... }
resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" { ... }
resource "aws_s3_bucket_ownership_controls" "artifacts" { ... }
```

```typescript
// CDK L2 — プロパティで一括設定（最も簡潔）
new s3.Bucket(this, 'ArtifactsBucket', {
  versioned: true,
  blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
  encryption: s3.BucketEncryption.S3_MANAGED,
});
```

```python
# Pulumi — Terraform と同じ分離スタイル（BucketV2 + 個別リソース）
aws.s3.BucketV2(...)
aws.s3.BucketVersioningV2(...)
aws.s3.BucketPublicAccessBlock(...)
aws.s3.BucketServerSideEncryptionConfigurationV2(...)
aws.s3.BucketOwnershipControls(...)
```

### コード量とリソース数の比較

| 指標 | Terraform | CDK | Pulumi |
|---|---|---|---|
| 明示的リソース宣言数 | ~22 | ~7 Construct + L1×2 | ~20 |
| 実際に作成されるリソース | 約22 | 約23（cdk synth で確認） | 約20 |
| 「書いたものと作られるものの一致」 | ◎（1:1） | △（隠蔽あり） | ◎（1:1） |
| S3設定の書き方 | 5リソース分離 | 1 Construct統合 | 5リソース分離 |
| IMDSv2設定 | 直接指定 | L1エスケープ必要 | 直接指定 |

### Stateの差異まとめ

| 観点 | Terraform | CDK | Pulumi |
|---|---|---|---|
| drift検出コマンド | `terraform plan` | `cdk diff` | `pulumi preview` |
| State保存先 | S3（自分で準備） | CloudFormation | Pulumi Cloud / S3 |
| Stateロック | DynamoDB | 組み込み | Cloud組み込み |
| リソース識別子 | `resource.name` | CFn論理ID | URN |
| Secret暗号化 | なし | △ | ◎（State内暗号化） |

---

## 9. 設計判断の根拠

### NAT Gatewayを使わない理由

```
NAT Gateway のコスト:
  $0.045/時間 × 730時間/月 ≈ $32.85/月

このラボの月次予算:
  ~$1/月/実装 → NAT Gateway 1台でバジェットの32倍

代替設計:
  EC2にパブリックIPを付与 + SecurityGroupでIngress全禁止
  → SSM Session Managerのみで接続（ポート22不要）
  → コスト: $0（IGW自体は無料）

許容できる理由:
  ・EC2のパブリックIPはIGWへのアウトバウンド疎通用
  ・SGでIngressがゼロのため、インターネットからのアクセスは完全にブロック
  ・本番環境では NAT GW または VPC Endpoint を検討すること
```

### Graviton2 (t4g.nano) を選ぶ理由

```
x86_64 (t3.nano) vs arm64 Graviton2 (t4g.nano)

同等スペック比較（ap-northeast-1, on-demand）:
  t3.nano:  2 vCPU, 0.5 GB RAM → ~$0.0068/時 (~$5.0/月)
  t4g.nano: 2 vCPU, 0.5 GB RAM → ~$0.0052/時 (~$3.8/月)

約 20% コスト削減（同等性能）
Amazon Linux 2023 の arm64 AMI は公式サポート済み
```

### IMDSv2を強制する理由

```
SSRF（Server-Side Request Forgery）攻撃のシナリオ:

IMDSv1（危険）:
  攻撃者 → アプリ（SSRF脆弱性あり） → http://169.254.254.169/latest/meta-data/
                                       → IAM認証情報（AccessKey/SecretKey）取得
  ※ 1ステップで完了してしまう

IMDSv2（安全）:
  1. PUT /latest/api/token でセッショントークン取得（TTL 21600秒）
  2. GET /latest/meta-data/ にトークンを付与してアクセス
  → 単純なSSRFではセッショントークン取得のPUTリクエストが必要
  → IMDSv2に対応したSSRFの構築が大幅に複雑化する

設定方法の比較:
  http_tokens = "required"  → IMDSv2のみ許可
  http_tokens = "optional"  → IMDSv1/v2両方許可（デフォルト、危険）
```

### for_each を count より優先する理由（Terraform）

```
count の問題:
  リソースを count.index（0, 1, 2...）で識別する。
  中間のリソースを削除すると全後続リソースのインデックスがずれ、
  destroy → create が連鎖する（"デスマーチ"）。

for_each の利点:
  リソースをキー（文字列）で識別する。
  中間要素を削除しても他のリソースへの影響がない。

  例: for_each = toset(["subnet-a", "subnet-c"])
  　 "subnet-b" を削除しても "subnet-a" と "subnet-c" は不変
```

---

## 10. セキュリティ設計

### 禁止パターン一覧

| 禁止事項 | 代替手段 | 理由 |
|---|---|---|
| SSHポート(22)のSG許可 | SSM Session Manager | ポート開放なしで接続可能 |
| IAMアクセスキーのハードコード | Instance Profile / OIDC | 漏洩リスクゼロ |
| NAT Gatewayの使用 | IGW + パブリックIP | コスト削減 |
| IMDSv1（optional） | IMDSv2（required） | SSRF経由の認証情報漏洩防止 |
| パブリックS3バケット | PAB全ブロック + BucketOwnerEnforced | 意図しない公開防止 |
| コスト監視なし | Budgets + CloudWatch必須 | コスト暴走防止 |

### IAM設計（最小権限の徹底）

```
EC2 Instance Profile: itl-dev-ec2-profile
  └── IAM Role: itl-dev-ec2-role
        ├── AmazonSSMManagedInstanceCore（AWS管理ポリシー）
        │     ← SSM Session Manager接続に必要な最小権限
        │
        └── インラインポリシー（S3操作）
              Action: s3:GetObject, s3:PutObject,
                      s3:DeleteObject, s3:ListBucket
              Resource: arn:aws:s3:::itl-dev-artifacts-{account_id}
                        arn:aws:s3:::itl-dev-artifacts-{account_id}/*
              ← バケット名を明示してワイルドカード(*)を排除
```

### Security Groupの設計

```
itl-dev-app-sg
  Ingress: なし（全ポート全プロトコルをブロック）
  Egress : 0.0.0.0/0 全許可（アウトバウンドのみ）

なぜIngressがゼロでSSM接続できるか？
  SSM Session Manager は EC2 側から SSM エンドポイントへの
  アウトバウンド接続（ポート443）でトンネルを確立する。
  インバウンド接続が不要なため、Ingress ルールが不要。
```

---

## 11. コスト設計

### 月次コスト見積もり（1実装）

| リソース | 料金 | 備考 |
|---|---|---|
| EC2 t4g.nano（on-demand） | ~$0.68 | 24時間稼働 |
| S3（最小利用） | ~$0.01 | ストレージほぼ0 |
| CloudWatch Alarm | ~$0.10 | アラーム1個 |
| AWS Budgets | $0.00 | 無料枠内 |
| IGW | $0.00 | 利用料のみ（作成は無料） |
| **1実装合計** | **~$0.79/月** | |
| **3実装同時** | **~$2.4/月** | |

**NAT Gateway不使用による節約: $32/月**

### コスト監視の仕組み

```
AWS Budgets: itl-dev-monthly-budget
  予算: $10/月
  通知タイミング:
    ① 実績コストが予算の 80% 超過（$8）
    ② 実績コストが予算の 100% 超過（$10）
  通知先: SNS Topic → Email

CloudWatch Alarm: itl-dev-cpu-alarm
  閾値: CPU使用率 > 80%
  評価期間: 2回連続（5分間隔）= 10分継続して超えたとき
  通知先: SNS Topic → Email
  treatMissingData: notBreaching（データなし時はアラームしない）
```

### 検証後のコスト削減

```bash
# 検証完了後は即 destroy でコスト発生を止める
cd terraform && terraform destroy
cd ../cdk && npx cdk destroy
cd ../pulumi && pulumi destroy

# State バックエンドリソースも手動削除（コスト0）
# S3 バケット: itl-tfstate-{account_id}
# DynamoDB テーブル: itl-tfstate-lock
```

---

## 12. 検証手順

### SSM接続テスト

```bash
# Terraform outputs から接続コマンドを取得
cd terraform
terraform output ssm_connect_command
# → aws ssm start-session --target i-xxxxxxxxxxxxxxxxx --region ap-northeast-1

# 接続後、IMDSv2強制の確認（IMDSv1が403になること）
curl -v http://169.254.169.254/latest/meta-data/
# → 401 Unauthorized が返れば IMDSv2 強制が有効
```

### S3アクセステスト（Instance Profile経由）

```bash
# EC2 インスタンス上で実行
aws s3 cp /tmp/test.txt s3://itl-dev-artifacts-{account_id}/test.txt
aws s3 ls s3://itl-dev-artifacts-{account_id}/
# → AccessDenied が出ずに成功すれば Instance Profile 正常
```

### セキュリティ確認チェックリスト

- [ ] SSM Session Manager でEC2に接続できる
- [ ] `curl http://169.254.169.254/...` が 401 を返す（IMDSv2強制）
- [ ] SGにポート22のIngress Ruleが存在しない
- [ ] EC2からS3バケットにファイルをアップロードできる
- [ ] S3バケットへの外部からの直接アクセスが拒否される
- [ ] AWS Budgets アラートが設定されている
- [ ] CloudWatch Alarm が作成されている

---

## 参照ドキュメント

| ドキュメント | 内容 |
|---|---|
| [infra-spec.md](infra-spec.md) | 3実装共通の「正解定義」（CIDR・インスタンス型・設定値） |
| [docs/comparison-matrix.md](docs/comparison-matrix.md) | 客観的比較 + 主観評価マトリクス |
| [adr/adr-001-terraform-baseline.md](adr/adr-001-terraform-baseline.md) | Terraformの「当たり前」を言語化 |
| [adr/adr-002-cdk-vs-terraform.md](adr/adr-002-cdk-vs-terraform.md) | CDKのL2抽象化の価値と限界 |
| [adr/adr-003-pulumi-vs-hcl.md](adr/adr-003-pulumi-vs-hcl.md) | Output[T]型の理解とPythonの利点欠点 |
| [adr/adr-004-iac-selection-guide.md](adr/adr-004-iac-selection-guide.md) | 3実装比較総括（Takuya記入待ち） |
