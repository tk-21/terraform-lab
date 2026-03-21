# bedrock-agent-resource-reporter

## プロジェクト概要
Agents for Bedrock を使い、AWSリソースの自律調査と
Markdownレポート生成・S3保存・SNS通知を行うエージェント。
Terraform でゼロから構築する個人検証プロジェクト。

## 設計方針
- リージョン: ap-northeast-1
- IaC: Terraform（モジュール分割必須）
- 認証: IAM ロール（アクセスキー禁止）
- Bedrock モデル: Claude 3 Haiku（コスト優先、variable で切替可能）
- VPCエンドポイント: bedrock-runtime, s3

## タグ戦略（全リソース必須）
```hcl
tags = {
  Environment = "dev"
  Project     = "bedrock-agent-resource-reporter"
  Owner       = "your-name"
}
```

## コスト制約
- Lambda メモリ: 512MB 以下
- NAT Gateway: 1つのみ
- 月額上限: $20

## ディレクトリ構成
```
bedrock-agent-resource-reporter/
├── CLAUDE.md
├── environments/
│   └── dev/
│       ├── main.tf          # モジュール呼び出し
│       ├── variables.tf
│       ├── terraform.tfvars
│       └── versions.tf      # terraform/provider バージョン固定
├── modules/
│   ├── networking/
│   │   ├── main.tf          # VPC, サブネット, NAT GW, VPCエンドポイント
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── bedrock-agent/
│   │   ├── main.tf          # Agent本体
│   │   ├── action_groups.tf # 3つのAction Group + OpenAPI schema
│   │   ├── iam.tf           # Agent実行ロール
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── lambda-actions/
│       ├── main.tf          # Lambda 3関数 + IAMロール
│       ├── variables.tf
│       ├── outputs.tf
│       └── src/
│           ├── aws_inspector/
│           │   └── main.py  # get_cost_and_usage, list_ec2_instances, get_cw_alarms
│           ├── report_writer/
│           │   └── main.py  # generate_report, save_to_s3, list_past_reports
│           └── notifier/
│               └── main.py  # send_sns_notification
└── docs/
    └── architecture.md
```

## モジュール依存関係
```
networking
  └──▶ bedrock-agent
  └──▶ lambda-actions
         └──▶ bedrock-agent（Action Group として登録）
```

## Action Group 一覧
| グループ名 | Lambda | tools |
|---|---|---|
| aws-inspector | aws_inspector/ | get_cost_and_usage, list_ec2_instances, get_cw_alarms |
| report-writer | report_writer/ | generate_report, save_to_s3, list_past_reports |
| notifier | notifier/ | send_sns_notification |

## Lambda 返却フォーマット（Bedrock 仕様）
```json
{
  "messageVersion": "1.0",
  "response": {
    "actionGroup": "<action_group_name>",
    "apiPath": "<path>",
    "httpMethod": "POST",
    "httpStatusCode": 200,
    "responseBody": {
      "application/json": {
        "body": "<JSON string>"
      }
    }
  }
}
```

## 完了条件
- terraform plan が通ること
- Bedrock コンソールから Agent をテスト実行できること
- 「東京リージョンのEC2一覧を調べてS3にレポートを保存して」という
  1文でエージェントが複数ステップを自律実行できること
```
