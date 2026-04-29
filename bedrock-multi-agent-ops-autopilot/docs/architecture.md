# アーキテクチャ概要

## システム構成図

```mermaid
graph TB
    subgraph "トリガー層"
        EB[EventBridge<br/>障害/コスト異常イベント]
    end

    subgraph "オーケストレーション層"
        SF[Step Functions<br/>bmao-ops-orchestrator]
        SA[Supervisor Agent<br/>Claude 3.7 Sonnet]
    end

    subgraph "Sub-Agent層"
        IA[Incident Investigator Agent<br/>Claude 3.5 Haiku]
        CA[Cost Optimizer Agent<br/>Claude 3.5 Haiku]
        RA[Remediation Agent<br/>Claude 3.5 Haiku]
        RP[Reporter Agent<br/>Claude 3.5 Haiku]
    end

    subgraph "Action Group Lambda層"
        IAL[incident-investigator Lambda<br/>CloudWatch/X-Ray/Config]
        CAL[cost-optimizer Lambda<br/>Cost Explorer/Trusted Advisor]
        RAL[remediation Lambda<br/>SSM/EC2操作]
        RPL[reporter Lambda<br/>S3 HTML + Chatwork]
    end

    subgraph "データ層"
        DDB1[(execution-history<br/>DynamoDB)]
        DDB2[(approval-requests<br/>DynamoDB)]
        S3[S3<br/>HTMLレポート]
    end

    subgraph "通知"
        CW[Chatwork]
    end

    EB --> SF
    SF --> SA
    SA -->|委譲| IA
    SA -->|委譲| CA
    SA -->|委譲| RA
    SA -->|委譲| RP
    IA --> IAL
    CA --> CAL
    RA -->|承認後実行| RAL
    RP --> RPL
    IAL --> DDB1
    RAL --> DDB2
    RPL --> S3
    RPL --> CW
```

## コンポーネント説明

| コンポーネント | モデル | 役割 |
|---|---|---|
| Supervisor Agent | Claude 3.7 Sonnet | 状況判断・Sub-agent委譲 |
| Incident Investigator | Claude 3.5 Haiku | CloudWatch/X-Ray調査 |
| Cost Optimizer | Claude 3.5 Haiku | コスト分析・最適化提案 |
| Remediation Agent | Claude 3.5 Haiku | SSM/EC2修復操作（承認後） |
| Reporter Agent | Claude 3.5 Haiku | HTMLレポート生成・Chatwork通知 |

## インフラ構成（Phase 1 基盤）

- **S3**: `bmao-reports-{account_id}` — HTMLレポート保存、Presigned URL配布
- **DynamoDB**: `bmao-execution-history` — Agent実行履歴管理
- **DynamoDB**: `bmao-approval-requests` — Human-in-the-loop承認フロー
- **SSM Parameter Store**: Chatwork認証情報・設定値の安全な管理
- **IAM**: Lambda共通ロール・Supervisor Agent専用ロール
- **CloudWatch Logs**: 全Lambda・Step Functionsのログ集約（14日保持）
