# アーキテクチャ詳細

## システム構成

```
┌─────────────────────────────────────────────────────────────┐
│ GitHub (レビュー対象リポジトリ)                               │
│                                                             │
│  Developer → PR作成/Push                                    │
│       ↓                                                     │
│  GitHub Actions Workflow                                    │
│   ・変更されたPlaybookファイルを取得（gh CLI）                │
│   ・各Playbookをbase64エンコードしてAPIへ送信                │
│   ・CRITICAL検出時 → exit 1 でPRブロック                    │
└──────────────────────┬──────────────────────────────────────┘
                       │ HTTPS POST /review
                       │ x-api-key: <APIキー>
                       │ Body: playbook_content / pr_number / api_secret
                       ▼
┌─────────────────────────────────────────────────────────────┐
│ AWS (ap-northeast-1)                                        │
│                                                             │
│  API Gateway (REST API)                                     │
│   ・APIキー認証（使用量プラン・スロットリング）               │
│   ・Lambda Proxy統合                                        │
│       ↓                                                     │
│  Lambda: playbook-reviewer (Python 3.12, arm64)            │
│   ├── index.py          メインハンドラー・認証・オーケストレーション
│   ├── playbook_parser.py  YAMLパース・危険パターン事前スキャン
│   ├── bedrock_reviewer.py Bedrock呼び出し・レビュー生成
│   ├── review_validator.py AI出力バリデーション（6項目）
│   └── github_commenter.py PRコメント投稿・ラベル付与
│       ↓                        ↓
│  SSM Parameter Store    Amazon Bedrock (us-east-1)         │
│   ・github-token         ・Claude Sonnet 3.5               │
│   ・api-key-secret       ・クロスリージョン呼び出し          │
└──────────────────────┬──────────────────────────────────────┘
                       │ GitHub API v3
                       ↓
               GitHub PR: コメント投稿・ラベル付与
```

---

## コンポーネント詳細

### index.py（メインハンドラー）

**責務**: リクエスト受付・認証・各モジュールのオーケストレーション・レスポンス返却

処理フロー:
1. リクエストボディのJSONパース
2. 必須フィールド検証（6フィールド）
3. SSMからapi-key-secretを取得してapi_secretと照合（第二認証）
4. SSMからgithub-tokenを取得
5. playbook_parserにYAMLパースを委譲
6. bedrock_reviewerにレビュー実行を委譲
7. review_validatorでAI出力を検証
8. github_commenterにPRコメント投稿・ラベル付与を委譲
9. 処理結果をAPI Gatewayレスポンス形式で返却

### playbook_parser.py（YAMLパーサー）

**責務**: Playbook内容の構造化と危険パターンの事前スキャン

出力構造:
- `tasks`: タスク一覧（名前・モジュール・パラメータ）
- `handlers`: ハンドラー一覧
- `vars`: 変数定義
- `pre_scan_warnings`: 事前スキャンで検出した危険パターン
- `parse_errors`: YAMLパースエラー

事前スキャン項目:
- ハードコードパスワードパターン（`password:`直後に文字列値）
- `shell`/`command`モジュールの使用頻度
- `ignore_errors: yes`の使用
- `no_log`が未設定な認証情報関連タスク

### bedrock_reviewer.py（Bedrockレビューアー）

**責務**: Amazon Bedrock（Claude Sonnet 3.5）を呼び出してPlaybookをレビュー

設計ポイント:
- 構造化JSONレスポンスを要求するシステムプロンプト
- playbook_parserの事前スキャン結果を含めてコンテキスト強化
- Bedrockクロスリージョン推論（ap-northeast-1 → us-east-1）
- タイムアウト: Lambda設定値（デフォルト60秒）に依存

出力スキーマ:
```json
{
  "overall_score": 0-100,
  "estimated_risk_level": "CRITICAL|HIGH|MEDIUM|LOW",
  "summary": "レビュー要約テキスト",
  "issues": [
    {
      "severity": "CRITICAL|HIGH|MEDIUM|LOW",
      "category": "security|idempotency|error_handling|performance|readability|best_practice",
      "description": "問題の説明",
      "line_hint": "該当箇所のヒント",
      "recommendation": "改善提案"
    }
  ],
  "recommendations": ["全体的な推奨事項リスト"]
}
```

### review_validator.py（バリデーター）

