# CLAUDE.md — config-securityhub-auto-remediation

## プロジェクト概要

AWS Config Rules + Security Hub Custom Action を組み合わせたセキュリティコンプライアンス自動修復基盤。
検知から修復・監査ログ記録・CloudWatch監視までをフルサイクルで実装する。

**差別化ポイント**:
- Config Rules → EventBridge → Lambda の自動修復ループ
- Security Hub Custom Action による手動トリガー修復
- S3/IAM/EC2-SG/RDS の4リソース種別をカバー
- 修復結果をDynamoDB記録 + S3監査ログ + CloudWatch Dashboardで可視化

---

## プロジェクト識別子

| 項目 | 値 |
|------|-----|
| プロジェクト名 | config-securityhub-auto-remediation |
| IAMプレフィックス | csar |
| リージョン | ap-northeast-1 |
| Terraform state bucket | csar-tfstate-${AWS_ACCOUNT_ID} |
| 監査ログ bucket | csar-audit-logs-${AWS_ACCOUNT_ID} |
| DynamoDBテーブル | csar-remediation-log |

---

## ディレクトリ構造

```
config-securityhub-auto-remediation/
├── CLAUDE.md
├── README.md
├── terraform/
│   ├── environments/
│   │   └── dev/
│   │       ├── main.tf
│   │       ├── variables.tf
│   │       ├── outputs.tf
│   │       └── backend.tf
│   └── modules/
│       ├── config/              # Config Rules × 4種
│       ├── security_hub/        # Security Hub + Custom Action
│       ├── remediation/         # EventBridge + Lambda + DLQ
│       ├── audit/               # S3監査ログ + DynamoDB
│       ├── dashboard/           # CloudWatch Dashboard
│       └── iam/                 # 最小権限IAMロール群
├── lambda/
│   ├── remediation/
│   │   ├── s3_remediation/
│   │   │   ├── index.py
│   │   │   └── requirements.txt
│   │   ├── iam_remediation/
│   │   │   ├── index.py
│   │   │   └── requirements.txt
│   │   ├── ec2_sg_remediation/
│   │   │   ├── index.py
│   │   │   └── requirements.txt
│   │   └── rds_remediation/
│   │       ├── index.py
│   │       └── requirements.txt
│   └── shared/
│       ├── audit_logger.py      # DynamoDB + S3監査ログ共通モジュール
├── tests/
│   ├── unit/
│   └── integration/
│       ├── create_violation_s3.sh
│   ├── create_violation_sg.sh
│   └── create_violation_iam.sh
├── docs/
│   ├── architecture.md          # Mermaidアーキテクチャ図
│   ├── adr/
│   │   ├── ADR-001-config-vs-guardduty.md
│   │   ├── ADR-002-lambda-vs-ssm-automation.md
│   │   ├── ADR-003-securityhub-integration.md
│   │   └── ADR-004-audit-storage.md
│   └── runbook.md
└── phase1.md ~ phase6.md        # Claude Code実行用フェーズファイル
```

---

## 絶対遵守ルール（禁止事項）

### コスト
- **NAT Gateway 禁止** — VPC Endpoints (Interface/Gateway) のみ使用
- Lambda は arm64 (Graviton2) + `RESERVED_CONCURRENT_EXECUTIONS` 設定必須
- DynamoDB は PAY_PER_REQUEST のみ
- S3監査ログバケットは Intelligent-Tiering + ライフサイクル (90日後 Glacier)

### セキュリティ
- **IAMロール名は64文字以内** (`csar-` プレフィックスで統一)
- **ワイルドカード権限禁止** — `Action: "*"` `Resource: "*"` は一切不可
- **アクセスキー禁止** — GitHub Actions は OIDC のみ
- Lambda環境変数に機密情報を直接記載禁止

### 実装品質
- Python 3.12、Lambda Powertools (logger/tracer/metrics) 必須
- **日本語インラインコメント必須** — 設計意図を日本語で説明すること
- すべてのLambdaにDLQ (SQS) 設定必須
- Lambda タイムアウト: 修復系 300秒、通知系 30秒

### ドキュメント
- **ADR本文はTakuya自身が記述** — AI生成テキストの転用禁止
- ADRテンプレートのみ提供し、`## 決定理由` セクションは空欄で納品
- 口頭説明チェックは各フェーズ末尾に必ず配置

