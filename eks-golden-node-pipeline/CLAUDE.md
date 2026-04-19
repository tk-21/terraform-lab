# eks-golden-node-pipeline

## プロジェクト概要

Ansible + Packer で CIS Benchmark 適用済みの Golden AMI をビルドし、
Terraform で EKS + Karpenter を構築して Golden AMI を NodeClass に適用する
フルパイプラインプロジェクト。

GitHub Actions (OIDC) で AMI ビルドと Terraform apply を自動化する。

## アーキテクチャ

```
[GitHub Actions]
    │
    ├─ AMI Build Pipeline
    │       │
    │       ├─ Ansible Playbook (CIS Benchmark ハードニング)
    │       └─ Packer → Golden AMI → ap-northeast-1
    │
    └─ Terraform Pipeline
            │
            ├─ VPC (3層: public / private / intra)
            ├─ EKS Cluster (v1.30)
            ├─ Karpenter
            │     └─ NodeClass → Golden AMI 参照
            ├─ IRSA (Karpenter / ALB Controller)
            └─ ALB Ingress Controller
```

## ディレクトリ構造

```
eks-golden-node-pipeline/
├── CLAUDE.md                          # このファイル
├── README.md
├── .github/
│   └── workflows/
│       ├── ami-build.yml              # AMIビルド + Packer
│       └── terraform.yml              # Terraform plan/apply
├── ansible/
│   ├── playbooks/
│   │   └── golden-ami.yml             # メインPlaybook
│   ├── roles/
│   │   ├── cis-benchmark/             # CIS Level1 ハードニング
│   │   │   ├── tasks/main.yml
│   │   │   ├── handlers/main.yml
│   │   │   └── defaults/main.yml
│   │   ├── docker-runtime/            # containerd インストール
│   │   │   └── tasks/main.yml
│   │   └── eks-node-prep/             # EKS ノード事前設定
│   │       └── tasks/main.yml
│   ├── inventory/
│   │   └── packer_hosts               # Packer用インベントリ
│   └── ansible.cfg
├── packer/
│   ├── golden-ami.pkr.hcl             # Packer HCL2テンプレート
│   └── variables.pkrvars.hcl          # 変数定義
├── terraform/
│   ├── environments/
│   │   └── dev/
│   │       ├── main.tf
│   │       ├── variables.tf
│   │       ├── outputs.tf
│   │       └── terraform.tfvars
│   └── modules/
│       ├── vpc/
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   └── outputs.tf
│       ├── eks/
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   └── outputs.tf
│       └── karpenter/
│           ├── main.tf
│           ├── variables.tf
│           ├── outputs.tf
│           └── templates/
│               ├── node-class.yaml    # EC2NodeClass (Golden AMI参照)
│               └── node-pool.yaml     # NodePool
└── docs/
    ├── architecture.md
    └── adr/
        ├── 001-golden-ami-strategy.md
        └── 002-karpenter-vs-managed-nodegroup.md
```

## 命名規則

| リソース | 命名パターン | 例 |
|---|---|---|
| プロジェクト名 | `eks-golden-node-pipeline` | 固定 |
| AMI名 | `golden-ami-eks-{VERSION}-{YYYYMMDD}` | `golden-ami-eks-1.30-20241201` |
| EKS Cluster | `{PROJECT}-{ENV}` | `eks-golden-node-pipeline-dev` |
| VPC | `{PROJECT}-{ENV}-vpc` | `eks-golden-node-pipeline-dev-vpc` |
| Terraform State Key | `{ENV}/terraform.tfstate` | `dev/terraform.tfstate` |
| GitHub Actions Role | `{PROJECT}-github-actions-role` | `eks-golden-node-pipeline-github-actions-role` |

## タグ戦略

全AWSリソースに以下のタグを付与する：

```hcl
tags = {
  Project     = "eks-golden-node-pipeline"
  Environment = var.environment          # dev / stg / prod
  ManagedBy   = "terraform"
  Owner       = "infrastructure-team"
  CostCenter  = "platform"
}
```

Karpenter が管理するノードには追加タグ：

```hcl
"karpenter.sh/discovery" = local.cluster_name
```

## 設計原則・禁止パターン

### 設計原則
- **Immutable AMI**: AMIは一度ビルドしたら変更しない。変更はAMI再ビルドで対応
- **Least Privilege**: Lambda/IRSA のIAMポリシーは最小権限。`*`リソース指定禁止
- **OIDC認証**: GitHub Actions は IAM Access Key を使わない。OIDC のみ
- **arm64優先**: Lambdaはarm64。EKSノードはコスト観点でarm64(Graviton)を優先検討
- **日本語コメント**: 設計意図を説明するコメントは日本語で記述

### 禁止パターン
- `iam:*` や `*:*` の過剰なIAMポリシー
- IAM Access Key のハードコード
- `latest`タグのAMI参照（AMI IDを明示的に指定する）
- Terraform `count` でのリソース管理（`for_each`を使う）
- `terraform destroy` の自動実行（手動確認必須）

## コスト目標

月額 $20〜$40 (dev環境)

| リソース | 想定コスト |
|---|---|
| EKS Control Plane | $0.10/hour → ~$73/月 |
| EC2 (Karpenter) | t3.medium × 1〜2台 → ~$30/月 |
| NAT Gateway | ~$10/月 |
| その他 | ~$5/月 |

**コスト削減策**: dev環境は夜間・週末にノードをゼロスケール

## 使用技術バージョン

| ツール | バージョン |
|---|---|
| Terraform | >= 1.7 |
| Packer | >= 1.10 |
| Ansible | >= 2.15 |
| EKS | 1.30 |
| Karpenter | v0.37.x |
| Python (Lambda) | 3.12 |
| AWS Region | ap-northeast-1 |

## Claude Code 実行手順

```bash
# 各フェーズを順番に実行する
claude < phase1.md   # CLAUDE.md + ディレクトリ骨格
claude < phase2.md   # Ansible Playbook (CIS Benchmark)
claude < phase3.md   # Packer + GitHub Actions AMIビルド
claude < phase4.md   # Terraform VPC / EKS
claude < phase5.md   # Terraform Karpenter + NodeClass
claude < phase6.md   # README + docs + Zenn記事草稿
```