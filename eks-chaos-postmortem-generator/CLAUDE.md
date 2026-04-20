# eks-chaos-postmortem-generator

## プロジェクト概要

AWS Fault Injection Service（FIS）でEKSクラスターに意図的な障害を注入し、
Amazon Bedrockが自動でポストモーテムドキュメントを生成するSREプラットフォーム。

**コンセプト**: 「障害を意図的に起こし、AIが人間より先にポストモーテムを書く」

## アーキテクチャ

```
FIS実験トリガー（手動 or EventBridge Schedule）
    │
    ▼
AWS Fault Injection Service
    - Pod kill（aws:eks:pod-delete）
    - Node termination（aws:eks:terminate-nodegroup-instances）
    - Network latency（aws:eks:inject-kubernetes-custom-resource）
    - CPU stress（aws:eks:inject-kubernetes-custom-resource）
    │
    │ EventBridge（実験完了イベント）
    ▼
Orchestrator Lambda（fis-event-handler）
    │ Step Functions起動
    ▼
Step Functions（postmortem-workflow）
    │
    ├─① data-collector Lambda
    │     - CloudWatch Logs（Pod/Node logs）
    │     - Container Insights メトリクス
    │     - CloudTrail（API操作履歴）
    │     - K8s Events（EKS APIサーバー経由）
    │
    ├─② bedrock-analyzer Lambda
    │     - Claude Sonnet 3.5でポストモーテム生成
    │     - 構造化出力バリデーション（6項目チェック）
    │
    ├─③ report-formatter Lambda
    │     - HTMLレポート生成 → S3保存
    │     - presigned URL生成（7日間有効）
    │
    └─④ notifier Lambda
          - Chatwork通知
          - presigned URL添付
```

## ディレクトリ構造

```
eks-chaos-postmortem-generator/
├── CLAUDE.md                          # このファイル
├── README.md
├── terraform/
│   ├── main.tf                        # プロバイダー・バックエンド設定
│   ├── variables.tf
│   ├── outputs.tf
│   ├── modules/
│   │   ├── eks/                       # EKSクラスター（Karpenter込み）
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   ├── vpc/                       # 3-tier VPC
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   ├── fis/                       # FIS実験テンプレート
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   ├── lambda/                    # 全Lambda関数
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   ├── step_functions/            # ワークフロー定義
│   │   │   ├── main.tf
│   │   │   └── postmortem_workflow.asl.json
│   │   ├── eventbridge/               # FISイベント検知ルール
│   │   │   ├── main.tf
│   │   │   └── variables.tf
│   │   └── s3/                        # レポート保存バケット
│   │       ├── main.tf
│   │       └── outputs.tf
│   └── environments/
│       └── dev/
│           ├── main.tf
│           ├── variables.tf
│           └── terraform.tfvars
├── lambda/
│   ├── fis-event-handler/             # Orchestrator
│   │   ├── main.py
│   │   └── requirements.txt
│   ├── data-collector/                # データ収集
│   │   ├── main.py
│   │   └── requirements.txt
│   ├── bedrock-analyzer/              # AI分析
│   │   ├── main.py
│   │   └── requirements.txt
│   ├── report-formatter/              # HTMLレポート生成
│   │   ├── main.py
│   │   └── requirements.txt
│   └── notifier/                      # Chatwork通知
│       ├── main.py
│       └── requirements.txt
├── k8s/
│   └── sample-app/                    # FIS実験対象のサンプルアプリ
│       ├── deployment.yaml
│       └── namespace.yaml
├── docs/
│   ├── architecture.md
│   └── runbook.md
└── .github/
    └── workflows/
        ├── terraform-plan.yml
        └── terraform-apply.yml
```

## 命名規則

