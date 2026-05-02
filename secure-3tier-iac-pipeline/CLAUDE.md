# CLAUDE.md — secure-3tier-iac-pipeline

## プロジェクト概要
AWS + Terraform + Ansible を使ったフルスタック本番級インフラ構築ハンズオン。
セキュアな3層Webアプリ基盤（ALB → EC2 Auto Scaling → RDS Aurora）を完全自動構築する。

## ゴール
- Terraform で本番グレードのネットワーク・コンピュート・データ層を構築
- Ansible で OS強化・アプリデプロイ・設定ドリフト自動検出を実装
- 上級セキュリティパターン（IMDSv2, SSM Session Manager, Secrets Manager, Ansible Vault）を適用
- Claude Code のフェーズ分割実行パターンで実装（claude < phaseN.md）

## ディレクトリ構造
```
secure-3tier-iac-pipeline/
├── CLAUDE.md
├── terraform/
│   ├── envs/
│   │   └── prod/
│   │       ├── main.tf
│   │       ├── variables.tf
│   │       ├── outputs.tf
│   │       └── terraform.tfvars
│   └── modules/
│       ├── network/          # VPC, Subnet, IGW, NAT, NACL
│       ├── compute/          # EC2 ASG, ALB, Launch Template
│       ├── database/         # RDS Aurora MySQL Serverless v2
│       ├── security/         # SG, IAM Role, Instance Profile
│       ├── secrets/          # Secrets Manager, KMS
│       └── ssm/              # SSM Parameter Store, Session Manager policy
├── ansible/
│   ├── inventories/
│   │   └── aws_ec2.yml       # 動的インベントリ (aws_ec2 plugin)
│   ├── group_vars/
│   │   ├── all/
│   │   │   ├── vars.yml
│   │   │   └── vault.yml     # Ansible Vault 暗号化
│   │   └── webservers/
│   │       └── vars.yml
│   ├── roles/
│   │   ├── os_hardening/     # CIS Benchmark Level 1 準拠
│   │   ├── app_deploy/       # アプリデプロイ・設定
│   │   └── drift_detection/  # 設定ドリフト検出・レポート
│   ├── site.yml
│   ├── hardening.yml
│   └── drift_check.yml
└── scripts/
    ├── bootstrap.sh          # tfstate バックエンド初期化
    └── run_ansible.sh        # SSM Session Manager 経由実行
```

## 命名規則
- プレフィックス: `s3t-prod-` (aws-terraform-ansible の略)
- リソース名: `s3t-prod-{role}-{type}` (例: `s3t-prod-web-sg`, `s3t-prod-db-subnet-group`)
- Terraform モジュール: スネークケース
- Ansible ロール: スネークケース
- タグ必須: `Project`, `Environment`, `ManagedBy`, `Owner`

## 禁止パターン
- `0.0.0.0/0` を SG インバウンドに設定（ALB SG のポート80/443のみ例外）
- IMDSv1 の使用（必ず `http_tokens = "required"` を指定）
- ハードコードされた AWS クレデンシャル
- パブリックサブネットへの EC2 直接配置
- SSH ポート(22)の SG 開放（SSM Session Manager を使用）
- `iam:*` の広範な IAM 権限付与
- Ansible Vault なしでのシークレット記載

## Terraform 規約
- バージョン: Terraform >= 1.7, AWS Provider >= 5.40
- リージョン: `ap-northeast-1`
- tfstate: S3 バックエンド + DynamoDB ロック（必須）
- `common_tags` locals を全モジュールで使用
- `lifecycle { prevent_destroy = true }` をステートフルリソースに適用
- `moved` ブロックを使ったリファクタリング対応

## Ansible 規約
- Python: 3.x
- 動的インベントリ: `amazon.aws.aws_ec2` プラグイン（タグベースフィルタリング）
- SSM 接続: `ansible_connection: aws_ssm`（SSH不使用）
- シークレット: Ansible Vault (`ansible-vault encrypt_string`)
- 冪等性: 全タスクで `changed_when`, `failed_when` を明示
- ハンドラー: サービス再起動は必ず `notify` + `handlers` で実装

## 上級ポイント（各フェーズで実装）
1. **IMDSv2 強制**: Launch Template で `http_tokens = "required"`, `http_put_response_hop_limit = 1`
2. **SSM Session Manager**: 22番ポート不要、IAM 権限で制御、セッションログをS3に記録
3. **Secrets Manager ローテーション**: RDS パスワードの自動ローテーション Lambda
4. **Ansible 動的インベントリ**: EC2 タグ `Role=webserver` でグループ自動形成
5. **設定ドリフト検出**: Ansible の `--check` モードで差分をレポート化、EventBridge でスケジュール実行
6. **KMS カスタマーキー**: EBS・RDS・S3・Secrets Manager を同一 CMK で暗号化

## コメント規約
```hcl
# [設計意図] なぜこの設定にしたかを日本語で記載
# [セキュリティ] セキュリティ上の理由がある場合
# [コスト] コスト最適化の観点がある場合
# [注意] 変更時に影響が出る可能性がある箇所
```

## フェーズ構成
- Phase 1: tfstate バックエンド + ネットワーク基盤 (VPC/Subnet/IGW/NAT/NACL)
- Phase 2: セキュリティ層 (IAM/SG/KMS/Secrets Manager) + コンピュート層 (ALB/ASG/Launch Template)
- Phase 3: データ層 (RDS Aurora) + SSM設定 + Terraform仕上げ
- Phase 4: Ansible 全実装 (動的インベントリ/OS強化/アプリデプロイ/ドリフト検出)