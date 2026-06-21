# CLAUDE.md — pr-driven-iac-lab

## プロジェクト概要

GitHub Actions + Atlantis（Self-hosted on ECS Fargate）および Terraform Cloud の両方を実装し、
PR-driven IaC ワークフロー（PR open → plan コメント → merge → apply）を比較体験するハンズオンラボ。

面接で「チームIaCワークフローの設計・運用経験」を語れるポートフォリオを構築する。

## ディレクトリ構成

```
pr-driven-iac-lab/
├── CLAUDE.md                  # このファイル（Claude Code自動読み込み）
├── phase1.md                  # インフラ基盤 + Terraformサンプルコード
├── phase2.md                  # Atlantis on ECS Fargate 構築
├── phase3.md                  # Atlantis GitHub Actions ワークフロー
├── phase4.md                  # Terraform Cloud ワークフロー実装
├── phase5.md                  # 比較・観察・ADR・面接準備
│
├── terraform/
│   ├── bootstrap/             # Terraform状態管理用S3+DynamoDB（手動apply）
│   ├── sample-infra/          # AtlantisとTFCが管理するサンプルインフラ
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── backend.tf
│   └── atlantis-infra/        # Atlantis本体のECS Fargate環境
│       ├── main.tf
│       ├── ecs.tf
│       ├── alb.tf
│       ├── iam.tf
│       ├── variables.tf
│       └── backend.tf
│
├── .github/
│   └── workflows/
│       ├── atlantis-trigger.yml    # Atlantis webhook確認用（オプション）
│       └── tfc-pr-workflow.yml     # TFC PR-driven ワークフロー
│
├── atlantis.yaml              # Atlantisプロジェクト定義
├── docs/
│   ├── adr/
│   │   ├── ADR-001-atlantis-vs-tfc.md
│   │   └── ADR-002-atlantis-on-ecs.md
│   ├── architecture.md
│   └── runbook.md
└── interview/
    └── star-answers.md
```

## アーキテクチャ設計原則（全フェーズ共通）

### コスト最適化（必須）
- NAT Gateway 禁止 → VPC Endpoints のみ使用
- Atlantis ECS: FARGATE_SPOT + arm64/Graviton2
- サンプルインフラ: S3（PAY_PER_REQUEST）、IAM（コストなし）
- DynamoDB: PAY_PER_REQUEST（Terraform state lock用）
- ラボ終了後は必ず `terraform destroy` を実行すること

### Terraform規約
- `for_each` を `count` より優先
- ハードコードされたシークレット禁止 → SSM Parameter Store
- IAM wildcard 禁止
- IAM ロール名は64文字以内
- GitHub Actions OIDC認証（アクセスキー禁止）
- 日本語インラインコメントで設計意図（「なぜ」）を記述

### Lambda/コンピュート規約
- Python 3.12 + Lambda Powertools
- arm64/Graviton2 をデフォルト

### 通知
- Chatwork REST API（`POST /v2/rooms/{room_id}/messages`）
- ヘッダー: `X-ChatWorkToken`、エンコード: `application/x-www-form-urlencoded`

## 各フェーズの実行方法

```bash
# フェーズ順に実行
claude < phase1.md
claude < phase2.md
claude < phase3.md
claude < phase4.md
claude < phase5.md
```

## 口頭説明チェックポイント（各フェーズ末）

各フェーズ完了後、以下を15分間ノートなしで説明できること：
- このフェーズで構築したものの全体像
- 設計判断の理由（なぜこのアーキテクチャか）
- AtlantisとTFCの違いと選択基準

## ADR記入ルール

`docs/adr/` 内の `## Decision` セクションは **必ずTakuya本人が記述**。
AI生成禁止。面接準備材料として機能させるため。

## ラボの学習目標

1. PR-driven IaCの全フロー（webhook → plan → approve → apply）を手で動かす
2. Atlantis（Self-hosted）とTFC（SaaS）のトレードオフを体感する
3. 「チームIaCワークフロー設計経験」を面接で15分話せる状態にする