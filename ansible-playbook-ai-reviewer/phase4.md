# ✅Phase 4: サンプルPlaybook + README + docs
# Ansible Playbook AI Reviewer
#
# 【Phase 1-3 完了済み内容】
# - Terraform: IAM・API Gateway・Lambda・SSM
# - Lambda: parser / reviewer / validator / commenter / index
# - GitHub Actions: カスタムAction・サンプルワークフロー・デプロイワークフロー
#
# 【このフェーズの目的】
# ポートフォリオとして公開できる状態に仕上げる:
# 1. サンプルPlaybook（良い例・悪い例）でレビューデモができるように
# 2. README（見栄えのするポートフォリオ用）
# 3. docs（アーキテクチャ・レビュー観点・運用手順）
#
# 【実行方法】
# claude < phase4.md
# ============================================================

以下のファイルを作成してください。

## 1. サンプルPlaybook

### examples/sample_playbook_bad.yml
```yaml
# 意図的に問題を含むPlaybook（AIレビューのデモ用）
# このファイルを使ってAIレビューがどのように動作するかを示す
# 含める問題:
# - CRITICAL: パスワードのハードコード、no_log未設定
# - HIGH: shell多用、become不要な箇所でのbecome: yes
# - MEDIUM: with_items使用（非推奨）、changed_when未設定のshell
# - LOW: タスク名が不明確、タグ未設定
# 実際のAnsible構文として正しいYAMLにすること
```

### examples/sample_playbook_good.yml
```yaml
# ベストプラクティスに準拠したPlaybook（比較用）
# 以下を示す:
# - FQCNモジュール名 (ansible.builtin.*)
# - no_log設定
# - changed_when / failed_when の適切な使用
# - loop (with_itemsの代わり)
# - block/rescue/always によるエラーハンドリング
# - 明確なタスク名とタグ
# - handlersの活用
# 実際のAnsible構文として正しいYAMLにすること（Webサーバーセットアップの例）
```

## 2. README.md

以下の構成で作成:

```markdown
# 🤖 Ansible Playbook AI Reviewer

> GitHub Actions × Amazon Bedrock でAnsible Playbookを自動AIレビュー。
> CRITICALな問題を検出してPRをブロック、改善提案をコメントで提供。

## デモ

（PRコメントのスクリーンショットをここに置く想定のプレースホルダー）
*PRにこのようなコメントが自動投稿されます*

## アーキテクチャ

（Mermaid シーケンス図）
GitHub PR → GitHub Actions → API Gateway → Lambda → Bedrock → GitHub PR Comment

## 機能

- ✅ Ansible Playbookの6カテゴリ自動レビュー（セキュリティ・冪等性・エラーハンドリング等）
- ✅ 重大度別（CRITICAL/HIGH/MEDIUM/LOW）の問題検出
- ✅ 具体的な改善提案とコードサンプル付きPRコメント
- ✅ CRITICALな問題検出時のPR自動ブロック
- ✅ 再利用可能なカスタムGitHub Action
- ✅ 既存レビューコメントの更新（スパム防止）

## レビュー観点

| カテゴリ | チェック内容 |
|---|---|
| セキュリティ | no_log, become乱用, ハードコード認証情報 |
| 冪等性 | changed_when, shell/command過剰使用 |
| エラーハンドリング | failed_when, block/rescue/always |
| パフォーマンス | gather_facts, ループ効率性 |
| 可読性 | タスク名, コメント, 変数名 |
| ベストプラクティス | FQCN, タグ, handlers |

## クイックスタート

### 1. インフラデプロイ

# Prerequisites: Terraform >= 1.9, AWS CLI, OIDC設定済みGitHub Actions

cd terraform/environments/dev
terraform init && terraform apply

### 2. Secretsの設定

GitHubリポジトリに以下のSecretsを設定:
- AI_REVIEWER_API_ENDPOINT
- AI_REVIEWER_API_KEY
- AI_REVIEWER_API_SECRET

### 3. ワークフローをコピー

.github/workflows/example_ansible_review.yml を対象リポジトリにコピー

## 使用技術
（技術スタック表）

## コスト
（コスト見積もり表）

## 設計の工夫
- なぜAPI GatewayにAPIキー + api_secretの二重認証を使うか
- なぜLambda Function URLではなくAPI Gatewayを使うか
- なぜPlaybookを永続化しないか（プライバシー設計）
- AI出力バリデーション6項目の設計意図
```

## 3. ドキュメント

### docs/architecture.md
```markdown
# アーキテクチャ詳細

## システム構成
## コンポーネント詳細（各モジュールの責務）
## セキュリティ設計
- 二重認証（API Key + api_secret）の設計意図
- Playbookコンテンツの非永続化
- IAM最小権限
## エラーハンドリング設計
## 拡張性（複数リポジトリでの共有方法）
```

### docs/review_criteria.md
```markdown
# レビュー観点の詳細

各カテゴリについて:
- チェック内容の詳細説明
- 問題の具体例（bad）
- 改善後の例（good）
- 参考: Ansible公式ベストプラクティスへのリンク

6カテゴリ全て記載
```

### docs/runbook.md
```markdown
# 運用手順書

## セットアップ
- OIDCロールの設定方法
- SSMパラメータへのトークン設定手順
- GitHub Secretsの設定手順

## 動作確認
- curl でAPIを手動呼び出しする方法（コマンド例付き）
- examples/sample_playbook_bad.yml を使ったテスト手順

## トラブルシューティング
- Lambda タイムアウト（Bedrock呼び出し遅延）
- API Key認証エラー
- GitHubトークン権限エラー
- Bedrockのレート制限

## CloudWatch Logs Insights クエリ集
- エラー率確認クエリ
- 処理時間分布クエリ
- CRITICALレビュー件数クエリ

## メンテナンス
- GitHubトークンの更新手順
- Bedrockモデルのアップデート方法
```

## 完了確認

- [ ] sample_playbook_bad.yml が実際に動作するAnsible YAML構文になっていること
- [ ] sample_playbook_good.yml がベストプラクティス全項目を網羅していること
- [ ] READMEのMermaid図が正しく描画されること
- [ ] docs/review_criteria.md に全6カテゴリの good/bad 例が記載されていること
- [ ] runbook.md に curl コマンド例が含まれていること

## 全フェーズ完了後の最終チェック

- [ ] `terraform fmt -recursive` エラーなし
- [ ] `terraform validate` エラーなし
- [ ] Lambda Powertoolsデコレータ全ハンドラーに適用
- [ ] IAMロールにワイルドカード`*`なし
- [ ] GitHub Actions に AWS アクセスキーなし（OIDC）
- [ ] 全リソースにタグ付与済み
- [ ] 日本語コメントで設計意図記載済み
- [ ] READMEが公開可能なクオリティ