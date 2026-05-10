# chaos-engineering-lab — Claude Code プロジェクトガイド

## プロジェクト概要

AWS FIS (Fault Injection Simulator) を使ったカオスエンジニアリング基盤。
ALB + ASG 構成に CPU ストレス負荷を注入し、Auto Scaling のスケールアウトを自動検証する。

**ポートフォリオ訴求ポイント**: FIS 実験テンプレートの完全 IaC 化（Terraform）

---

## ディレクトリ構造

```
chaos-engineering-lab/
├── CLAUDE.md                          # このファイル（Claude Code 自動ロード）
├── README.md
├── terraform/
│   ├── environments/
│   │   └── dev/
│   │       ├── main.tf                # ルートモジュール呼び出し
│   │       ├── variables.tf
│   │       ├── outputs.tf
│   │       └── terraform.tfvars
│   └── modules/
│       ├── vpc/                       # VPC / サブネット / IGW / NAT
│       ├── sg/                        # セキュリティグループ
│       ├── alb/                       # Application Load Balancer
│       ├── asg/                       # Auto Scaling Group + Launch Template
│       ├── iam/                       # FIS 実行ロール / EC2 インスタンスプロファイル
│       └── fis/                       # FIS 実験テンプレート（CPU ストレス）
├── scripts/
│   ├── run_experiment.sh              # FIS 実験起動 + 結果検証スクリプト
│   └── check_scaling.sh              # ASG スケールアウト確認スクリプト
├── docs/
│   └── adrs/
│       ├── 001-use-fis-over-thirdparty.md
│       └── 002-asg-target-tracking.md
└── runbooks/
    └── cpu-stress-experiment.md
```

---

## 技術スタック・制約

| 項目 | 値 |
|------|-----|
| リージョン | ap-northeast-1 (Tokyo) |
| Terraform バージョン | >= 1.9 |
| AWS プロバイダー | ~> 5.0 |
| EC2 AMI | Amazon Linux 2023 (最新、SSM 対応) |
| インスタンスタイプ | t3.micro (コスト最小) |
| 認証 | OIDC (GitHub Actions) |
| 通知 | Chatwork |

---

## 命名規則

- リソースプレフィックス: `cel` (chaos-engineering-lab)
- 例: `cel-dev-alb`, `cel-dev-asg`, `cel-fis-cpu-stress-role`
- IAM ロール名は 64 文字以内
- タグ必須: `Project = "chaos-engineering-lab"`, `Env = "dev"`, `ManagedBy = "terraform"`

---

## Terraform 実装ルール

1. **モジュール分割**: vpc / sg / alb / asg / iam / fis の 6 モジュール
2. **state 管理**: S3 バックエンド + DynamoDB ロック（`cel-tfstate-<account_id>` バケット）
3. **変数**: すべて `variables.tf` に定義、デフォルト値あり
4. **出力**: 重要リソースの ARN / ID を `outputs.tf` に定義
5. **コメント**: 日本語でコメントを記載（設計意図を説明）
6. **depends_on**: モジュール間依存は明示的に記述

---

## FIS 実験設計

### シナリオ: CPU ストレス → スケールアウト確認

```
FIS 実験開始
  ↓
対象: ASG 内 EC2 インスタンス（50% をランダム選択）
  ↓
アクション: aws:ssm:send-command で stress-ng 実行（CPU 100%、5分間）
  ↓
CloudWatch メトリクス: CPUUtilization > 70% で 2 分間
  ↓
ASG スケールアウト発動（Target Tracking Policy）
  ↓
FIS 停止条件: CPUUtilization > 90% が 10 分継続（安全弁）
```

### FIS リソース構成（fis モジュール）

- `aws_fis_experiment_template`: CPU ストレス実験テンプレート
- `aws_iam_role`: FIS サービスロール（SSM SendCommand / ASG 操作権限）
- `aws_cloudwatch_metric_alarm`: 停止条件用アラーム

---

## ASG / ALB 設計

### ASG (asg モジュール)

- 最小: 2、希望: 2、最大: 6
- ヘルスチェック: ELB（ALB ヘルスチェック連動）
- スケーリングポリシー: Target Tracking（CPU 70%）
- Launch Template: Amazon Linux 2023 + SSM Agent + stress-ng インストール UserData

### ALB (alb モジュール)

- ターゲットグループ: HTTP:80、ヘルスチェック /health
- リスナー: HTTP:80
- Access Logs: S3 バケット（`cel-alb-logs-<account_id>`）

---

## IAM 最小権限設計

### FIS 実行ロール (`cel-fis-execution-role`)
```
ssm:SendCommand        → EC2 への stress-ng 注入
ssm:GetCommandInvocation → 実行状態確認
ec2:DescribeInstances  → 対象インスタンス探索
autoscaling:Describe*  → ASG 状態確認
logs:CreateLogGroup / PutLogEvents → FIS ログ
```

### EC2 インスタンスプロファイル (`cel-ec2-instance-profile`)
```
ssm:UpdateInstanceInformation
ssm:ListAssociations
ssmmessages:*          → SSM セッションマネージャー接続
ec2messages:*          → SSM Agent 通信
cloudwatch:PutMetricData → カスタムメトリクス送信
```

---

## フェーズ実行順序

```
phase1.md → Terraform バックエンド + VPC + SG
phase2.md → ALB + ASG + Launch Template
phase3.md → IAM ロール + FIS 実験テンプレート
phase4.md → 検証スクリプト + ADR + Runbook + README
```

各フェーズは `claude < phaseN.md` で実行。
フェーズ冒頭に前フェーズの成果物サマリーを記載済み。

---

## コスト見積もり（月額）

| リソース | 概算 |
|----------|------|
| EC2 t3.micro × 2 | ~$17 |
| ALB | ~$20 |
| NAT Gateway | ~$35 |
| FIS 実験（従量） | ~$1 |
| **合計** | **~$73** |

> ⚠️ NAT Gateway が最大コスト。検証後は `terraform destroy` 推奨。

---

## ポートフォリオ訴求ポイント（README / Zenn 用）

1. FIS 実験テンプレートを Terraform で完全 IaC 化（再現性・バージョン管理）
2. ASG Target Tracking + FIS 停止条件で安全な実験設計
3. SSM SendCommand 経由の agentless カオス注入（SSH 不要）
4. IAM 最小権限 + 停止条件による安全弁の多層設計