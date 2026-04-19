# Ansible Playbook AI Reviewer - CLAUDE.md

## プロジェクト概要

**目的**: GitHub ActionsのCI/CDパイプラインでAnsible PlaybookをAmazon Bedrock (Claude Sonnet)が自動レビューし、品質問題・セキュリティリスク・ベストプラクティス違反を検出してPRコメントとして投稿するシステム

**ポートフォリオ訴求**: 「CI/CD × AI自動化 × Ansibleのベストプラクティスを実装できるエンジニア」

---

## ディレクトリ構造

```
ansible-playbook-ai-reviewer/
├── CLAUDE.md                          # このファイル（プロジェクト記憶）
├── README.md
├── terraform/
│   ├── main.tf                        # IAM・Lambda・API Gateway
│   ├── variables.tf
│   ├── outputs.tf
│   ├── backend.tf
│   └── modules/
│       ├── reviewer_lambda/
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   └── outputs.tf
│       └── api_gateway/
│           ├── main.tf
│           ├── variables.tf
│           └── outputs.tf
├── lambda/
│   └── playbook_reviewer/
│       ├── index.py                   # メインハンドラー（API Gateway経由）
│       ├── playbook_parser.py         # YAML解析・コンテキスト抽出
│       ├── bedrock_reviewer.py        # Bedrock呼び出し・レビュー生成
│       ├── github_commenter.py        # PRコメント投稿
│       ├── review_validator.py        # AI出力バリデーション
│       └── requirements.txt
├── github_actions/
│   └── ansible-ai-review/
│       ├── action.yml                 # カスタムGitHub Action定義
│       └── README.md
├── .github/
│   └── workflows/
│       ├── deploy.yml                 # Terraform + Lambda デプロイ
│       └── example_ansible_review.yml # サンプル: Ansible PRのレビューワークフロー
├── examples/
│   ├── sample_playbook_good.yml       # ベストプラクティス準拠例
│   └── sample_playbook_bad.yml        # 意図的に問題を含む例（レビューデモ用）
└── docs/
    ├── architecture.md
    ├── review_criteria.md             # レビュー観点の詳細説明
    └── runbook.md
```

---

## アーキテクチャ

```
GitHub PR作成/更新
    │
    ▼
GitHub Actions Workflow (example_ansible_review.yml)
    │ 変更されたPlaybookファイルを取得
    │ API Gatewayへリクエスト
    ▼
API Gateway (POST /review)
    │
    ▼
Lambda: playbook-reviewer
    │
    ├─► playbook_parser.py
    │       - 変更されたPlaybookのYAMLをパース
    │       - タスク一覧・変数・ハンドラーを構造化
    │       - 危険なモジュール・パターンを事前スキャン
    │
    ├─► bedrock_reviewer.py
    │       - Bedrock Claude Sonnet 3.5でレビュー実行
    │       - 構造化JSON形式でレビュー結果を取得
    │       - review_validator.pyでバリデーション
    │
    └─► github_commenter.py
            - PRにMarkdownコメントを投稿
            - 重大度別にラベルを付与
            - 既存レビューコメントを更新（重複防止）
```

---

## レビュー観点（Bedrock分析対象）

| カテゴリ | チェック内容 |
|---|---|
| **セキュリティ** | become: yes の不必要な使用、平文パスワード、no_log未設定、shell/commandモジュールの過剰使用 |
| **冪等性** | changed_when未設定のcommand/shell、fileモジュールの不適切な使用 |
| **エラーハンドリング** | ignore_errors乱用、failed_when未設定、ロールバック処理不足 |
| **パフォーマンス** | ループの非効率な記述、不要なgather_facts、with_items非推奨 |
| **可読性** | タスク名の不明確さ、コメント不足、変数名の命名規則 |
| **ベストプラクティス** | FQCNモジュール名、タグ未設定、handlers活用 |

---

## 命名規則

| リソース種別 | 命名パターン | 例 |
|---|---|---|
| Lambda関数 | `ansible-ai-reviewer` | - |
| IAMロール | `ansible-ai-reviewer-role` | - |
| API Gateway | `ansible-ai-reviewer-api` | - |
| SSMパラメータ | `/ansible-ai-reviewer/{key}` | `/ansible-ai-reviewer/github-token` |

---

## タグ戦略

```hcl
tags = {
  Project     = "ansible-playbook-ai-reviewer"
  Environment = var.environment
  ManagedBy   = "terraform"
  Owner       = "infra-team"
  CostCenter  = "portfolio"
}
```

---

## 設計方針・禁止事項

### 設計方針
- **Lambda**: Python 3.12, arm64, AWS Lambda Powertools必須
- **Bedrock**: Claude Sonnet 3.5 (us-east-1)
- **API Gateway**: REST API（Lambda Proxy統合）、APIキー認証
- **Secrets**: GitHub TokenはSSM Parameter Store (SecureString)
- **冪等性**: 同じPRへのコメントは更新（新規作成で重複させない）
- **コメント**: 日本語で設計意図を記載

### 禁止事項
- APIキーのコード内ハードコード禁止
- Lambda実行ロールへの過剰な権限付与禁止
- Playbookの内容をS3以外に永続化しない（プライバシー考慮）

---

## AI出力バリデーション

`review_validator.py` は以下の6項目をチェック:
1. `overall_score` が 0-100 の数値であること
2. `issues` がリスト形式であること
3. 各 issue に `severity`（CRITICAL/HIGH/MEDIUM/LOW）が存在すること
4. 各 issue に `category` と `description` が存在すること
5. `summary` が文字列であること
6. `recommendations` がリスト形式であること

---

## コスト見積もり

| リソース | 想定コスト/月 |
|---|---|
| Lambda（PRごとに実行、月50回想定） | ~$0.05 |
| API Gateway | ~$0.02 |
| Bedrock Claude Sonnet | ~$1.50 |
| **合計** | **~$2.00/月** |

---

## リージョン・環境

- **デフォルトリージョン**: ap-northeast-1 (Tokyo)
- **Bedrockリージョン**: us-east-1

---

## フェーズ構成

| フェーズ | 内容 |
|---|---|
| Phase 1 | Terraformベースインフラ（IAM・API Gateway・Lambda・SSM） |
| Phase 2 | Lambda実装（parser・reviewer・validator・commenter） |
| Phase 3 | GitHub Actions（カスタムAction・サンプルワークフロー） |
| Phase 4 | サンプルPlaybook・README・docs |