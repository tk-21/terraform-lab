# CLAUDE.md — istio-eks-service-mesh

## プロジェクト概要

Terraform × Ansible × Istio on EKS を用いたサービスメッシュ基盤の構築ハンズオン。
ポートフォリオ品質を目指し、可観測性・セキュリティ・GitOps を体系的に実装する。

## ディレクトリ構造

```
istio-eks-service-mesh/
├── CLAUDE.md                        # このファイル（Claude Code自動ロード）
├── README.md                        # プロジェクト概要・アーキテクチャ図
├── docs/
│   ├── adr/
│   │   ├── 001-use-istio-over-appmesh.md
│   │   ├── 002-eks-managed-nodegroup.md
│   │   └── 003-s3-html-report.md
│   └── runbook/
│       ├── deploy.md
│       └── troubleshoot.md
├── terraform/
│   ├── backend.tf                   # S3 + DynamoDB リモートステート
│   ├── versions.tf                  # provider バージョン固定
│   ├── variables.tf
│   ├── outputs.tf
│   ├── main.tf                      # module 呼び出し
│   └── modules/
│       ├── vpc/
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   └── outputs.tf
│       ├── eks/
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   └── outputs.tf
│       ├── iam/
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   └── outputs.tf
│       └── s3/
│           ├── main.tf
│           ├── variables.tf
│           └── outputs.tf
├── ansible/
│   ├── ansible.cfg
│   ├── inventory/
│   │   └── aws_ec2.yaml             # dynamic inventory (aws_ec2 plugin)
│   ├── group_vars/
│   │   └── all.yaml
│   ├── roles/
│   │   ├── os_hardening/            # CIS Benchmark準拠 OS hardening
│   │   │   ├── tasks/main.yaml
│   │   │   ├── handlers/main.yaml
│   │   │   └── defaults/main.yaml
│   │   └── istio_install/           # Istioctl によるIstioインストール
│   │       ├── tasks/main.yaml
│   │       └── defaults/main.yaml
│   └── playbooks/
│       ├── hardening.yaml
│       └── istio_setup.yaml
├── k8s/
│   ├── namespaces/
│   │   └── mesh-apps.yaml
│   ├── apps/
│   │   ├── frontend/
│   │   │   ├── deployment.yaml
│   │   │   └── service.yaml
│   │   ├── backend/
│   │   │   ├── deployment.yaml
│   │   │   └── service.yaml
│   │   └── database-stub/
│   │       ├── deployment.yaml
│   │       └── service.yaml
│   └── istio/
│       ├── gateway.yaml
│       ├── virtual-service.yaml
│       ├── destination-rule.yaml
│       ├── peer-authentication.yaml  # mTLS STRICT
│       └── traffic-policy/
│           ├── canary.yaml           # カナリアリリース設定
│           └── circuit-breaker.yaml  # サーキットブレーカー設定
└── scripts/
    ├── bootstrap.sh                  # Terraformバックエンド初期化
    ├── generate_report.py            # S3 HTML観測レポート生成
    └── cleanup.sh                    # リソース全削除
```

## 実装ルール（必ず遵守）

### Terraform
- `required_providers` でバージョン固定（`~>` 演算子使用）
- リモートステートは S3 + DynamoDB（`terraform/backend.tf`）
- GitHub Actions OIDC 認証（アクセスキー禁止）
- タグ必須: `Project`, `Env`, `ManagedBy = "terraform"`, `Owner`
- モジュール間の参照は `outputs.tf` 経由のみ
- `terraform fmt` と `terraform validate` を常に通す
- コメントは日本語で設計意図を記述

### Ansible
- `ansible.cfg` で `host_key_checking = False`, `retry_files_enabled = False`
- Dynamic Inventory (`aws_ec2` plugin) を使用、静的 hosts ファイル禁止
- 全タスクに `name:` を日本語で記述
- `become: true` が必要なタスクのみ sudo 昇格
- Idempotent であること（何度実行しても同じ結果）
- OS hardening は CIS Amazon Linux 2023 Benchmark Level 1 準拠

### Kubernetes / Istio
- Namespace `mesh-apps` に `istio-injection: enabled` ラベル付与
- mTLS は `STRICT` モード（Permissive は開発初期のみ）
- PeerAuthentication と DestinationRule をペアで管理
- リソースに `app` と `version` ラベル必須（Kiali 可視化のため）

### セキュリティ原則
- IAM ロールは最小権限（`*` リソース禁止）
- セキュリティグループはポート・CIDR を最小化
- EKS API エンドポイントは Private + Public（CIDRホワイトリスト）
- Secrets は AWS Secrets Manager 経由（平文禁止）

### コスト最適化（目標 ~$30/月）
- EKS ワーカーノード: `t3.medium` × 2（Spot 推奨）
- EKS コントロールプレーン: $0.10/時間 → 不使用時は削除
- NAT Gateway: 1 AZ のみ（HA不要なハンズオン環境）
- S3 レポートバケット: ライフサイクル 30日で自動削除

### ポートフォリオ品質マーカー
- `docs/adr/` に設計判断を記録（ADR形式）
- `docs/runbook/` に運用手順を記載
- README にアーキテクチャ図（Mermaid）を含める
- 全 Lambda / スクリプトに日本語コメントで設計意図を説明

## フェーズ実行順序

```bash
# Phase 1: AWS基盤構築
claude < phase1.md

# Phase 2: OS hardening + Istio インストール
claude < phase2.md

# Phase 3: アプリデプロイ・トラフィック制御・観測レポート
claude < phase3.md
```

## 環境変数（実行前に設定）

```bash
export AWS_PROFILE=your-profile
export TF_VAR_project_name="istio-eks-service-mesh"
export TF_VAR_env="dev"
export TF_VAR_aws_region="ap-northeast-1"
```

## 月額コスト見積もり

| リソース | スペック | 月額 |
|---|---|---|
| EKS コントロールプレーン | - | ~$7.2 |
| EC2 ワーカーノード | t3.medium × 2 (Spot) | ~$10 |
| NAT Gateway | 1 AZ | ~$5 |
| S3 | レポートバケット | ~$1 |
| データ転送 | - | ~$2 |
| **合計** | | **~$25** |