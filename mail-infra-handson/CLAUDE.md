# mail-infra-handson - Claude Code 作業ガイド

## プロジェクト概要

メール送受信の仕組み（プロトコル・MTA・認証・セキュリティ）をAWS×Terraformで体系的に理解するハンズオン。
フェーズ1〜5の学習を経て完成したモジュール構成で、本番運用レベルのメールインフラを一括デプロイできる。

## ディレクトリ構造

```
mail-infra-handson/
├── CLAUDE.md                    # このファイル（Claude Code自動ロード）
├── README.md                    # プロジェクト概要
├── phases/                      # フェーズ別学習プロンプト（参照用）
│   ├── phase1.md                # Phase 1: 理論 × DNS基盤構築
│   ├── phase2.md                # Phase 2: MTA構築（Postfix on EC2）
│   ├── phase3.md                # Phase 3: AWS SES本格構成
│   ├── phase4.md                # Phase 4: DKIM/DMARC完全実装
│   └── phase5.md                # Phase 5: セキュリティ強化×運用監視
├── terraform/                   # Terraform ルート（単一stateで全リソース管理）
│   ├── main.tf                  # 全モジュールを呼び出すエントリポイント
│   ├── variables.tf             # ルート変数（domain_name, admin_email 等）
│   ├── outputs.tf               # ルート出力（name_servers, bucket_name 等）
│   ├── versions.tf              # プロバイダーバージョン制約
│   ├── terraform.tfvars.example # tfvarsサンプル
│   └── modules/                 # 機能別モジュール（8つ）
│       ├── dns/                 # Route53 Hosted Zone + MX/SPF/DMARC レコード
│       ├── ses-identity/        # SES Email Identity + DKIM CNAME x3
│       ├── ses-config/          # Configuration Set + イベント通知先設定
│       ├── bounce-pipeline/     # SNS + DynamoDB サプレッションリスト + bounce_handler Lambda
│       ├── inbound-pipeline/    # S3 + spam_log DynamoDB + spam_handler Lambda + Receipt Rules
│       ├── suppression-sync/    # suppression_manager Lambda + EventBridge 日次スケジュール
│       ├── monitoring/          # CloudWatch アラーム + ダッシュボード + SNS通知
│       └── vpc-endpoint/        # SES SMTP 用 VPC Interface Endpoint
├── docs/
│   ├── architecture.md          # アーキテクチャ解説（全体フロー図）
│   ├── protocol-cheatsheet.md   # SMTPコマンド・プロトコル早見表
│   ├── troubleshooting.md       # よくあるトラブルと対処法
│   ├── dmarc-migration-guide.md # DMARC段階的移行ガイド（none→quarantine→reject）
│   └── production-checklist.md  # 本番運用前チェックリスト
└── scripts/
    ├── smtp-test.sh             # telnetでSMTP手動テスト
    ├── send-test-mail.py        # Python経由でSES送信テスト
    ├── check-dns.sh             # DNS設定確認スクリプト
    ├── check-dmarc.sh           # DMARCレコード確認スクリプト
    ├── analyze-mail-header.py   # メールヘッダー解析ツール
    ├── postfix-user-data.sh     # EC2起動時Postfixセットアップ（参照用）
    └── ses-setup.sh             # SES SMTP認証情報セットアップ
```

## 共通設定

```hcl
# デフォルト値
region     = "ap-northeast-1"  # 東京リージョン固定
```

## Terraform共通ルール

- **構成**: 単一ルート（`terraform/`）で全8モジュールを管理、stateファイルは1つ
- **命名規則**: `mail-handson-{resource}` 形式（フェーズ番号なし）
- **タグ必須**:
  ```hcl
  tags = {
    Project   = "mail-infra-handson"
    ManagedBy = "terraform"
  }
  ```
  各モジュール内で `Module = "<module-name>"` が自動付与される
- **IAM命名**: 64文字以内厳守
- **arm64優先**: Lambdaは `architectures = ["arm64"]` + Python 3.12
- **OIDC認証**: GitHub Actions連携時はアクセスキー不使用

## コードコメントルール

- 日本語でコメントを記載し、設計の意図まで説明する
- 例:
  ```hcl
  # MXレコード: メール受信時の宛先MTAを指定するDNSレコード
  # 優先度(priority)が低いほど優先して使われる（10が20より優先）
  resource "aws_route53_record" "mx" {
  ```

## モジュール間の依存関係

```
dns（Route53 Hosted Zone）
    ↓ hosted_zone_id
ses-identity（SES Email Identity + DKIM）
    ↓ identity_arn, dkim_tokens → dns モジュールで CNAME 登録
ses-config（Configuration Set）
    ↓ configuration_set_name
bounce-pipeline（SNS + DynamoDB + bounce_handler Lambda）
    ↓ suppression_table_arn, suppression_table_name, bounce_handler_function_name
    ├── inbound-pipeline（S3 + spam_handler + Receipt Rules）
    ├── suppression-sync（日次同期 Lambda）
    └── monitoring（CloudWatch ダッシュボード）
vpc-endpoint（VPC Interface Endpoint）
    ↓ endpoint_id（独立モジュール）
```

## Terraform操作

```bash
cd terraform
terraform init
terraform plan -var-file="terraform.tfvars"

# 以下はユーザーが自分で実行する
terraform apply -var-file="terraform.tfvars"
terraform destroy -var-file="terraform.tfvars"
```

## 費用の目安

| リソース区分 | 主なサービス | 概算費用 |
|------------|------------|---------|
| DNS | Route53ホストゾーン + ドメイン | $1.5/月 |
| メール送受信 | SES + S3 + Lambda | $1/月 |
| 監視 | CloudWatch + SNS | $1/月 |
| ネットワーク | VPC Endpoint（使用時のみ） | $0〜$2/月 |
| **合計** | | **〜$4/月** |

## 学習の流れ

1. `phases/phase*.md` の理論解説セクションを読む
2. `terraform/modules/` の対応モジュールコードを確認する
3. `terraform apply` で実際にリソースを作成する
4. `scripts/` の検証スクリプトで動作確認する
5. `docs/` のドキュメントで設計意図を深掘りする