# IaC Drift Detective - CLAUDE.md

## プロジェクト概要

**目的**: Terraform stateと実AWSリソースの差分（ドリフト）をBedrockが自然言語で説明し、修復用Terraform HCLコードを生成してGitHub PRを自動作成するシステム

**ポートフォリオ訴求**: 「Terraform運用を極め、AI×IaC自動修復まで実装できるエンジニア」

---

## ディレクトリ構造

```
iac-drift-detective/
├── CLAUDE.md                          # このファイル（プロジェクト記憶）
├── README.md
├── terraform/
│   ├── main.tf                        # ルートモジュール
│   ├── variables.tf
│   ├── outputs.tf
│   ├── backend.tf                     # S3リモートバックエンド
│   ├── modules/
│   │   ├── drift_detector/            # ドリフト検知Lambda
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   ├── bedrock_analyzer/          # Bedrock分析Lambda
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   ├── pr_creator/                # GitHub PR作成Lambda
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   └── step_functions/            # オーケストレーション
│   │       ├── main.tf
│   │       ├── variables.tf
│   │       └── outputs.tf
│   └── environments/
│       └── dev/
│           ├── main.tf
│           ├── terraform.tfvars
│           └── backend.tf
├── lambda/
│   ├── drift_detector/
│   │   ├── index.py                   # メインハンドラー
│   │   ├── drift_scanner.py           # AWS Config/CloudFormation drift API呼び出し
│   │   ├── state_comparator.py        # S3のtfstateと実環境の比較
│   │   └── requirements.txt
│   ├── bedrock_analyzer/
│   │   ├── index.py
│   │   ├── analyzer.py                # Bedrock Claude Sonnet呼び出し
│   │   ├── prompt_builder.py          # プロンプト構築
│   │   └── requirements.txt
│   └── pr_creator/
│       ├── index.py
│       ├── github_client.py           # GitHub API操作
│       ├── hcl_formatter.py           # HCL整形
│       └── requirements.txt
├── step_functions/
│   └── drift_workflow.asl.json        # State Machine定義
├── .github/
│   └── workflows/
│       ├── terraform.yml              # Terraform CI/CD (OIDC)
│       └── lambda_deploy.yml          # Lambda デプロイ
└── docs/
    ├── architecture.md                # アーキテクチャ説明
    └── runbook.md                     # 運用手順
```

---

## アーキテクチャ

```
EventBridge (cron: 毎日9時 JST)
    │
    ▼
Step Functions (DriftDetectionWorkflow)
    │
    ├─► Lambda: drift-detector
    │       - S3からtfstateを取得
    │       - AWS Config / CloudFormation Drift Detection APIで実環境取得
    │       - リソース差分リストを生成
    │       - 差分なし → Step Functions終了
    │
    ├─► Lambda: bedrock-analyzer  ← 差分あり時のみ
    │       - Bedrock Claude Sonnet 3.5で差分を分析
    │       - 原因説明（日本語）を生成
    │       - 修復用Terraform HCLコードを生成
    │       - 構造化JSON（説明＋HCL）を返却
    │
    └─► Lambda: pr-creator
            - GitHub APIでブランチ作成
            - 修復HCLをファイルとしてコミット
            - PR作成（タイトル・本文に分析結果を記載）
            - Chatwork通知
```

---

## 命名規則

| リソース種別 | 命名パターン | 例 |
|---|---|---|
| Lambda関数 | `drift-detective-{role}` | `drift-detective-analyzer` |
| IAMロール | `drift-detective-{role}-role` | `drift-detective-analyzer-role` |
| S3バケット | `drift-detective-{purpose}-{accountid}` | `drift-detective-reports-123456789` |
| EventBridge Rule | `drift-detective-schedule` | - |
| Step Functions | `DriftDetectionWorkflow` | - |
| SSMパラメータ | `/drift-detective/{key}` | `/drift-detective/github-token` |

---

## タグ戦略

全リソースに以下を付与:
```hcl
tags = {
  Project     = "iac-drift-detective"
  Environment = var.environment          # dev / prod
  ManagedBy   = "terraform"
  Owner       = "infra-team"
  CostCenter  = "portfolio"
}
```

---

## 設計方針・禁止事項

### 設計方針
- **Lambda**: Python 3.12, arm64, AWS Lambda Powertools必須
- **Bedrock**: Claude Sonnet 3.5 (claude-sonnet-4-20250514)を使用（複雑な推論が必要なため）
- **IAM**: 最小権限の原則。Lambda実行ロールはリソース別に個別作成
- **Secrets**: GitHub TokenはSSM Parameter Store（SecureString）に格納。環境変数に直書き禁止
- **CI/CD**: GitHub Actions + OIDC認証（アクセスキー使用禁止）
- **通知**: Chatwork API（Slack不使用）
- **コメント**: Lambdaコード内のコメントは日本語で設計意図を記載

### 禁止事項
- `iam:*` の wildcard付与禁止
- Lambda実行ロールへの `terraform apply` 権限付与禁止（人間レビュー必須）
- ハードコードされたAWSアカウントID・リージョン禁止（変数化すること）
- アクセスキーのコード内埋め込み禁止

---

## コスト見積もり

| リソース | 想定コスト/月 |
|---|---|
| Lambda（3関数 × 毎日実行） | ~$0.10 |
| Step Functions | ~$0.01 |
| Bedrock Claude Sonnet | ~$1.00 |
| EventBridge | 無料枠内 |
| S3（レポート保存） | ~$0.10 |
| **合計** | **~$1.50/月** |

---

## リージョン・環境

- **デフォルトリージョン**: ap-northeast-1 (Tokyo)
- **Bedrockリージョン**: us-east-1（Claude Sonnet 3.5が利用可能なリージョン）
- **環境**: dev（ポートフォリオ用）

---

## AI出力バリデーション

`bedrock_analyzer` Lambdaは以下の5項目をチェックしてから後続処理へ渡す:
1. `drift_summary` フィールドが存在し、文字列であること
2. `root_cause` フィールドが存在すること
3. `remediation_hcl` フィールドが存在し、`resource` キーワードを含むこと
4. `severity` が `HIGH` / `MEDIUM` / `LOW` のいずれかであること
5. `affected_resources` がリスト形式であること

バリデーション失敗時はStep Functionsの `TaskFailed` として処理し、PR作成をスキップする。

---

## フェーズ構成

| フェーズ | 内容 |
|---|---|
| Phase 1 | Terraformベースインフラ（IAM・S3・EventBridge・SSM） |
| Phase 2 | Lambda実装（drift-detector・bedrock-analyzer） |
| Phase 3 | Lambda実装（pr-creator）＋ Step Functions |
| Phase 4 | GitHub Actions CI/CD・README・docs |