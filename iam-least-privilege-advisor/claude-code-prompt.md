# iam-least-privilege-advisor — Claude Code 統合プロンプト

## 依頼内容

以下の仕様に従い、`iam-least-privilege-advisor` プロジェクトのすべてのファイルを生成してください。
CLAUDE.md に記載されたディレクトリ構成どおりに、すべてのファイルを実装してください。

フェーズごとに分割して実装すること。各フェーズ完了後に確認事項をチェックしてから次フェーズに進む。

---

## ✅Phase 1 — Terraform 基盤（IAM・S3・Access Analyzer）

以下のファイルを生成してください。

1. `terraform/variables.tf` — `project_name`, `environment`, `aws_region`, `github_token_secret_arn`（sensitive）, `chatwork_secret_arn`（sensitive）, `chatwork_room_id`, `github_owner`, `github_repo`, `bedrock_model_id`（default: `"anthropic.claude-sonnet-4-5"`）を定義する
2. `terraform/modules/iam/main.tf` — `analyzer-trigger` と `policy-advisor` それぞれの実行ロールを CLAUDE.md の IAM ポリシー設計に従って作成する。`policy-advisor` ロールに `iam:PutPolicy` 系の権限が含まれていないこと
3. `terraform/modules/s3/main.tf` — バケット名 `${var.project_name}-results-${data.aws_caller_identity.current.account_id}`、バージョニング有効・パブリックアクセスブロック・SSE-S3・90日後削除ライフサイクルルールを設定する
4. `terraform/modules/access_analyzer/main.tf` — `type = "ACCOUNT"`（外部アクセス）と `type = "ACCOUNT_UNUSED_ACCESS"`（未使用アクセス、`unused_access_age = 90`）の 2 つの Analyzer を作成する
5. 各モジュールの `variables.tf` と `outputs.tf` も生成する

### Phase 1 完了確認

- [ ] `policy-advisor` の IAM ロールに `iam:PutPolicy` 系の権限が含まれていないか
- [ ] `iam:GetPolicy` の Resource が `*` でなく対象ポリシー ARN に限定されているか
- [ ] S3 バケットに 90 日後の自動削除ライフサイクルルールが設定されているか
- [ ] GitHub Token と Chatwork Token が別々の Secrets Manager シークレットで管理されているか

---

## ✅Phase 2 — Terraform Lambda・EventBridge・ルートモジュール

以下のファイルを生成してください。

1. `terraform/modules/lambda/main.tf` — 2 つの Lambda 関数を作成する
   - `analyzer-trigger`: python3.12・arm64・256MB・60秒、環境変数: `S3_BUCKET_NAME`, `POLICY_ADVISOR_FUNCTION_NAME`
   - `policy-advisor`: python3.12・arm64・512MB・120秒、環境変数: `S3_BUCKET_NAME`, `GITHUB_TOKEN_SECRET_ARN`, `CHATWORK_SECRET_ARN`, `CHATWORK_ROOM_ID`, `GITHUB_OWNER`, `GITHUB_REPO`, `BEDROCK_MODEL_ID`
2. `terraform/modules/eventbridge/main.tf` — `aws_scheduler_schedule` を作成する（`cron(0 0 ? * MON *)`・flexible_time_window: OFF・ターゲット: `analyzer-trigger`）。Scheduler 用 IAM ロール（`lambda:InvokeFunction` のみ）も同ファイルに含める
3. `terraform/main.tf` — `iam`, `s3`, `access_analyzer`, `lambda`, `eventbridge` の 5 モジュールを呼び出す
4. `terraform/outputs.tf`・`terraform/terraform.tfvars.example` を生成する
5. 各モジュールの `variables.tf`・`outputs.tf` も生成する

### Phase 2 完了確認

- [ ] EventBridge Scheduler 用の IAM ロール（`lambda:InvokeFunction` のみ）が作成されているか
- [ ] `terraform validate` が通る構成になっているか

---

## ✅Phase 3 — Lambda: analyzer-trigger

`lambda/analyzer_trigger/handler.py` と `requirements.txt` を生成してください。

