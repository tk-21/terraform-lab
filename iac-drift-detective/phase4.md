# ✅Phase 4: GitHub Actions CI/CD + README + docs
# IaC Drift Detective
#
# 【Phase 1-3 完了済み内容】
# - Terraformベースインフラ (S3/IAM/EventBridge/SSM)
# - drift-detector Lambda (tfstate取得 → CFnドリフト検知)
# - bedrock-analyzer Lambda (Bedrock分析 → HCL生成 → S3保存)
# - pr-creator Lambda (GitHub PR作成 → Chatwork通知)
# - Step Functions (3Lambda オーケストレーション)
# - Terraformモジュール 4種 (drift_detector/bedrock_analyzer/pr_creator/step_functions)
#
# 【このフェーズの目的】
# GitHub ActionsによるCI/CD・README・アーキテクチャドキュメントの整備
# ポートフォリオとして公開できる状態にする
#
# 【実行方法】
# claude < phase4.md
# ============================================================

以下のファイルを作成してください。

## 1. GitHub Actions

### .github/workflows/terraform.yml
```yaml
# トリガー:
# - push to main (terraform/**変更時)
# - pull_request (terraform/**変更時)
# - workflow_dispatch

# ジョブ: terraform
# runs-on: ubuntu-latest
# permissions: id-token: write, contents: read, pull-requests: write

# ステップ:
# 1. Checkout
# 2. Configure AWS Credentials (OIDC)
#    role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
#    aws-region: ap-northeast-1
# 3. Setup Terraform (version: 1.9.x)
# 4. Terraform Format Check
# 5. Terraform Init (environments/dev/)
# 6. Terraform Validate
# 7. Terraform Plan (PRの場合のみ)
#    - planの結果をPRコメントに投稿
# 8. Terraform Apply (mainへのpushのみ)
```

### .github/workflows/lambda_deploy.yml
```yaml
# トリガー:
# - push to main (lambda/**変更時)
# - workflow_dispatch (手動実行)

# ジョブ: deploy-lambdas
# matrix: [drift_detector, bedrock_analyzer, pr_creator]

# ステップ:
# 1. Checkout
# 2. Configure AWS Credentials (OIDC)
# 3. Setup Python 3.12
# 4. Install dependencies (requirements.txt)
#    pip install -r lambda/{matrix.lambda}/requirements.txt -t lambda/{matrix.lambda}/
# 5. Package Lambda (zip)
# 6. Upload to S3 (drift-detective-deployments-{accountid})
# 7. Update Lambda function code (aws lambda update-function-code)
# 8. Wait for update completion
# 9. Publish Lambda version
```

## 2. README.md

以下の構成でプロフェッショナルなREADMEを作成:

```markdown
# 🔍 IaC Drift Detective

> Terraform × AWS Bedrock で実現する、インフラドリフトの自動検知・AI分析・修復PR自動作成

## アーキテクチャ図
（Mermaid形式のシーケンス図を挿入）
EventBridge → Step Functions → drift-detector → bedrock-analyzer → pr-creator → GitHub PR

## 機能
- ✅ Terraform stateと実AWSリソースの差分を自動検知
- ✅ Amazon Bedrock (Claude Sonnet 3.5) による原因分析と修復HCL生成
- ✅ GitHub PRの自動作成（修復コード付き）
- ✅ Chatworkへのリアルタイム通知
- ✅ 重要度（HIGH/MEDIUM/LOW）による優先度付け

## 使用技術
| カテゴリ | 技術スタック |
|---|---|
| IaC | Terraform >= 1.9 |
| AI/ML | Amazon Bedrock (Claude Sonnet 3.5) |
| 言語 | Python 3.12 (arm64) |
| オーケストレーション | AWS Step Functions |
| CI/CD | GitHub Actions (OIDC認証) |
| 監視 | AWS Lambda Powertools, CloudWatch |

## セットアップ
1. Prerequisites
2. AWS初期設定（OIDC設定方法）
3. SSMパラメータへのトークン設定方法
4. Terraform初期デプロイ手順
5. 動作確認方法（手動実行）

## ディレクトリ構造
（CLAUDE.mdの構造をそのまま記載）

## コスト
（CLAUDE.mdのコスト表をそのまま記載）

## 設計の工夫・こだわり
- なぜLambda実行ロールにterraform apply権限を与えないか
- AI出力バリデーションの実装理由
- arm64選択の理由
```

## 3. ドキュメント

### docs/architecture.md
```markdown
# アーキテクチャ詳細

## システム概要
## コンポーネント詳細
（各Lambdaの責務・入出力を詳細に記載）
## データフロー
## エラーハンドリング設計
## セキュリティ設計
（最小権限・SSM・OIDC・バリデーションの設計意図）
## スケーラビリティ考慮
```

### docs/runbook.md
```markdown
# 運用手順書

## 日常運用
- ログ確認方法（CloudWatch Logs Insights クエリ付き）
- Step Functions実行履歴確認方法

## 障害対応
- drift-detector が失敗する場合
- bedrock-analyzer がバリデーションエラーになる場合
- GitHub PR作成が失敗する場合

## メンテナンス
- SSMパラメータ（トークン）の更新方法
- Bedrockモデルのアップデート方法
- Lambda依存ライブラリの更新方法

## コスト管理
- 月次コスト確認方法
- コスト削減オプション（実行頻度の調整）
```

## 完了確認

- [ ] GitHub ActionsのOIDC設定にアクセスキーが含まれていないこと
- [ ] READMEのMermaid図が正しく描画される形式であること
- [ ] runbook.mdに CloudWatch Logs Insights クエリが含まれていること
- [ ] terraform.ymlのPlan結果がPRコメントに投稿されること
- [ ] lambda_deploy.ymlがmatrix戦略で3関数を並列デプロイできること

## Phase 4 完了後の最終チェック

全フェーズを通じた確認事項:
- [ ] `terraform fmt -recursive` エラーなし
- [ ] `terraform validate` エラーなし
- [ ] 全Lambdaに Lambda Powertools デコレータ適用済み
- [ ] 全IAMロールにワイルドカード`*`なし
- [ ] GitHub Actions に AWS アクセスキーなし（OIDC のみ）
- [ ] CLAUDE.mdのタグ戦略が全リソースに適用済み
- [ ] 日本語コメントで設計意図が記載済み
- [ ] READMEが公開可能なクオリティであること