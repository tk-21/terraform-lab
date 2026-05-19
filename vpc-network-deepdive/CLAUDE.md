# vpc-network-deepdive — CLAUDE.md

## プロジェクト概要

AWSネットワーク設計を実務レベルで体得するためのTerraformハンズオン。
Hub-Spoke VPC構成 + VPC Endpoint（Gateway/Interface）+ カスタムPrivateLinkを段階的に構築し、
「なぜこの設計なのか」を説明できるエンジニアになることがゴール。

## ディレクトリ構成

```
vpc-network-deepdive/
├── CLAUDE.md                  # このファイル（自動ロード）
├── phase1_prompt.md           # Hub VPC + Spoke VPC基盤
├── phase2_prompt.md           # VPC Peering + ルーティング設計
├── phase3_prompt.md           # VPC Endpoint（Gateway型 + Interface型）
├── phase4_prompt.md           # カスタムPrivateLink（NLB経由）
│
├── modules/
│   ├── vpc/                   # VPC・サブネット・IGW汎用モジュール
│   ├── vpc_peering/           # Peeringと双方向ルート汎用モジュール
│   ├── endpoint/              # Gateway/Interface Endpoint汎用モジュール
│   └── privatelink/           # NLB + VPC Endpoint Service汎用モジュール
│
├── envs/
│   ├── hub/                   # Hub VPC環境
│   ├── spoke_prod/            # Spoke-Prod VPC環境
│   └── spoke_dev/             # Spoke-Dev VPC環境
│
├── docs/
│   ├── architecture.md        # アーキテクチャ全体図（Mermaid）
│   ├── adr/                   # Architecture Decision Records
│   │   ├── ADR-001_cidr_design.md
│   │   ├── ADR-002_peering_vs_tgw.md
│   │   ├── ADR-003_endpoint_strategy.md
│   │   └── ADR-004_privatelink_design.md
│   └── runbook.md             # 動作確認手順
│
└── tests/
    └── network_connectivity/  # 疎通確認スクリプト
```

## 命名規則

| リソース種別 | パターン | 例 |
|---|---|---|
| VPC | `vnd-{env}-vpc` | `vnd-hub-vpc`, `vnd-prod-vpc` |
| サブネット | `vnd-{env}-{tier}-subnet-{az}` | `vnd-hub-private-subnet-1a` |
| ルートテーブル | `vnd-{env}-{tier}-rtb` | `vnd-prod-private-rtb` |
| セキュリティグループ | `vnd-{env}-{purpose}-sg` | `vnd-hub-endpoint-sg` |
| VPC Peering | `vnd-{local}-to-{remote}-peering` | `vnd-hub-to-prod-peering` |
| NLB | `vnd-{env}-{purpose}-nlb` | `vnd-hub-shared-nlb` |
| Endpoint | `vnd-{env}-{service}-endpoint` | `vnd-prod-ssm-endpoint` |
| EC2（検証用） | `vnd-{env}-bastion` | `vnd-prod-bastion` |

プレフィックス: **`vnd`**（vpc-network-deepdive）

## CIDR設計

| VPC | CIDR | 用途 |
|---|---|---|
| Hub | `10.0.0.0/16` | 共有サービス・PrivateLink公開元 |
| Spoke-Prod | `10.1.0.0/16` | 本番相当ワークロード |
| Spoke-Dev | `10.2.0.0/16` | 開発相当ワークロード |

### Hub VPC サブネット

| サブネット | CIDR | AZ | 用途 |
|---|---|---|---|
| public-1a | `10.0.0.0/24` | ap-northeast-1a | （将来拡張用・今回は未使用） |
| public-1c | `10.0.1.0/24` | ap-northeast-1c | （将来拡張用・今回は未使用） |
| private-1a | `10.0.10.0/24` | ap-northeast-1a | Endpoint・NLB配置 |
| private-1c | `10.0.11.0/24` | ap-northeast-1c | Endpoint・NLB配置 |

### Spoke-Prod VPC サブネット

| サブネット | CIDR | AZ | 用途 |
|---|---|---|---|
| private-1a | `10.1.10.0/24` | ap-northeast-1a | ワークロード |
| private-1c | `10.1.11.0/24` | ap-northeast-1c | ワークロード |

### Spoke-Dev VPC サブネット

| サブネット | CIDR | AZ | 用途 |
|---|---|---|---|
| private-1a | `10.2.10.0/24` | ap-northeast-1a | ワークロード |
| private-1c | `10.2.11.0/24` | ap-northeast-1c | ワークロード |

## コスト制約（$5/月以内）

### コスト発生リソースと対策

| リソース | 単価 | 対策 |
|---|---|---|
| Interface Endpoint | $0.014/時/AZ | 検証後は `terraform destroy` 徹底 |
| NAT Gateway | $0.062/時 | **使用禁止**（Session Manager経由でSSH不要） |
| EC2（検証用） | t4g.nano $0.0052/時 | 検証時のみ起動、arm64必須 |
| NLB | $0.0243/時 | Phase4のみ、検証後即destroy |

### 禁止パターン

```hcl
# ❌ NAT Gatewayは使用禁止
resource "aws_nat_gateway" "this" { ... }

# ❌ IAMアクセスキーの発行禁止（OIDC or InstanceProfile使用）
resource "aws_iam_access_key" "this" { ... }

# ❌ IMDSv1の許可禁止
metadata_options {
  http_endpoint = "enabled"
  http_tokens   = "optional"  # ← 禁止。requiredにすること
}
```

## コーディング規約

### 全般

- Terraform バージョン: `>= 1.9.0`
- AWS Provider バージョン: `~> 5.0`
- バックエンド: ローカル（学習用途のためS3不要）
- 状態管理: envごとに独立した `terraform.tfstate`

### インラインコメント規約（必須）

```hcl
# ✅ 日本語で「なぜこの設計か」を説明する
resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_hostnames = true  # Interface Endpointの名前解決に必須
  enable_dns_support   = true  # VPC内DNSリゾルバを有効化

  tags = merge(var.tags, { Name = "${var.prefix}-vpc" })
}
```

```hcl
# ❌ 何をしているかだけのコメントは不要
cidr_block = var.cidr_block  # CIDRブロックを設定
```

### モジュール設計原則

- 1モジュール = 1つの関心事（VPC、Peering、Endpointを混在させない）
- `for_each` でマルチAZ対応（`count` は使用禁止）
- すべてのリソースに `tags` 引数を渡す

### outputs設計

- モジュールのoutputsは **他のモジュールが必要とする値を全て出力** する
- VPC ID, Subnet IDs (map), RouteTable IDs (map), SG IDs は必須output

## SSH接続方針

**Session Manager経由のみ許可（SSHポート開放禁止）**

```hcl
# EC2に必要なIAM Managed Policy
"arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

# Inbound SSH (22番ポート) のSGルールは作成しない
```

## 学習チェックポイント

各フェーズ完了後、以下を口頭で説明できることを確認：

- Phase 1: 「なぜHub-Spoke構成にするのか？ TGWとの違いは？」
- Phase 2: 「Peeringのルーティングで対称性が必要な理由は？」
- Phase 3: 「Gateway型とInterface型のEndpointの技術的違いは？」
- Phase 4: 「PrivateLinkでNLBが必要な理由は？ENIとの関係は？」

## タグ戦略

```hcl
locals {
  common_tags = {
    Project     = "vpc-network-deepdive"
    ManagedBy   = "terraform"
    Environment = var.environment  # hub / prod / dev
    CostTarget  = "learning"
  }
}
```