処理フロー：
1. `ListAnalyzers` で `type: ACCOUNT_UNUSED_ACCESS` のアナライザーを特定
2. `StartResourceScan` でスキャン実行
3. 最大 30 秒・5 秒間隔でスキャン完了をポーリング
4. `ListFindings` で `status = ACTIVE` な未使用アクセス Findings を取得
5. 結果を `analyzer-results/{YYYY}/{MM}/{DD}/findings.json` として S3 に保存（CLAUDE.md の JSON フォーマット参照）
6. `policy-advisor` Lambda を `InvocationType=Event` で非同期起動（ペイロードに `{"s3_key": "..."}` を含める）

規約: 全関数に docstring を記載、AWS API 呼び出し箇所に使用 IAM アクションをコメントで明記

### Phase 3 完了確認

- [ ] Lambda → Lambda 非同期呼び出しで `InvocationType=Event` が指定されているか
- [ ] S3 保存キーが `analyzer-results/{YYYY}/{MM}/{DD}/findings.json` 形式か
- [ ] すべての Python 関数に docstring が記載されているか

---

## ✅Phase 4 — Lambda: policy-advisor コアモジュール

以下の 4 ファイルを生成してください。

**`lambda/policy_advisor/iam_fetcher.py`**
`IamFetcher` クラスの `get_managed_policies(role_arn: str) -> list[dict]` を実装する。`iam:ListAttachedRolePolicies`, `iam:GetPolicy`, `iam:GetPolicyVersion` を使用してマネージドポリシーのみ取得する（インラインポリシーは対象外）。戻り値: `[{"policy_name", "policy_arn", "document"}]`

**`lambda/policy_advisor/bedrock_client.py`**
`BedrockClient` クラスを実装する。`boto3.client("bedrock-runtime")` の `invoke_model()` を使用し、CLAUDE.md のシステムプロンプト・ユーザープロンプトを送信する。Markdown コードブロック（` ```json ` / ` ``` `）を除去してから `json.loads()` でパース。`ThrottlingException` に対して指数バックオフ（1秒→2秒→4秒、最大3回）でリトライ。パース失敗時は `None` を返す

**`lambda/policy_advisor/terraform_formatter.py`**
`TerraformFormatter.format_as_terraform(policy_name, policy_arn, revised_policy, reason, removed_actions) -> str` を実装する。`jsonencode()` 形式（ヒアドキュメント不可）、先頭に `# AI生成 - レビュー必須` コメント、削除アクションと変更理由をコメントで記載、インデント2スペース

**`lambda/policy_advisor/chatwork_notifier.py`**
Secrets Manager から Chatwork トークンを取得し、CLAUDE.md の通知フォーマットで通知する。失敗は `raise` せずエラーログのみ

### Phase 4 完了確認

- [ ] Bedrock レスポンスの Markdown コードブロック除去処理が含まれているか
- [ ] Chatwork 通知失敗時に例外を raise していないか
- [ ] すべての Python 関数に docstring が記載されているか

---

## ✅Phase 5 — Lambda: policy-advisor handler・GitHub PR・AI 検証

以下の 2 ファイルを生成してください。

**`lambda/policy_advisor/github_pr_creator.py`**
`GithubPrCreator` クラスを実装する。GitHub REST API を使用して以下のフローで PR を作成する：
1. Secrets Manager から GitHub Token 取得
2. `GET /repos/{owner}/{repo}/git/ref/heads/main` で最新 SHA 取得
3. ブランチ作成: `fix/iam-least-privilege-{YYYYMMDD}-{role_name_short}`（ロール名は20文字に切り詰め）
4. `PUT /repos/{owner}/{repo}/contents/terraform/iam_policies/{role_name_short}.tf` でファイルをコミット（content は base64 エンコード）
5. PR 作成（CLAUDE.md のタイトル・本文フォーマット参照）。GitHub API 失敗は `raise` してエラーとして記録する

**`lambda/policy_advisor/handler.py`**
policy-advisor のメインエントリーポイントを実装する。以下の処理フローを実装する：
1. イベントから S3 キーを取得（なければ当日の最新ファイルを S3 から取得）
2. S3 から findings.json を読み込み
3. findings をロール ARN でグループ化
4. 各ロールに対して：
   a. `IamFetcher.get_managed_policies(role_arn)` で現行ポリシー取得
   b. `BedrockClient.generate_least_privilege_policy()` で最小権限版生成
   c. `validate_ai_policy()` で AI 出力検証（失敗時はスキップ・警告ログ）
   d. `TerraformFormatter.format_as_terraform()` で HCL 変換
   e. `GithubPrCreator.create_pr()` で PR 作成
   f. `ChatworkNotifier.notify()` で通知