| リソース種別 | 命名パターン | 例 |
|---|---|---|
| EKSクラスター | `{project}-{env}` | `eks-chaos-postmortem-dev` |
| Lambda関数 | `{project}-{function}-{env}` | `eks-chaos-postmortem-data-collector-dev` |
| S3バケット | `{project}-reports-{account_id}-{env}` | `eks-chaos-postmortem-reports-123456789-dev` |
| FIS実験 | `{project}-{experiment-type}-{env}` | `eks-chaos-postmortem-pod-kill-dev` |
| Step Functions | `{project}-postmortem-workflow-{env}` | `eks-chaos-postmortem-postmortem-workflow-dev` |
| IAMロール | `{project}-{component}-role-{env}` | `eks-chaos-postmortem-lambda-role-dev` |

## タグ戦略

全リソースに必須タグを付与：

```hcl
tags = {
  Project     = "eks-chaos-postmortem-generator"
  Environment = var.environment          # dev / stg / prod
  ManagedBy   = "terraform"
  Owner       = "takuya"
  CostCenter  = "portfolio"
}
```

## 設計方針・禁止パターン

### 設計方針
- **Lambda runtime**: Python 3.12 arm64（全Lambda統一）
- **IaC**: Terraform（モジュール構造）
- **通知**: Chatwork API（Slackは使わない）
- **レポート保存**: S3 HTMLレポート + presigned URL
- **重複排除**: DynamoDB（FIS実験IDをキーに冪等性保証）
- **AI**: Bedrock Claude Sonnet 3.5（複雑な推論）
- **認証**: OIDC経由のGitHub Actions（アクセスキー禁止）
- **可観測性**: AWS Lambda Powertools（構造化ログ・トレーシング）
- **コメント**: 日本語インラインコメントで設計意図を明記

### Bedrockへの入力設計
- CloudWatch Logsは障害開始時刻±10分でフィルタしてからBedrockに渡す
- ログは要約Lambda（data-collector）で圧縮してからbedrock-analyzerへ
- 入力トークン数の目安: 8,000トークン以下

### Bedrock出力バリデーション（6項目）
bedrock-analyzerは以下6項目が含まれることを確認してから次ステップへ：
1. 概要（summary）
2. タイムライン（timeline）
3. 根本原因（root_cause）
4. 影響範囲（impact）
5. 再発防止策（prevention）
6. アクションアイテム（action_items）

### 禁止パターン
- Lambdaのアクセスキーハードコード禁止 → IRSA使用
- Lambda実行ロールへの`iam:PutRolePolicy`付与禁止
- S3バケットのパブリックアクセス禁止
- EKSクラスターへのパブリックエンドポイント（本番では禁止）
- FIS実験の本番クラスターへの誤適用防止 → タグフィルター必須

## FIS実験設計

### 実験テンプレート一覧

| 実験名 | FISアクション | 対象 | 期間 |
|---|---|---|---|
| pod-kill | aws:eks:pod-delete | namespace=chaos-target | 即時 |
| node-termination | aws:eks:terminate-nodegroup-instances | NodeGroup=chaos | 即時 |
| network-latency | aws:eks:inject-kubernetes-custom-resource | namespace=chaos-target | 60秒 |
| cpu-stress | aws:eks:inject-kubernetes-custom-resource | namespace=chaos-target | 60秒 |

### 安全設計
- FIS実験対象Namespaceは`chaos-target`のみ（本番Namespaceは除外）
- StopCondition: CloudWatchアラームが閾値超過したら自動停止
- 全実験はタグ`ChaosTarget=true`が付いたリソースのみ対象

## コスト見積もり（月次）

| サービス | 想定コスト |
|---|---|
| EKS（クラスター料金） | ~$72 |
| EC2（Karpenter管理ノード） | ~$30（t3.medium×2想定） |
| Lambda（実行料金） | ~$1 |
| Bedrock（Claude Sonnet） | ~$3 |
| Step Functions | ~$1 |
| S3・CloudWatch | ~$2 |
| **合計** | **~$109/月** |

> ⚠️ EKSは高いため、検証後はクラスターを停止してコスト管理すること

## リージョン

- **デフォルト**: ap-northeast-1（東京）

## GitHub Actions

- `terraform-plan.yml`: PRマージ時にplan結果をPRコメントに投稿
- `terraform-apply.yml`: mainブランチpush時にapply実行
- 認証: OIDC（アクセスキー不使用）