# Architecture: bedrock-agent-resource-reporter

## Overview

Agents for Bedrock を使い、AWSリソースの自律調査・Markdownレポート生成・S3保存・SNS通知を行うエージェント。

```
User Prompt
    │
    ▼
┌─────────────────────────────────────┐
│         Amazon Bedrock Agent         │
│   (Claude 3 Haiku / ap-northeast-1)  │
└──────────────┬──────────────────────┘
               │ Action Groups
       ┌───────┼───────────────┐
       ▼       ▼               ▼
┌──────────┐ ┌─────────────┐ ┌──────────┐
│aws-inspec│ │report-writer│ │notifier  │
│  Lambda  │ │   Lambda    │ │  Lambda  │
└────┬─────┘ └──────┬──────┘ └────┬─────┘
     │              │              │
     ▼              ▼              ▼
  EC2 / CW       S3 (SSE-KMS)   SNS Topic
  Cost Explorer  reports bucket
```

## Modules

### networking
- VPC (10.0.0.0/16)
- Public subnet × 2 AZ / Private subnet × 2 AZ
- NAT Gateway × 1 (コスト最適化)
- VPC Endpoints: bedrock-runtime (Interface), S3 (Gateway)

### lambda-actions
Lambda 3関数 + それぞれの IAM ロール

| 関数 | Action Group | ツール |
|---|---|---|
| bedrock-agent-aws-inspector | aws-inspector | get_cost_and_usage, list_ec2_instances, get_cw_alarms |
| bedrock-agent-report-writer | report-writer | generate_report, save_to_s3, list_past_reports |
| bedrock-agent-notifier | notifier | send_sns_notification |

### bedrock-agent
- Bedrock Agent 本体（Claude 3 Haiku）
- 3つの Action Group（OpenAPI スキーマ定義）
- Agent 実行 IAM ロール

## Data Flow

1. ユーザーが Bedrock Agent に自然言語でプロンプトを送信
2. Agent が意図を解析し、必要な Action Group を順次呼び出す
3. `aws-inspector` Lambda が EC2 / Cost Explorer / CloudWatch を調査
4. `report-writer` Lambda が Markdown レポートを生成し S3 に保存（SSE-KMS）
5. `notifier` Lambda が SNS 経由でメール通知を送信

## Security

- IAM ロール：最小権限（アクセスキー禁止）
- S3 バケット：SSE-KMS 暗号化 + パブリックアクセスブロック + バージョニング
- Lambda → Bedrock Agent 呼び出し許可：`source_arn` で Agent ARN を限定

## Cost Controls

- Lambda メモリ: 256 MB（上限 512 MB）
- NAT Gateway: 1つのみ
- Bedrock モデル: Claude 3 Haiku（最低コスト tier）
- 月額目安: ~$5 (軽量テスト時)