**責務**: AI出力の形式・内容を検証し、不正なデータがPRコメントに投稿されるのを防ぐ

バリデーション6項目:
1. `overall_score` が 0-100 の数値
2. `issues` がリスト型
3. 各 issue に `severity`（CRITICAL/HIGH/MEDIUM/LOW）が存在
4. 各 issue に `category` と `description` が存在
5. `summary` が文字列型
6. `recommendations` がリスト型

バリデーション失敗時は `ValueError` を raise → Lambda が 500 を返す。

### github_commenter.py（GitHubコメンター）

**責務**: レビュー結果をMarkdownコメントとしてPRに投稿し、ラベルを付与

重複防止ロジック:
- PRの既存コメントを一覧取得
- コメントボディに識別マーカー（`<!-- ansible-ai-reviewer -->`）があれば更新
- なければ新規作成

ラベル付与ルール:
- `CRITICAL` → `ai-review: critical` + `do-not-merge`
- `HIGH` → `ai-review: high`
- `MEDIUM` → `ai-review: medium`
- `LOW` → `ai-review: low` + `ai-review: passed`

---

## セキュリティ設計

### 二重認証（API Key + api_secret）の設計意図

```
GitHub Actions → API Gateway
                    ↑
             x-api-key ヘッダー（第一認証）
             ・API Gatewayネイティブ機能
             ・使用量プラン・スロットリングに連動
             ・キーが漏洩した場合のリスク: 不正API呼び出し

Lambda内部で api_secret を照合（第二認証）
             ・SSMから取得した値と比較（ランタイムで検証）
             ・キーが漏洩しても api_secret なしでは処理継続不可
             ・独立したシークレット管理（SSM SecureString）
```

API Gatewayキーはネットワーク制御・使用量管理層、api_secretはビジネスロジック層での認証という役割分担により、単一障害点を排除している。

### Playbookコンテンツの非永続化

Playbook内容はLambdaのメモリ上のみで処理し、以下への書き込みを一切行わない:
- S3バケット
- DynamoDB
- CloudWatch Logs（Playbookの生内容は除外）
- Bedrock会話履歴（ステートレス呼び出し）

インフラ構成・IPアドレス・変数名など機密情報を含む可能性があるPlaybookを永続化しないことで、意図しないデータ漏洩リスクを最小化している。

### IAM最小権限

Lambdaの実行ロールに付与する権限:
```
bedrock:InvokeModel        → 特定モデルARNのみ
ssm:GetParameter           → /ansible-ai-reviewer/* のみ
logs:CreateLogGroup        → 自身のロググループのみ
logs:CreateLogStream       → 自身のロググループのみ
logs:PutLogEvents          → 自身のロググループのみ
xray:PutTraceSegments      → Lambda Tracer用
xray:PutTelemetryRecords   → Lambda Tracer用
```

ワイルドカード（`*`）リソース指定は一切使用しない。

---

## エラーハンドリング設計

| エラー種別 | HTTPステータス | 処理 |
|---|---|---|
| JSONパースエラー | 400 | エラーメッセージを返す |
| 必須フィールド不足 | 400 | 不足フィールド名を返す |
| api_secret不一致 | 403 | 認証エラーを返す |
| SSM取得失敗 | 500 | 内部エラーを返す（詳細非公開） |
| Bedrockタイムアウト | 500 | エラーを返す |
| バリデーション失敗 | 500 | エラーを返す |
| PRコメント投稿失敗 | 500 | エラーを返す |
| ラベル付与失敗 | 200 | ログのみ（コメント成功を優先） |

Lambda Powertoolsの構造化ログ（JSON）により、CloudWatch Logs Insightsでエラー種別・発生頻度・処理時間の分析が容易。

---

## 拡張性（複数リポジトリでの共有方法）

このシステムは単一のLambda/API Gatewayエンドポイントを複数リポジトリで共有できる設計。

リポジトリごとの設定:
1. GitHub SecretsにAPIエンドポイント・キーを設定（全リポジトリで共通値）
2. `.github/workflows/ansible-review.yml` をコピー（またはカスタムActionとして参照）

APIリクエストに `github_repo_owner` と `github_repo_name` を含めることで、Lambda側でどのPRへコメントするかを動的に切り替えている。新しいリポジトリの追加にインフラ変更は不要。
