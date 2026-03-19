# Event-Driven Pipeline Sandbox

## プロジェクト概要
SQS → Lambda → Step Functions → Bedrock の非同期 AI ジョブ処理パイプラインを実装する。
API Gateway の直接統合（Lambda 不要）と Step Functions の SDK 統合（Bedrock / DynamoDB / SNS を Lambda 不要で呼び出す）が主な学習テーマ。

## 技術スタック
- IaC: Terraform（モジュール化必須）
- クラウド: AWS ap-northeast-1
- 認証: OIDC（アクセスキー禁止）
- CI/CD: GitHub Actions
- 言語: Python 3.12（Lambda）

---

## ディレクトリ構成

```
event-driven-pipeline-sandbox/
├── CLAUDE.md
├── README.md
├── .github/workflows/terraform.yml
├── environments/dev/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── terraform.tfvars
│   ├── backend.tf
│   └── versions.tf
└── modules/
    ├── networking/          ← VPC / サブネット / VPC エンドポイント
    ├── messaging/           ← SQS (input + DLQ) / SNS
    ├── storage/             ← DynamoDB jobs + metrics（Streams 有効）
    ├── dispatcher/          ← SQS trigger Lambda → DynamoDB → Step Functions 起動
    ├── workflow/            ← Step Functions + state_machine.asl.json.tftpl
    ├── stream-processor/    ← DynamoDB Streams → Lambda → metrics table 集計
    ├── event-router/        ← EventBridge rules + DLQ Handler + Cleanup Lambda
    ├── api-ingestor/        ← API Gateway REST 直接統合（SQS / DynamoDB）
    └── observability/       ← CloudWatch ダッシュボード / アラーム / X-Ray
```

---

## 設計原則

1. Lambda は「ロジックが必要な場合のみ」使う（API GW→SQS、SFN→Bedrock は Lambda 不要）
2. セキュリティ: VPC エンドポイント必須、最小権限 IAM
3. 耐障害性: DLQ 必須、Retry/Catch 必須、TTL でデータ自動削除
4. コスト: NAT GW 1台のみ、DynamoDB on-demand、Lambda 512MB 以下

---

## タグ戦略（全リソース必須）

```hcl
tags = {
  Environment = "dev"
  Project     = "event-driven-pipeline-sandbox"
  Owner       = "your-name"
  CostCenter  = "personal"
}
```

provider の `default_tags` で一括付与。モジュール呼び出し側で `tags =` は不要。

---

## モジュール間依存関係

```
networking
  └──▶ messaging (SQS / SNS)
  └──▶ storage (DynamoDB)
         └──▶ workflow (SFN state machine)
                └──▶ dispatcher
                └──▶ stream-processor
         └──▶ event-router (SFN ARN でフィルタ)
         └──▶ api-ingestor
全モジュール ──▶ observability
```

---

## Step Functions ASL ファイル

`modules/workflow/state_machine.asl.json.tftpl` は Terraform の `templatefile()` で参照。
変数プレースホルダーは `${variable_name}` 形式。
Step Functions の JSONPath (`$.foo`, `$$.State`) は `$` のみなのでテンプレートと競合しない。

---

## VPC エンドポイント一覧

| サービス | タイプ | 用途 |
|---------|--------|-----|
| S3 | Gateway | Lambda デプロイパッケージ取得 |
| DynamoDB | Gateway | Dispatcher / StreamProcessor / Cleanup が DynamoDB へアクセス |
| states | Interface | Dispatcher が Step Functions を起動 |
| SNS | Interface | DLQ Handler / Cleanup が SNS に publish |
| logs | Interface | Lambda → CloudWatch Logs（NAT GW 不使用） |

---

## 構築スケジュール

| Week | モジュール |
|------|-----------|
| 1 | networking + messaging |
| 2 | storage |
| 3 | dispatcher |
| 4 | workflow |
| 5 | stream-processor |
| 6 | event-router + api-ingestor |
| 7 | observability + GitHub Actions |
