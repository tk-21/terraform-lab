# CLAUDE.md - bedrock-multi-agent-ops-autopilot

## プロジェクト概要

Bedrock Multi-Agent Collaborationを使い、AWS運用タスク（障害対応・コスト最適化）を
Supervisor Agentが自律的に判断・委譲・実行するシステム。

## ディレクトリ構造

```
bedrock-multi-agent-ops-autopilot/
├── CLAUDE.md
├── README.md
├── docs/
│   ├── architecture.md        # Mermaidアーキテクチャ図
│   ├── adr/                   # Architecture Decision Records
│   └── runbook.md
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── locals.tf
│   └── modules/
│       ├── foundation/        # VPC, IAM, S3, DynamoDB
│       ├── agents/            # Bedrock Agent定義
│       ├── lambda/            # Action Group Lambda群
│       └── stepfunctions/     # オーケストレーション
├── lambda/
│   ├── incident_investigator/ # CloudWatch/X-Ray/Config調査
│   ├── cost_optimizer/        # Cost Explorer/Trusted Advisor
│   ├── remediation/           # SSM/EC2/Lambda操作
│   └── reporter/              # S3 HTMLレポート + Chatwork通知
├── agents/
│   ├── supervisor/
│   │   ├── instruction.txt    # Supervisor Agent指示
│   │   └── openapi.yaml
│   ├── incident_investigator/
│   │   ├── instruction.txt
│   │   └── openapi.yaml
│   ├── cost_optimizer/
│   │   ├── instruction.txt
│   │   └── openapi.yaml
│   ├── remediation/
│   │   ├── instruction.txt
│   │   └── openapi.yaml
│   └── reporter/
│       ├── instruction.txt
│       └── openapi.yaml
└── tests/
    ├── unit/
    └── integration/
```

## 命名規則

- プレフィックス: `bmao` (bedrock-multi-agent-ops-autopilot)
- リソース例:
  - Lambda: `bmao-incident-investigator`
  - DynamoDB: `bmao-execution-history`
  - S3: `bmao-reports-{account_id}`
  - IAM Role: `bmao-supervisor-agent-role`
  - Step Functions: `bmao-ops-orchestrator`

## Terraformルール

- バージョン: `>= 1.7`
- AWSプロバイダー: `>= 5.0`
- モジュール分割: foundation / agents / lambda / stepfunctions
- ステート: ローカル（S3バックエンドはコメントで提示）
- `common_tags` locals必須:

```hcl
locals {
  common_tags = {
    Project     = "bedrock-multi-agent-ops-autopilot"
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "takuya"
  }
}
```

## Lambdaルール

- ランタイム: `python3.12`
- アーキテクチャ: `arm64`
- フレームワーク: AWS Lambda Powertools（Logger/Tracer/Metrics必須）
- タイムアウト: デフォルト30秒（調査系は300秒）
- 環境変数はSSM Parameter Store経由
- エラーハンドリング: 構造化例外処理、必ずCloudWatch Logsに記録

## Bedrock Agentルール

- Supervisor: `claude-3-7-sonnet-20250219`
- Sub-agents: `claude-3-5-haiku-20241022`（コスト削減）
- Guardrails必須: 破壊的操作（terminate/delete）は人間承認フローへ
- Memory: `ENABLED`（セッション間コンテキスト保持）
- Action Group定義はOpenAPI 3.0 YAML形式

## セキュリティルール

- IAMは最小権限。Lambda実行ロールに不要な権限を付与しない
- Remediation Agentの実行ロールには以下を**明示的に除外**:
  - `iam:*`
  - `organizations:*`
  - `account:*`
- Human-in-the-loop: DynamoDB承認テーブルで実行前確認
- すべてのS3バケットはパブリックアクセスブロック有効

## 通知ルール

- 通知先: **Chatwork**（Slackではない）
- API: `POST https://api.chatwork.com/v2/rooms/{room_id}/messages`
- ヘッダー: `X-ChatWorkToken`
- ボディ: `application/x-www-form-urlencoded` の `body` パラメータ
- room_idはSSM Parameter Storeから取得: `/bmao/chatwork/room_id`

## コストターゲット

- 月額上限: $20
- Bedrock呼び出しはStep Functionsで制御し、無限ループ防止
- Sub-agentはHaiku優先、SupervisorのみSonnet

## ドキュメントルール

- 各モジュールにREADME.md
- 設計上の判断はADRとして `docs/adr/` に記録
- アーキテクチャ図はMermaid形式
- Lambdaコード内のコメントは**日本語**で設計意図を記述

## 禁止パターン

- ハードコードされたAWSアカウントID・クレデンシャル
- `AdministratorAccess` のIAMポリシー付与
- Bedrock AgentへのEC2インスタンス削除権限付与（承認フロー必須）
- `us-east-1` へのリソース作成（`ap-northeast-1` 固定）

## リージョン

`ap-northeast-1`（東京）固定