# tf-ansible-nginx-pipeline

## プロジェクト概要

**目的**: 「動けばいい」から「なぜこう設計するか説明できる」レベルへの昇格
**テーマ**: Terraform provisioning → Ansible configuration の完全統合パイプライン
**重点**: 設計思想の言語化 × テスト・検証方法論

## ディレクトリ構成

```
tf-ansible-nginx-pipeline/
├── CLAUDE.md                    # このファイル（Claude Code自動読み込み）
├── phases/
│   ├── phase1.md               # 設計思想の言語化
│   ├── phase2.md               # Terraformモジュール設計
│   ├── phase3.md               # Ansible Role設計
│   ├── phase4.md               # 統合パイプライン
│   └── phase5.md               # テスト・検証方法論
├── docs/
│   └── adr/
│       └── ADR-001-template.md # Architecture Decision Record テンプレート
├── terraform/
│   ├── environments/
│   │   └── dev/
│   │       ├── main.tf
│   │       ├── variables.tf
│   │       ├── outputs.tf
│   │       └── terraform.tfvars
│   └── modules/
│       ├── vpc/
│       ├── compute/
│       └── ssm/
├── ansible/
│   ├── inventory/
│   │   └── aws_ec2.yml         # Dynamic Inventory設定
│   ├── roles/
│   │   └── nginx/
│   │       ├── tasks/
│   │       ├── handlers/
│   │       ├── defaults/
│   │       ├── templates/
│   │       └── molecule/
│   └── site.yml
├── tests/
│   ├── terratest/
│   │   └── vpc_test.go
│   └── inspec/
│       └── controls/
└── .github/
    └── workflows/
        ├── terraform.yml
        └── ansible.yml
```

## Claude Codeへの実行指示

### フェーズ実行方法
```bash
# 各フェーズを順番に実行する
claude < phases/phase1.md
claude < phases/phase2.md
claude < phases/phase3.md
claude < phases/phase4.md
claude < phases/phase5.md
```

### 前提条件
- AWS CLI設定済み（ap-northeast-1）
- Terraform >= 1.7
- Ansible >= 2.15
- Go >= 1.21（Terratest用）
- Docker（Molecule用）

## 設計原則（全フェーズ共通）

1. **OIDC over アクセスキー**: GitHub ActionsはOIDCで認証、静的キーは使わない
2. **SSM Session Manager over SSH**: SSHキー管理を廃止する
3. **最小権限IAM**: LambdaもGitHub ActionsもIAMロールは最小権限
4. **冪等性の証明**: 2回実行しても結果が変わらないことをテストで担保
5. **日本語コメント**: 設計意図を日本語で残す（なぜそう書いたかを説明）

## AWS設定

- **リージョン**: ap-northeast-1（東京）
- **tfstate**: S3 + DynamoDBロック
- **命名規則**: `{project}-{env}-{resource}` (例: `handson-dev-vpc`)
- **月額目標**: $10以下（ハンズオン完了後はterraform destroyで全削除）