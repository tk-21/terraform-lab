# aws-multilayer-firewall-terraform — CLAUDE.md

## プロジェクト概要

AWS ネットワークセキュリティを実践的に学ぶ Terraform ハンズオン。
NACL / Security Group / WAF / AWS Network Firewall を段階的に構築し、
実際の通信制御・ブロック動作を確認することで設計判断の根拠を身体化する。

---

## ディレクトリ構成

```
aws-multilayer-firewall-terraform/
├── CLAUDE.md                  # このファイル（自動ロード）
├── phases/
│   ├── phase1_vpc_sg_nacl.md
│   ├── phase2_network_firewall.md
│   ├── phase3_waf.md
│   └── phase4_validation_and_docs.md
├── terraform/
│   ├── modules/
│   │   ├── vpc/
│   │   ├── security_group/
│   │   ├── nacl/
│   │   ├── network_firewall/
│   │   └── waf/
│   ├── environments/
│   │   └── dev/
│   │       ├── main.tf
│   │       ├── variables.tf
│   │       ├── outputs.tf
│   │       └── terraform.tfvars
│   └── backend.tf
├── scripts/
│   ├── test_connectivity.sh   # 疎通確認スクリプト
│   └── attack_simulation.sh   # 模擬攻撃スクリプト（curl）
├── docs/
│   ├── architecture.md
│   ├── adr/
│   │   ├── 001_nacl_vs_sg.md
│   │   ├── 002_network_firewall_placement.md
│   │   └── 003_waf_rule_strategy.md
│   └── runbook.md
└── README.md
```

---

## 命名規則

| リソース種別 | 命名パターン | 例 |
|---|---|---|
| VPC | `{prefix}-vpc` | `amf-vpc` |
| Subnet | `{prefix}-{tier}-{az}` | `amf-public-1a` |
| Security Group | `{prefix}-sg-{role}` | `amf-sg-web` |
| NACL | `{prefix}-nacl-{tier}` | `amf-nacl-public` |
| Network Firewall | `{prefix}-nfw` | `amf-nfw` |
| WAF WebACL | `{prefix}-waf-{scope}` | `amf-waf-alb` |
| IAM Role | `{prefix}-role-{service}` | `amf-role-lambda` |

**プレフィックス**: `amf`（aws-multilayer-firewall-terraform の略）

---

## Terraform 規約

### 必須事項
- **プロバイダー**: `aws` プロバイダー、リージョン `ap-northeast-1`
- **バックエンド**: S3 + DynamoDB（`backend.tf` に記載）
- **Terraform バージョン**: `>= 1.7`
- **AWS プロバイダーバージョン**: `~> 5.0`

### コーディングスタイル
- 全リソースに `# 設計理由:` コメントを必須で記載（"何を" ではなく "なぜ"）
- タグは全リソースに統一して付与（`local.common_tags` を使用）
- `count` より `for_each` を優先
- ハードコード禁止：CIDRや設定値は `variables.tf` に定義

### 必須タグ
```hcl
locals {
  common_tags = {
    Project     = "aws-multilayer-firewall-terraform"
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "takuya"
  }
}
```

---

## CIDR 設計

```
VPC:              10.0.0.0/16
Public Subnet:    10.0.0.0/24  (AZ: ap-northeast-1a)
                  10.0.1.0/24  (AZ: ap-northeast-1c)
Private Subnet:   10.0.10.0/24 (AZ: ap-northeast-1a)
                  10.0.11.0/24 (AZ: ap-northeast-1c)
Firewall Subnet:  10.0.100.0/28 (AZ: ap-northeast-1a)
                  10.0.101.0/28 (AZ: ap-northeast-1c)
```

---

## セキュリティ設計原則

- **最小権限**: IAM ポリシーは必要最小限のアクションのみ許可
- **IMDSv2 強制**: 全 EC2 インスタンスで `http_tokens = "required"`
- **SSH レス**: Session Manager 経由のみ。22番ポートは一切開放しない
- **暗号化**: S3 / CloudWatch Logs は全て暗号化有効
- **フロー ログ**: VPC Flow Logs を CloudWatch Logs へ出力（セキュリティ検証用）

---

## コスト制約

- **月額目標**: $5〜$15
- **コスト注意リソース**:
  - Network Firewall Endpoint: ~$0.395/時間/AZ → **1AZ のみ**でハンズオン実施
  - NAT Gateway: ~$0.062/時間 → 検証後は `terraform destroy`
  - ALB: 不要な場合は EC2 直接で代替
- **節約パターン**: `t4g.nano`（arm64/Graviton）を EC2 に使用

---

## 禁止パターン

```
❌ セキュリティグループに 0.0.0.0/0 の ingress（SSH/RDP）
❌ IAM ポリシーに Action: "*" または Resource: "*"
❌ アクセスキー（IAM User Key）の使用 → OIDC or Instance Profile を使用
❌ IMDSv1 の使用
❌ terraform apply を -auto-approve で実行（学習目的のため必ず差分確認）
❌ WAF のマネージドルールを全て有効化（コスト爆発防止）
```

---

## フェーズ実行順序

```bash
# Phase 1: VPC + SG + NACL
claude < phases/phase1.md

# Phase 2: Network Firewall
claude < phases/phase2.md

# Phase 3: WAF
claude < phases/phase3.md

# Phase 4: 動作検証 + ドキュメント整備
claude < phases/phase4.md
```

---

## 学習チェックポイント（各フェーズ完了後に自問）

1. **SG vs NACL の違いを15分説明できるか？**
   - ステートフル vs ステートレスの具体的な挙動
   - どちらをどのユースケースで使うべきか

2. **Network Firewall の配置場所を設計できるか？**
   - Firewall Subnet が必要な理由
   - ルートテーブルの Traffic Mirroring パターン

3. **WAF ルールの優先度設計を説明できるか？**
   - Allow/Block/Count のアクション使い分け
   - レートベースルールの閾値根拠