5. 処理件数・PR 作成数・スキップ数をログ出力

同ファイルに `validate_ai_policy()` 関数も実装する（CLAUDE.md の AI 出力検証を参照）：

```python
def validate_ai_policy(original_policy: dict, revised_policy: dict, unused_actions: list) -> tuple[bool, str]:
    """
    AI 生成ポリシーの安全性を検証する。

    # AI出力検証: 以下の5項目をすべてパスした場合のみ True を返す
    # 1. revised_policy に Version と Statement が存在するか
    # 2. unused_actions 以外のアクションが削除されていないか
    # 3. Resource 指定が元のポリシーから変更されていないか
    # 4. Condition が元のポリシーから変更・削除されていないか
    # 5. Effect: Deny の Statement が変更されていないか
    """
```

### Phase 5 完了確認

- [ ] `validate_ai_policy()` の 5 項目の検証がすべて実装されているか
- [ ] AI 出力検証箇所に `# AI出力検証:` プレフィックスのコメントがあるか
- [ ] GitHub API 失敗時に `raise` しているか
- [ ] 日時表示がすべて JST になっているか

---

## ✅Phase 6 — GitHub Actions・その他ファイル

以下のファイルを生成してください。

**`.github/workflows/deploy.yml`**
- PR 時: `terraform fmt -check`・`terraform validate`・`terraform plan`、plan 結果を `actions/github-script` で PR コメントに投稿
- main マージ時: Lambda ZIP 生成（`analyzer_trigger` と `policy_advisor` の 2 つ）→ `terraform apply -auto-approve`
- OIDC 認証: `aws-actions/configure-aws-credentials@v4`

**`.gitignore`**
```
*.tfvars
!*.tfvars.example
.terraform/
.terraform.lock.hcl
__pycache__/
*.pyc
*.zip
.env
```

**`README.md`**（以下のセクション構成）
1. プロジェクト概要（アーキテクチャ図はテキスト矢印で表現）
2. 前提条件（AWS CLI, Terraform, Python 3.12, Access Analyzer 有効化）
3. セットアップ手順（Secrets Manager への GitHub Token / Chatwork Token 登録・GitHub OIDC プロバイダーの設定・terraform init → apply）
4. 動作確認方法（EventBridge Scheduler を手動で invoke する方法）
5. AI 出力のレビューポイント（何を確認すべきか）
6. コスト目安
7. 注意事項（Access Analyzer 未使用アクセス分析は費用が発生する。不要時は Analyzer を削除する）

### Phase 6 完了確認

- [ ] Lambda ZIP 生成ステップが apply 前に含まれているか
- [ ] OIDC 認証が `aws-actions/configure-aws-credentials@v4` で設定されているか

---

## ✅全フェーズ完了後の最終確認

- [ ] `terraform validate` が通る構成になっているか
- [ ] `policy-advisor` の IAM ロールに `iam:PutPolicy` 系の権限が含まれていないか
- [ ] `iam:GetPolicy` の Resource が `*` でなく対象ポリシー ARN に限定されているか
- [ ] GitHub Token と Chatwork Token が別々の Secrets Manager シークレットで管理されているか
- [ ] `validate_ai_policy()` の 5 項目の検証がすべて実装されているか
- [ ] Bedrock レスポンスの Markdown コードブロック除去処理が含まれているか
- [ ] EventBridge Scheduler 用の IAM ロール（`lambda:InvokeFunction` のみ）が作成されているか
- [ ] S3 バケットに 90 日後の自動削除ライフサイクルルールが設定されているか
- [ ] すべての Python 関数に docstring が記載されているか
- [ ] AI 出力検証箇所に `# AI出力検証:` プレフィックスのコメントがあるか
- [ ] Lambda → Lambda 非同期呼び出しで `InvocationType=Event` が指定されているか
- [ ] 日時表示がすべて JST になっているか
