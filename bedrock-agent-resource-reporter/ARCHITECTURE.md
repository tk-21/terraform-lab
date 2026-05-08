# ARCHITECTURE: bedrock-agent-resource-reporter

## 目次

1. [プロジェクト概要](#1-プロジェクト概要)
2. [システム全体アーキテクチャ](#2-システム全体アーキテクチャ)
3. [ネットワーク構成](#3-ネットワーク構成)
4. [Terraform モジュール構成](#4-terraform-モジュール構成)
5. [Lambda 関数の実装詳細](#5-lambda-関数の実装詳細)
6. [Bedrock Agent の仕組み](#6-bedrock-agent-の仕組み)
7. [IAM 設計（最小権限）](#7-iam-設計最小権限)
8. [データフロー（エンドツーエンド）](#8-データフローエンドツーエンド)
9. [セキュリティ設計](#9-セキュリティ設計)
10. [コスト設計](#10-コスト設計)
11. [デプロイ手順](#11-デプロイ手順)
12. [動作確認・テスト](#12-動作確認テスト)

---

## 1. プロジェクト概要

### 何をするシステムか

**Amazon Bedrock Agents** を使って AWS リソースの自律調査・レポート生成・通知を行うエージェントシステム。

```
ユーザーが一言投げるだけ
┌─────────────────────────────────────────────────────────┐
│  「東京リージョンのEC2を調べてS3にレポートを保存して通知して」  │
└─────────────────────────────────────────────────────────┘
                          ↓ 自律実行
┌───────────┐   ┌───────────┐   ┌───────────┐   ┌───────────┐
│  EC2/CW/  │ → │  Markdown │ → │  S3 保存  │ → │  メール   │
│  CE 調査  │   │  生成     │   │  (暗号化) │   │  通知     │
└───────────┘   └───────────┘   └───────────┘   └───────────┘
```

### 技術スタック

| 要素 | 選択 | 理由 |
|---|---|---|
| AI エンジン | Amazon Bedrock Agents | 自律タスク実行のオーケストレーション |
| Foundation Model | Claude 3 Haiku | コスト最優先（最安価 tier） |
| アクション実行 | AWS Lambda (Python 3.12) | サーバーレス、コールドスタート許容 |
| データ保存 | S3 + SSE-KMS | 耐久性・暗号化 |
| 通知 | SNS | 疎結合、メール/SMS/その他に対応 |
| IaC | Terraform ~> 1.7 | モジュール分割による保守性 |
| リージョン | ap-northeast-1 | 東京（Bedrock Agents サポート済み） |

---

## 2. システム全体アーキテクチャ

```
╔═══════════════════════════════════════════════════════════════════════╗
║                    bedrock-agent-resource-reporter                    ║
╚═══════════════════════════════════════════════════════════════════════╝

  👤 ユーザー（コンソール / InvokeAgent API）
       │
       │  自然言語プロンプト
       │  「東京リージョンのEC2を調べてS3にレポートを保存して」
       ▼
╔══════════════════════════════════════════════════════════════════════╗
║                     Amazon Bedrock Agent                              ║
║              claude-3-haiku-20240307  /  ap-northeast-1              ║
║                                                                      ║
║  System Prompt: 「AWSインフラ調査エージェント。                        ║
║  aws-inspector→report-writer→notifier を自律的に組み合わせること」      ║
║                                                                      ║
║  ┌─────────────────────────────────────────────────────────────┐    ║
║  │              Action Groups  (OpenAPI 3.0 スキーマ定義)        │    ║
║  │                                                             │    ║
║  │  ┌─────────────────┐  ┌──────────────────┐  ┌───────────┐  │    ║
║  │  │  aws-inspector  │  │  report-writer   │  │ notifier  │  │    ║
║  │  │─────────────────│  │──────────────────│  │───────────│  │    ║
║  │  │/get_cost_and    │  │/generate_report  │  │/send_sns_ │  │    ║
║  │  │  _usage         │  │/save_to_s3       │  │ notific.. │  │    ║
║  │  │/list_ec2_inst   │  │/list_past_reports│  └───────────┘  │    ║
║  │  │  ances          │  └──────────────────┘                 │    ║
║  │  │/get_cw_alarms   │                                       │    ║
║  │  └─────────────────┘                                       │    ║
║  └─────────────────────────────────────────────────────────────┘    ║
╚═══════╤═══════════════════════╤══════════════════╤═══════════════════╝
        │ lambda:InvokeFunction  │                  │
        ▼                        ▼                  ▼
┌───────────────┐  ┌─────────────────────┐  ┌─────────────┐
│ aws_inspector │  │    report_writer    │  │  notifier   │
│    Lambda     │  │       Lambda        │  │   Lambda    │
│───────────────│  │─────────────────────│  │─────────────│
│ Python 3.12   │  │ Python 3.12         │  │ Python 3.12 │
│ 256 MB / 60s  │  │ 256 MB / 60s        │  │ 256 MB / 60s│
│ REGION env    │  │ REPORTS_BUCKET_NAME │  │ SNS_TOPIC   │
│               │  │ env                 │  │ REGION env  │
└───┬───────────┘  └──────────┬──────────┘  └──────┬──────┘
    │                         │                     │
    │                         │                     │
    ▼                         ▼                     ▼
┌──────────────┐      ┌───────────────────┐   ┌────────────┐
│ Cost Explorer│      │     S3 Bucket     │   │ SNS Topic  │
│ (us-east-1)  │      │───────────────────│   │────────────│
│              │      │ SSE-KMS (CMK)     │   │ bedrock-   │
│ EC2 API      │      │ バージョニング有効  │   │ agent-     │
│ (ap-ne-1)    │      │ 90日ライフサイクル │   │ reporter-  │
│              │      │ パブリックアクセス  │   │ notific..  │
│ CloudWatch   │      │ ブロック           │   │            │
│ (ap-ne-1)    │      └───────────────────┘   └─────┬──────┘
└──────────────┘                                     │
                                                     ▼
                                              📧 サブスクライバー
                                              （Email / SMS 等）
```

---

## 3. ネットワーク構成

```
┌──────────────────────────────────────────────────────────────────────┐
│  VPC: 10.0.0.0/16  (bedrock-agent-reporter-vpc)  ap-northeast-1     │
│                                                                      │
│  ┌──────────────────────────┐  ┌──────────────────────────┐         │
│  │   Public Subnet AZ-a     │  │   Public Subnet AZ-c     │         │
│  │   10.0.0.0/24            │  │   10.0.1.0/24            │         │
│  │                          │  │                          │         │
│  │  ┌────────────────────┐  │  │  (冗長用・現状未使用)     │         │
│  │  │   NAT Gateway      │  │  │                          │         │
│  │  │   (EIP 固定)       │  │  │                          │         │
│  │  └─────────┬──────────┘  │  │                          │         │
│  └────────────│─────────────┘  └──────────────────────────┘         │
│               │                           │                          │
│               │ (Internet Gateway 共有)   │                          │
│  ┌────────────│─────────────┐  ┌──────────────────────────┐         │
│  │   Private Subnet AZ-a    │  │   Private Subnet AZ-c    │         │
│  │   10.0.10.0/24           │  │   10.0.11.0/24           │         │
│  │                          │  │                          │         │
│  │  (将来の Lambda 配置用)   │  │  (将来の Lambda 配置用)   │         │
│  │  ※現在 Lambda は VPC 外  │  │  ※現在 Lambda は VPC 外  │         │
│  └──────────────────────────┘  └──────────────────────────┘         │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │  VPC Endpoints                                                  │ │
│  │  ┌─────────────────────────────┐                               │ │
│  │  │  S3 Gateway Endpoint (無料)  │ → S3 へのトラフィックが       │ │
│  │  │  com.amazonaws.*.s3         │   VPC 内で完結                │ │
│  │  │  Private RT + Public RT     │   (NAT Gateway 経由なし)      │ │
│  │  └─────────────────────────────┘                               │ │
│  └────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────┘
           │
           │ Internet Gateway
           ▼
        🌐 Internet
```

### ルーティング設計

```
┌─────────────────┬──────────────────────────────────────────────────┐
│  ルートテーブル   │  ルート                                           │
├─────────────────┼──────────────────────────────────────────────────┤
│  Public RT      │  0.0.0.0/0  → Internet Gateway                   │
│                 │  S3 prefix  → S3 Gateway Endpoint                 │
├─────────────────┼──────────────────────────────────────────────────┤
│  Private RT     │  0.0.0.0/0  → NAT Gateway (AZ-a)                 │
│                 │  S3 prefix  → S3 Gateway Endpoint                 │
└─────────────────┴──────────────────────────────────────────────────┘

⚠️ 現在の Lambda は VPC 外配置のため NAT Gateway は未使用。
   将来 Lambda を VPC 内配置する際、Private Subnet + NAT Gateway が活躍。
```

---

## 4. Terraform モジュール構成

### ファイルツリー

```
bedrock-agent-resource-reporter/
│
├── environments/
│   └── dev/                          ┐
│       ├── main.tf      ← KMS/S3/SNS │ Terraform
│       ├── variables.tf              │ ルートモジュール
│       ├── terraform.tfvars          │ （エントリポイント）
│       ├── outputs.tf                │
│       └── versions.tf              ┘
│
└── modules/
    ├── networking/                   ┐
    │   ├── main.tf    ← VPC/Subnet   │ ネットワーク層
    │   ├── variables.tf              │
    │   └── outputs.tf               ┘
    │
    ├── lambda-actions/               ┐
    │   ├── main.tf    ← IAM/Lambda   │ アクション実行層
    │   ├── variables.tf              │
    │   ├── outputs.tf                │
    │   └── src/                      │
    │       ├── aws_inspector/main.py │
    │       ├── report_writer/main.py │
    │       └── notifier/main.py     ┘
    │
    └── bedrock-agent/                ┐
        ├── main.tf    ← Agent/Alias  │ エージェント層
        ├── action_groups.tf          │
        ├── iam.tf                    │
        ├── variables.tf              │
        └── outputs.tf               ┘
```

### モジュール依存グラフ

```
environments/dev (ルートモジュール)
│
├── [直接定義]
│   ├── aws_kms_key.reports           ← CMK
│   ├── aws_kms_alias.reports         ← alias/bedrock-agent-reporter
│   ├── aws_s3_bucket.reports         ← depends_on: kms_key
│   │   ├── aws_s3_bucket_versioning
│   │   ├── aws_s3_bucket_server_side_encryption_configuration
│   │   ├── aws_s3_bucket_lifecycle_configuration
│   │   └── aws_s3_bucket_public_access_block
│   └── aws_sns_topic.notifications
│
├── module.networking
│   └── 出力: vpc_id / public_subnet_ids / private_subnet_ids / nat_gateway_id
│   （bedrock_agent / lambda_actions からは現状未参照）
│
├── module.lambda_actions
│   入力 ◄── aws_s3_bucket.reports.id     (reports_bucket_name)
│   入力 ◄── aws_s3_bucket.reports.arn    (reports_bucket_arn)
│   入力 ◄── aws_sns_topic.notifications.arn (sns_topic_arn)
│   入力 ◄── aws_kms_key.reports.arn      (kms_key_arn)
│   出力 ──► aws_inspector_lambda_arn
│   出力 ──► report_writer_lambda_arn
│   出力 ──► notifier_lambda_arn
│
└── module.bedrock_agent
    入力 ◄── module.lambda_actions.aws_inspector_lambda_arn
    入力 ◄── module.lambda_actions.report_writer_lambda_arn
    入力 ◄── module.lambda_actions.notifier_lambda_arn
    出力 ──► agent_id / agent_arn / agent_alias_id
```

### 各モジュールのリソース一覧

```
module.networking
  ├── aws_vpc.this
  ├── aws_internet_gateway.this
  ├── aws_subnet.public[0,1]
  ├── aws_subnet.private[0,1]
  ├── aws_eip.nat
  ├── aws_nat_gateway.this
  ├── aws_route_table.public / .private
  ├── aws_route_table_association.public[0,1] / .private[0,1]
  └── aws_vpc_endpoint.s3

module.lambda_actions
  ├── data.archive_file.aws_inspector / .report_writer / .notifier  ← ZIP 自動生成
  ├── aws_iam_role.aws_inspector / .report_writer / .notifier
  ├── aws_iam_role_policy_attachment.*_basic                         ← AWSLambdaBasicExecutionRole
  ├── aws_iam_role_policy.*_custom                                   ← 最小権限カスタムポリシー
  ├── aws_lambda_function.aws_inspector / .report_writer / .notifier
  └── aws_lambda_permission.*_bedrock                                ← Bedrock からの呼び出し許可

module.bedrock_agent
  ├── aws_iam_role.bedrock_agent
  ├── aws_iam_role_policy.bedrock_agent
  ├── aws_bedrockagent_agent.this
  ├── aws_bedrockagent_agent_action_group.aws_inspector
  ├── aws_bedrockagent_agent_action_group.report_writer
  ├── aws_bedrockagent_agent_action_group.notifier
  └── aws_bedrockagent_agent_alias.this                              ← depends_on: 全 action_group
```

---

## 5. Lambda 関数の実装詳細

### Bedrock Agent ↔ Lambda のプロトコル

```
Bedrock Agent が Lambda を呼ぶ時のイベント（INPUT）
┌────────────────────────────────────────────────────┐
│  {                                                  │
│    "actionGroup": "aws-inspector",                  │
│    "apiPath": "/list_ec2_instances",                │
│    "httpMethod": "POST",                            │
│    "requestBody": {                                 │
│      "content": {                                   │
│        "application/json": {                        │
│          "body": "{\"region\": \"ap-northeast-1\"}" │
│        }                                            │
│      }                                              │
│    }                                                │
│  }                                                  │
└────────────────────────────────────────────────────┘
                        ↓ Lambda 処理
Lambda が Bedrock Agent に返すレスポンス（OUTPUT）
┌────────────────────────────────────────────────────┐
│  {                                                  │
│    "messageVersion": "1.0",          ← 必須・固定   │
│    "response": {                                    │
│      "actionGroup": "aws-inspector", ← echo back   │
│      "apiPath": "/list_ec2_instances",              │
│      "httpMethod": "POST",                          │
│      "httpStatusCode": 200,                         │
│      "responseBody": {                              │
│        "application/json": {                        │
│          "body": "{\"instances\":[...],\"count\":3}"│
│        }                                            │
│      }                                              │
│    }                                                │
│  }                                                  │
└────────────────────────────────────────────────────┘
```

### 5.1 aws_inspector Lambda

**ファイル**: `modules/lambda-actions/src/aws_inspector/main.py`

```
┌─────────────────────────────────────────────────────────────────┐
│                     aws_inspector Lambda                         │
│                                                                  │
│  apiPath ──► /get_cost_and_usage                                 │
│               └── ce.get_cost_and_usage()    ← us-east-1 固定   │
│               └── Granularity: MONTHLY                          │
│               └── GroupBy: SERVICE                               │
│               └── 返却: {period, costs: {サービス名: "金額 USD"}} │
│                                                                  │
│  apiPath ──► /list_ec2_instances                                 │
│               └── ec2.describe_instances()  ← リージョン指定可   │
│               └── 返却: {region, instances:[                     │
│                            {instance_id, type, state,            │
│                             name(Nameタグ), launch_time}],       │
│                          count}                                  │
│                                                                  │
│  apiPath ──► /get_cw_alarms                                      │
│               └── cw.describe_alarms()     ← REGION 環境変数    │
│               └── MetricAlarms のみ取得                           │
│               └── 返却: {alarms:[{name, state, metric,           │
│                                   description}], count}          │
└─────────────────────────────────────────────────────────────────┘
         │               │               │
         ▼               ▼               ▼
   Cost Explorer       EC2 API      CloudWatch API
   (us-east-1)      (ap-ne-1)       (ap-ne-1)
```

### 5.2 report_writer Lambda

**ファイル**: `modules/lambda-actions/src/report_writer/main.py`

```
┌─────────────────────────────────────────────────────────────────┐
│                    report_writer Lambda                          │
│                                                                  │
│  apiPath ──► /generate_report                                    │
│               入力: {title, data: {ec2_instances, costs, alarms}}│
│               └── data のキーを検知してセクションを自動生成        │
│               └── 各セクション最大10件表示                         │
│               └── S3 保存は行わない（生成のみ）                   │
│               返却: {title, content(Markdown文字列), lines}       │
│                                                                  │
│  apiPath ──► /save_to_s3                                         │
│               入力: {title, content}                              │
│               └── key: reports/{YYYY-MM-DD}/{title[:50]}.md      │
│               └── ContentType: text/markdown                     │
│               └── SSE-KMS は S3 バケット設定で自動適用            │
│               返却: {bucket, key, s3_uri, size_bytes}            │
│                                                                  │
│  apiPath ──► /list_past_reports                                   │
│               └── Prefix: reports/                               │
│               └── 30日前以降のキーのみフィルタ                     │
│               返却: {reports:[{key, s3_uri, last_modified,       │
│                               size_bytes}], count}               │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                      S3 Bucket (SSE-KMS)
                  reports/{date}/{title}.md
```

### 5.3 notifier Lambda

**ファイル**: `modules/lambda-actions/src/notifier/main.py`

```
┌─────────────────────────────────────────────────────────────────┐
│                       notifier Lambda                            │
│                                                                  │
│  apiPath ──► /send_sns_notification                              │
│               入力: {subject, message, report_uri(任意)}         │
│               └── subject は 100文字で切り捨て（SNS 制限）        │
│               └── report_uri があれば本文末尾に追記               │
│               └── UTC タイムスタンプを本文末尾に自動付加           │
│               └── sns.publish(TopicArn, Subject, Message)        │
│               返却: {message_id, topic_arn, subject}             │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                       SNS Topic
                bedrock-agent-reporter-notifications
                              │
                    ┌─────────┴──────────┐
                    ▼                    ▼
               📧 Email            📱 SMS / 他
```

### S3 に保存される Markdown レポートの構造

```markdown
# 東京リージョン EC2 調査レポート

**Generated at:** 2026-05-06 10:30:00 UTC

## Summary

### EC2 Instances

Region: ap-northeast-1 | Count: 3

- `i-0abc123` (t3.micro) - running - web-server-1
- `i-0def456` (t3.small) - stopped - batch-worker

### Cost Summary

Period: 2026-04-06 to 2026-05-06

- Amazon EC2: 12.3456 USD
- Amazon S3: 0.0234 USD

### CloudWatch Alarms

Total: 2

- CPUUtilization-high: ALARM
- DiskSpace-low: OK
```

---

## 6. Bedrock Agent の仕組み

### Action Group と OpenAPI スキーマの関係

```
action_groups.tf
├── aws_bedrockagent_agent_action_group "aws_inspector"
│   ├── action_group_executor { lambda = var.aws_inspector_lambda_arn }
│   └── api_schema { payload = jsonencode({
│         openapi: "3.0.0"
│         paths:
│           /get_cost_and_usage → POST (パラメータなし)
│           /list_ec2_instances → POST (body: {region})
│           /get_cw_alarms      → POST (パラメータなし)
│       }) }
│
├── aws_bedrockagent_agent_action_group "report_writer"
│   └── api_schema: /generate_report / /save_to_s3 / /list_past_reports
│
└── aws_bedrockagent_agent_action_group "notifier"
    └── api_schema: /send_sns_notification

↓ Bedrock がスキーマを解析
↓ 「どのツールが何をするか」を LLM (Haiku) に教示
↓ LLM がユーザー意図に応じて呼び出し順序を自律決定
```

### エージェントの推論ループ（ReAct パターン）

```
╔══════════════════════════════════════════════════════════════════╗
║  INPUT: 「東京リージョンのEC2を調べてS3にレポート保存して通知して」   ║
╚══════════════════════════════════════════════════════════════════╝
                             │
                  ┌──────────▼──────────┐
                  │    Think (LLM)      │
                  │ EC2 情報が必要だ    │
                  └──────────┬──────────┘
                             │
                  ┌──────────▼──────────┐
                  │    Act              │
                  │ aws-inspector       │
                  │ /list_ec2_instances │◄─── Lambda 呼び出し
                  └──────────┬──────────┘
                             │
                  ┌──────────▼──────────┐
                  │    Observe          │
                  │ {instances:[...],   │
                  │  count: 3}          │
                  └──────────┬──────────┘
                             │
                  ┌──────────▼──────────┐
                  │    Think (LLM)      │
                  │ データが揃った。     │
                  │ レポートを生成しよう │
                  └──────────┬──────────┘
                             │
                  ┌──────────▼──────────┐
                  │    Act              │
                  │ report-writer       │
                  │ /generate_report    │◄─── Lambda 呼び出し
                  └──────────┬──────────┘
                             │
                  ┌──────────▼──────────┐
                  │    Observe          │
                  │ {content:"# ...",   │
                  │  lines: 25}         │
                  └──────────┬──────────┘
                             │
                  ┌──────────▼──────────┐
                  │    Act              │
                  │ report-writer       │
                  │ /save_to_s3         │◄─── Lambda 呼び出し
                  └──────────┬──────────┘
                             │
                  ┌──────────▼──────────┐
                  │    Observe          │
                  │ {s3_uri:"s3://..."}│
                  └──────────┬──────────┘
                             │
                  ┌──────────▼──────────┐
                  │    Act              │
                  │ notifier            │
                  │ /send_sns_notif..   │◄─── Lambda 呼び出し
                  └──────────┬──────────┘
                             │
╔══════════════════════════════════════════════════════════════════╗
║  OUTPUT: 「EC2 3台を調査しレポートを s3://... に保存しました。     ║
║           SNS で通知済みです。」                                   ║
╚══════════════════════════════════════════════════════════════════╝
```

### Agent バージョンとエイリアスの仕組み

```
┌─────────────────────────────────────────────────────────┐
│  Agent バージョン管理                                     │
│                                                         │
│  DRAFT ←── 開発中（Action Group 変更が即時反映）          │
│    │                                                    │
│    └── alias "dev" ──► DRAFT を指す                     │
│                        API 呼び出し時はエイリアス ID を使う │
│                                                         │
│  v1 (snapshot)                                          │
│    └── alias "prod" ──► v1 を指す（本番用途）             │
│                                                         │
│  ※ terraform では prepare_agent = true で自動 PREPARED  │
│     → apply 後すぐコンソールからテスト可能               │
└─────────────────────────────────────────────────────────┘
```

---

## 7. IAM 設計（最小権限）

### 権限の全体図

```
┌─────────────────────────────────────────────────────────────────────┐
│                        IAM 信頼関係と権限                             │
│                                                                     │
│  bedrock.amazonaws.com                                              │
│    │ AssumeRole (条件: aws:SourceAccount = 自アカウントのみ)          │
│    ▼                                                                │
│  ┌──────────────────────────────────┐                              │
│  │  bedrock-agent-reporter-role     │                              │
│  │  ─────────────────────────────  │                              │
│  │  bedrock:InvokeModel             │ ← Haiku モデル ARN のみ       │
│  │  lambda:InvokeFunction           │ ← 3関数の ARN のみ            │
│  └──────────────────────────────────┘                              │
│                                                                     │
│  lambda.amazonaws.com                                               │
│    │ AssumeRole                                                     │
│    ├──► aws_inspector_role                                          │
│    │     ├── AWSLambdaBasicExecutionRole (managed)                  │
│    │     └── カスタムポリシー:                                        │
│    │           ce:GetCostAndUsage      Resource: *                  │
│    │           ec2:DescribeInstances   Resource: *                  │
│    │           cloudwatch:DescribeAlarms Resource: *                │
│    │                                                                │
│    ├──► report_writer_role                                          │
│    │     ├── AWSLambdaBasicExecutionRole (managed)                  │
│    │     └── カスタムポリシー:                                        │
│    │           s3:PutObject            Resource: bucket/* のみ      │
│    │           s3:GetObject            Resource: bucket/* のみ      │
│    │           s3:ListBucket           Resource: bucket のみ        │
│    │           kms:GenerateDataKey     Resource: CMK ARN のみ       │
│    │           kms:Decrypt             Resource: CMK ARN のみ       │
│    │                                                                │
│    └──► notifier_role                                               │
│          ├── AWSLambdaBasicExecutionRole (managed)                  │
│          └── カスタムポリシー:                                         │
│                sns:Publish             Resource: Topic ARN のみ     │
└─────────────────────────────────────────────────────────────────────┘
```

### Lambda リソースベースポリシー（循環依存回避の設計）

```
通常の設計（循環依存が発生する）
┌──────────────────────┐       ┌──────────────────────┐
│  bedrock-agent モジュ │──────►│ lambda-actions モジュ │
│  ール（agent_arn が   │       │ ール（lambda_arn が   │
│  確定してから         │◄──────│ 確定してから作成）     │
│  permission 作成）   │       └──────────────────────┘
└──────────────────────┘
         ↑ 循環依存！両方が相手を待つ

今回の設計（ワイルドカードで解消）
aws_lambda_permission.source_arn =
  "arn:aws:bedrock:{region}:{account}:agent/*"
                                           ↑ 全 Agent を許可
  → bedrock-agent モジュールの ARN を知らなくても作成可能
  → 循環依存なし、セキュリティも同一アカウント内に限定
```

---

## 8. データフロー（エンドツーエンド）

```
TIME ──────────────────────────────────────────────────────────────►

① ユーザー
   │  「東京リージョンのEC2を調べてレポートをS3に保存して通知して」
   ▼

② Bedrock Agent（推論開始）
   │
   ├──[Action]──► aws_inspector Lambda
   │               POST /list_ec2_instances
   │               {"region": "ap-northeast-1"}
   │               ◄── {"instances":[...], "count": N}
   │
   ├──[Action]──► aws_inspector Lambda  ※必要と判断した場合
   │               POST /get_cost_and_usage
   │               ◄── {"period":"...", "costs":{...}}
   │
   ├──[Action]──► aws_inspector Lambda  ※必要と判断した場合
   │               POST /get_cw_alarms
   │               ◄── {"alarms":[...], "count": N}
   │
   ├──[Action]──► report_writer Lambda
   │               POST /generate_report
   │               {"title":"...", "data":{ec2_instances, costs, alarms}}
   │               ◄── {"content":"# ...(Markdown)...", "lines": N}
   │
   ├──[Action]──► report_writer Lambda
   │               POST /save_to_s3
   │               {"title":"...", "content":"...Markdown..."}
   │               ◄── {"s3_uri":"s3://bucket/reports/2026-05-06/xxx.md"}
   │
   │               ↓ S3 に保存（SSE-KMS 暗号化）
   │               s3://bedrock-agent-reporter-reports-{account}/
   │                   reports/2026-05-06/東京EC2調査.md
   │
   ├──[Action]──► notifier Lambda
   │               POST /send_sns_notification
   │               {"subject":"...", "message":"...",
   │                "report_uri":"s3://..."}
   │               ◄── {"message_id":"...", "topic_arn":"..."}
   │
   │               ↓ SNS 発行
   │               件名: AWSリソース調査レポート完了
   │               本文: ... + s3:// URI + Timestamp
   │               ↓
   │               📧 Email サブスクライバーに届く
   │
   └──► ユーザーへの最終回答
        「EC2 N台を調査し、レポートを s3://... に保存しました。
         SNS 通知も送信済みです。」
```

---

## 9. セキュリティ設計

### S3 バケットのセキュリティレイヤー

```
┌─────────────────────────────────────────────────────────────────┐
│  S3 Bucket: bedrock-agent-reporter-reports-{account}            │
│                                                                 │
│  Layer 1: アクセス制御                                           │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Public Access Block (全4設定 = true)                    │   │
│  │  ・block_public_acls       → ACL でのパブリック化禁止     │   │
│  │  ・block_public_policy     → ポリシーでのパブリック化禁止  │   │
│  │  ・ignore_public_acls      → 既存 ACL を無効化           │   │
│  │  ・restrict_public_buckets → パブリックポリシー無効化     │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  Layer 2: 暗号化                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  SSE-KMS (CMK: alias/bedrock-agent-reporter)             │   │
│  │  ・bucket_key_enabled = true → KMS API コール削減        │   │
│  │  ・キーローテーション: 年次自動                            │   │
│  │  ・削除猶予: 7日間                                        │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  Layer 3: バージョン管理・ライフサイクル                           │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  バージョニング: 有効 → 誤削除から復元可能                  │   │
│  │  ライフサイクル:                                          │   │
│  │    reports/ 配下 → 90日後に現行バージョン削除             │   │
│  │    旧バージョン  → 30日後に削除                            │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

### Bedrock Agent ロールの Condition による保護

```
bedrock.amazonaws.com が AssumeRole できる条件:

  通常（Condition なし）
  ┌────────────────────────────────────────────────────┐
  │  どのアカウントの Bedrock からでも AssumeRole 可能   │  ← 危険
  └────────────────────────────────────────────────────┘

  今回の設計（aws:SourceAccount 条件あり）
  ┌────────────────────────────────────────────────────┐
  │  StringEquals:                                     │
  │    "aws:SourceAccount": "123456789012"              │  ← 自アカウントのみ
  └────────────────────────────────────────────────────┘
  → クロスアカウントからの不正呼び出しを防止
```

---

## 10. コスト設計

### 月額コスト見積もり（軽量テスト: 月10回実行）

```
┌─────────────────────────────────────────────────────────────┐
│  サービス別コスト内訳                                          │
│                                                             │
│  NAT Gateway  ████████████████████████████████  ~$3.50     │
│  ($0.045/h × 730h)                              ← 支配的    │
│                                                             │
│  Bedrock      █  ~$0.05                                     │
│  Lambda       ▏  ~$0.00  (無料枠内)                         │
│  S3           ▏  ~$0.01                                     │
│  SNS          ▏  ~$0.00  (無料枠内)                         │
│  CW Logs      ▏  ~$0.01                                     │
│                                                             │
│  合計                                           ~$3.57/月   │
└─────────────────────────────────────────────────────────────┘

⚠️ Lambda を VPC 外に置けば NAT Gateway は不要。
   現在の VPC は将来の VPC 内 Lambda 移行に備えた構成。
```

### コスト最適化の判断根拠

```
Bedrock モデル選択
  Claude 3 Haiku  → $0.00025/1K input tokens
  Claude 3 Sonnet → $0.003/1K input tokens   ← 約 12 倍高い
  Claude 3 Opus   → $0.015/1K input tokens   ← 約 60 倍高い

  → variable で切替可能にしているため、本番移行時に上位モデルへ変更しやすい

NAT Gateway: 1つのみ
  2つ（各 AZ）→ ~$7.00/月
  1つ（AZ-a） → ~$3.50/月  ← 今回
  0つ（VPC 外 Lambda）→ $0   ← Lambda を VPC 外に移せば不要

S3 bucket_key_enabled = true
  → S3 がバケット単位で KMS データキーをキャッシュ
  → オブジェクトごとの KMS API コール不要
  → SSE-KMS コスト大幅削減
```

---

## 11. デプロイ手順

```bash
# 作業ディレクトリへ移動
cd bedrock-agent-resource-reporter/environments/dev

# 1. 初期化（プロバイダー・モジュール取得）
terraform init

# 2. フォーマット
terraform fmt -recursive

# 3. バリデーション（構文チェック）
terraform validate

# 4. プラン確認（必ず確認してから apply すること）
terraform plan

# 5. 適用 ← ユーザー自身が実行
terraform apply
```

### apply 後に作成されるリソース数

```
約 40 リソース（概算）:

  networking:       13 リソース (VPC/Subnet×4/IGW/NAT/EIP/RT×2/RTA×4/Endpoint)
  lambda-actions:   15 リソース (archive×3/IAM_role×3/policy_attachment×3/
                                  policy×3/lambda×3/permission×3)
  bedrock-agent:     5 リソース (IAM_role/policy/agent/action_group×3/alias)
  environments/dev:  8 リソース (KMS/alias/S3/versioning/encryption/
                                  lifecycle/public_access_block/SNS)
```

---

## 12. 動作確認・テスト

### コンソールからのテスト手順

```
1. AWS Console → Amazon Bedrock → Agents
2. "bedrock-agent-resource-reporter" を選択
3. [Test] ボタン → Alias: "dev" を選択
4. 以下を送信:

   「東京リージョンのEC2インスタンス一覧を調べて、
    Markdownレポートを作成し、S3に保存してから通知してください。」
```

### 期待される実行ステップ（コンソールの Trace で確認可能）

```
Step 1  aws-inspector  /list_ec2_instances  → EC2 一覧取得
Step 2  report-writer  /generate_report     → Markdown 生成
Step 3  report-writer  /save_to_s3          → S3 保存
Step 4  notifier       /send_sns_notif..    → SNS 通知
Final   エージェント回答 + S3 URI
```

### SNS 通知の受信設定

```bash
aws sns subscribe \
  --topic-arn "$(terraform output -raw sns_topic_arn)" \
  --protocol email \
  --notification-endpoint your@email.com
# → 確認メールが届くので Confirm をクリック
```

### S3 レポートの確認

```bash
aws s3 ls \
  "s3://$(terraform output -raw reports_bucket_name)/reports/" \
  --recursive
```

### Lambda ログの確認

```bash
# aws-inspector のログ
aws logs tail /aws/lambda/bedrock-agent-aws-inspector --follow

# report-writer のログ
aws logs tail /aws/lambda/bedrock-agent-report-writer --follow

# notifier のログ
aws logs tail /aws/lambda/bedrock-agent-notifier --follow
```

### インフラ削除

```bash
# ユーザー自身が実行すること
terraform destroy
```
