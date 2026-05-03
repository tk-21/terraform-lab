# CLAUDE.md — aws-lsyncd-sync-infra

## プロジェクト概要

Terraform × Ansible × lsyncd による Web コンテンツ自動同期基盤。
master EC2 の `/var/www/html` を slave EC2 × 2 にリアルタイム同期する 1:N 構成。

## ディレクトリ構造

```
aws-lsyncd-sync-infra/
├── CLAUDE.md
├── README.md
├── phase1.md                          # Terraform 構築フェーズ
├── phase2.md                          # Ansible 設定フェーズ
├── phase3.md                          # 動作確認フェーズ
├── docs/
│   ├── adr/001-lsyncd-over-nfs.md
│   └── runbook/operations.md
├── terraform/
│   ├── backend.tf
│   ├── variables.tf
│   ├── vpc.tf
│   ├── security_group.tf
│   ├── key_pair.tf
│   ├── ec2.tf
│   └── outputs.tf
└── ansible/
    ├── ansible.cfg
    ├── inventory/aws_ec2.yml
    ├── group_vars/{all,master,slave}.yml
    ├── roles/
    │   ├── common/tasks/main.yml
    │   ├── nginx/{tasks,templates}/
    │   ├── ssh_key_dist/tasks/main.yml
    │   └── lsyncd/{tasks,handlers,templates}/
    └── playbooks/site.yml
```

## 実行順序

```bash
# Phase 1: Terraform
claude < phase1.md

# Phase 2: Ansible ファイル生成
claude < phase2.md

# Phase 3: 動作確認
claude < phase3.md
```

## 設計原則

- リージョン: ap-northeast-1
- SSH 鍵2種類: ec2_key.pem（運用者用）/ lsyncd_rsa（同期用）
- Dynamic Inventory: Tag: Role でグループ自動分類
- OIDC: GitHub Actions はアクセスキー不使用
- コスト目安: ~$32/月（t3.micro × 3）

## 開発ルール

- **リージョン**: ap-northeast-1（東京）固定
- **EC2 タイプ**: t3.micro（ハンズオン用コスト最小）
- **IAM**: 最小権限原則。GitHub Actions は OIDC（アクセスキー不使用）
- **Terraform state**: S3 + DynamoDB（リモートバックエンド）
- **Ansible**: dynamic inventory（aws_ec2 plugin）で IP ハードコード排除
- **コメント**: 設計意図を日本語で記述する

## 月次コスト見積もり

| リソース | 単価 | 数量 | 月額（概算） |
|---|---|---|---|
| t3.micro EC2 | $0.0136/h | 3台 | ~$30 |
| EBS gp3 8GB | $0.096/GB | 3台 | ~$2.3 |
| S3 (tfstate) | - | 1 | ~$0.01 |
| **合計** | | | **~$32** |

> ハンズオン終了後は `terraform destroy` で全リソース削除すること。
