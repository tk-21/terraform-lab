# CLAUDE.md - terraform-ansible-aws-platform

## プロジェクト概要

Terraform × Ansible × AWS による本格インフラ構築ハンズオン。
3-tier VPC上にALB + EC2 (Nginx + Flask) を構築し、Ansibleで構成管理、GitHub ActionsでCI/CDを実現する。

## ゴール

- ポートフォリオとして公開できる上級レベルの実装
- Terraform / Ansible の連携パターンを実証
- OIDC認証・Session Manager・IMDSv2などセキュリティベストプラクティス適用

---

## ディレクトリ構造

```
terraform-ansible-aws-platform/
├── CLAUDE.md                          # このファイル（プロジェクトメモリ）
├── README.md
├── terraform/
│   ├── environments/
│   │   └── dev/
│   │       ├── main.tf                # rootモジュール呼び出し
│   │       ├── variables.tf
│   │       ├── outputs.tf
│   │       └── terraform.tfvars
│   ├── modules/
│   │   ├── vpc/
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   ├── ec2/
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   ├── alb/
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   └── security_groups/
│   │       ├── main.tf
│   │       ├── variables.tf
│   │       └── outputs.tf
│   └── backend.tf                     # S3 + DynamoDB remote backend
├── ansible/
│   ├── ansible.cfg
│   ├── inventory/
│   │   └── aws_ec2.yml                # Dynamic Inventory (aws_ec2プラグイン)
│   ├── group_vars/
│   │   ├── all.yml
│   │   └── app_servers.yml
│   ├── roles/
│   │   ├── common/                    # OS基本設定 (SELinux, chrony, etc.)
│   │   ├── nginx/                     # Nginxインストール・設定
│   │   └── flask_app/                 # Flaskアプリデプロイ
│   ├── site.yml                       # メインPlaybook
│   └── requirements.yml               # Ansible Galaxy依存
├── app/
│   ├── app.py                         # Flask API本体
│   ├── requirements.txt
│   └── systemd/
│       └── flask-app.service
├── scripts/
│   ├── bootstrap.sh                   # Bastionセットアップ用
│   └── inventory_check.sh
└── .github/
    └── workflows/
        ├── terraform-plan.yml         # PRトリガー
        └── terraform-apply.yml        # mainマージトリガー
```

---

## 命名規則

| リソース種別 | 形式 | 例 |
|-------------|------|----|
| VPC | `{project}-{env}-vpc` | `tap-dev-vpc` |
| Subnet | `{project}-{env}-{tier}-{az}` | `tap-dev-public-1a` |
| EC2 | `{project}-{env}-{role}-{index}` | `tap-dev-app-01` |
| SG | `{project}-{env}-{role}-sg` | `tap-dev-app-sg` |
| ALB | `{project}-{env}-alb` | `tap-dev-alb` |
| IAM Role | `{project}-{env}-{role}-role` | `tap-dev-ec2-role` |

**project略称**: `tap` (Terraform Ansible Platform)

---

## タグ戦略

全リソースに以下のタグを付与（Ansibleのdynamic inventoryフィルタにも使用）:

```hcl
tags = {
  Project     = "terraform-ansible-platform"
  Environment = var.environment          # dev / stg / prod
  ManagedBy   = "terraform"
  Role        = "<リソース役割>"          # app / bastion / alb / etc.
}
```

---

## AWS設定

- **リージョン**: ap-northeast-1 (東京)
- **AZ**: ap-northeast-1a, ap-northeast-1c
- **AMI**: Amazon Linux 2023 (arm64) ※ Graviton3でコスト削減
- **インスタンスタイプ**: t4g.small (App), t4g.micro (Bastion)

### VPC CIDR設計

```
VPC:              10.0.0.0/16
Public  Subnet 1a: 10.0.0.0/24    (Bastion, ALB)
Public  Subnet 1c: 10.0.1.0/24    (ALB)
Private Subnet 1a: 10.0.10.0/24   (App EC2)
Private Subnet 1c: 10.0.11.0/24   (App EC2)
DB      Subnet 1a: 10.0.20.0/24   (将来のDB用、今回は未使用)
DB      Subnet 1c: 10.0.21.0/24   (将来のDB用、今回は未使用)
```

---

## セキュリティ設計方針

- **SSH鍵不要**: Session Manager (SSM) 経由でEC2接続
- **IMDSv2強制**: `http_tokens = "required"` をEC2に設定
- **Bastion**: SSHではなくSSMセッションのみ許可
- **SG最小権限**: App SGはALBからの443/80のみ受け付ける
- **OIDC認証**: GitHub ActionsはIAMアクセスキー不使用

---

## Terraform設計方針

- **モジュール分割**: vpc / ec2 / alb / security_groups
- **Remote Backend**: S3 (バージョニング有効) + DynamoDB (state lock)
- **環境分離**: `environments/dev/` 配下にtfvarsで環境差分を管理
- **output活用**: モジュール間の依存はoutputsで疎結合に保つ

---

## Ansible設計方針

- **Dynamic Inventory**: `aws_ec2`プラグインでTerraformのtagsからホスト自動検出
- **Role構造**: common / nginx / flask_app の3役割に分離
- **冪等性確保**: 全タスクにchanged_when / failed_whenを明示
- **Secrets管理**: ansible-vault で機密情報を暗号化

---

## Flask API仕様

- **エンドポイント**: 
  - `GET /` → ヘルスチェック (200 OK)
  - `GET /api/health` → {"status": "healthy", "host": "<hostname>"}
  - `GET /api/info` → インスタンスメタデータ (IMDSv2経由)
- **起動**: systemdサービスとして管理 (`flask-app.service`)
- **ポート**: 内部5000番 → Nginxがリバースプロキシで80番に公開

---

## コスト試算

| リソース | 月額概算 |
|---------|---------|
| EC2 (t4g.small × 2) | ~$15 |
| EC2 (t4g.micro × 1, Bastion) | ~$4 |
| ALB | ~$18 |
| NAT Gateway | ~$5 |
| S3 + DynamoDB | ~$1 |
| **合計** | **~$43/月** |

> ハンズオン後は `terraform destroy` で即コスト削減。NAT GW不要な場合はVPC Endpointで代替可能。

---

## 禁止パターン

- ❌ IAMアクセスキーをコードにハードコード
- ❌ SG の inbound に `0.0.0.0/0` port 22 を開放
- ❌ EC2 に PublicIP を直接付与してApp公開
- ❌ `terraform apply -auto-approve` を直接本番実行
- ❌ Ansible で `shell` モジュール多用（専用モジュール優先）
- ❌ IMDSv1 の使用（http_tokens = "optional" の設定）

---

## Phase構成

| Phase | 内容 | 推定作業時間 |
|-------|------|------------|
| Phase1 | Terraform: Remote Backend + VPC基盤 | 45分 |
| Phase2 | Terraform: EC2 + ALB + Bastion + IAM | 60分 |
| Phase3 | Ansible: Dynamic Inventory + Role構成 + Flask | 60分 |
| Phase4 | GitHub Actions: OIDC + Plan/Apply分離 | 45分 |
| Phase5 | CloudWatch: Agent + Dashboard + Alarm | 45分 |