---

## アーキテクチャ概要

```
【自動修復フロー (Config Rules起点)】
Config Rule 違反検知
    → EventBridge Rule (source: aws.config)
    → Lambda 修復関数 (リソース種別ごと)
    → 修復実行 (AWS API Call)
    → DynamoDB 修復ログ記録
    → S3 監査ログ PUT
    → CloudWatch メトリクス記録

【手動修復フロー (Security Hub Custom Action起点)】
Security Hub Finding
    → Custom Action ボタンクリック
    → EventBridge Rule (source: aws.securityhub, custom-action)
    → 同一Lambda修復関数へルーティング
    → 上記と同じ後続処理

【DLQ フロー (修復失敗時)】
Lambda 実行失敗 (3回リトライ後)
    → SQS DLQ
    → EventBridge Pipe or Lambda (DLQ監視)
    → CloudWatch Alarm + DynamoDB FAILED記録
```

---

## 修復対象リソースと修復内容

| リソース | Config Rule | 違反条件 | 自動修復内容 |
|---------|------------|---------|------------|
| S3バケット | s3-bucket-public-read-prohibited | PublicRead ACL | Block Public Access 有効化 |
| S3バケット | s3-bucket-server-side-encryption-enabled | SSE未設定 | AES256 SSE 強制設定 |
| IAMユーザー | iam-user-mfa-enabled | MFA未設定 | コンソールアクセス無効化 + 監査ログ記録 |
| EC2/SG | restricted-ssh | 0.0.0.0/0:22 開放 | 当該インバウンドルール削除 |
| RDS | rds-storage-encrypted | 暗号化なし | スナップショット取得後に監査ログへ手動対応を記録 (インプレース修復不可のため) |
| RDS | rds-instance-public-access-check | PubliclyAccessible=true | PubliclyAccessible=false に変更 |

---

## Terraform 規約

```hcl
# プロバイダーバージョン固定
terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }
}

# タグ必須
locals {
  common_tags = {
    Project     = "config-securityhub-auto-remediation"
    Environment = var.environment
    ManagedBy   = "terraform"
    CostCenter  = "security-automation"
  }
}
```

---

## DynamoDB スキーマ (csar-remediation-log)

```
PK: remediation_id (String) — "csar-rem-{YYYYMMDD}-{uuid8}"
SK: timestamp (String) — ISO8601

Attributes:
  resource_type    String  # S3 / IAM / EC2-SG / RDS
  resource_id      String  # バケット名/ユーザー名/SG-ID/DB識別子
  rule_name        String  # Config Rule名
  violation_detail String  # 違反の詳細JSON
  remediation_action String # 実行した修復内容
  status           String  # SUCCESS / FAILED / MANUAL_REQUIRED
  trigger_source   String  # CONFIG_RULE / SECURITY_HUB_CUSTOM_ACTION
  aws_account_id   String
  region           String
  ttl              Number  # 90日後のエポック秒
```

---

## CloudWatch Dashboard 構成

- **修復実行数** (24h/7d): Lambda Invocations メトリクス
- **修復成功率**: SUCCESS / (SUCCESS + FAILED) %
- **リソース種別別違反件数**: カスタムメトリクス (EMF)
- **DLQ深度**: SQS ApproximateNumberOfMessagesVisible
- **Lambda エラー率**: Errors / Invocations %

---

## Lambda Powertools 設定

```python
from aws_lambda_powertools import Logger, Tracer, Metrics
from aws_lambda_powertools.metrics import MetricUnit

# 各Lambda共通設定
logger = Logger(service="csar-remediation")
tracer = Tracer(service="csar-remediation")
metrics = Metrics(namespace="CSAR", service="remediation")

# カスタムメトリクス名
# csar.remediation.success
# csar.remediation.failed
# csar.remediation.manual_required
```

---

## 口頭説明チェック基準

各フェーズ完了後、以下を見ずに15分説明できること：

1. Config Rulesの評価タイミングと EventBridge への連携方法
2. Security Hub Custom Action の仕組みとConfig Rulesとの違い
3. 各リソース修復の技術的制約（特にRDSが自動修復できない理由）
4. DLQが必要な理由とリトライ設計
5. 監査ログをS3とDynamoDB両方に持つ設計上の理由
