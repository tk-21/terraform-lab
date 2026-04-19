# ✅Phase 2: Lambda実装
# Ansible Playbook AI Reviewer
#
# 【Phase 1 完了済み内容】
# - IAMロール (ansible-ai-reviewer-role) 作成済み
# - API Gateway REST API (/review POST, APIキー認証) 作成済み
# - Lambda関数 (ansible-ai-reviewer, Python3.12, arm64) 作成済み（コードはプレースホルダー）
# - SSMパラメータ (github-token / api-key-secret) 作成済み
# - CloudWatch Logs グループ 作成済み
#
# 【このフェーズの目的】
# Lambda関数の全Pythonコードを実装する:
# - playbook_parser.py: YAML解析・構造化
# - bedrock_reviewer.py: Bedrock呼び出し・レビュー生成
# - review_validator.py: AI出力バリデーション
# - github_commenter.py: PRコメント投稿（重複防止）
# - index.py: メインハンドラー
#
# 【実行方法】
# claude < phase2.md
# ============================================================

以下のファイルを作成してください。

## lambda/playbook_reviewer/requirements.txt
```
aws-lambda-powertools[tracer]>=2.30.0
boto3>=1.34.0
PyYAML>=6.0.1
PyGithub>=2.1.0
```

## lambda/playbook_reviewer/playbook_parser.py
```python
"""
Ansible Playbookの YAML解析・コンテキスト抽出モジュール
BedrockへのPROMPT構築のためにPlaybookの構造を分析する
"""

import yaml
from typing import Any

# 事前スキャンで検出する危険パターン
DANGEROUS_PATTERNS = {
    "no_log_missing": "パスワードや秘密情報を扱うタスクにno_logが設定されていない",
    "shell_overuse": "shell/commandモジュールが多用されている（冪等性リスク）",
    "become_unnecessary": "become: yesが不必要に使用されている可能性",
    "hardcoded_secrets": "ハードコードされた認証情報の可能性",
    "ignore_errors_overuse": "ignore_errors: trueが多用されている",
    "deprecated_with_items": "非推奨のwith_itemsが使用されている（loopを推奨）",
}

def parse_playbook(yaml_content: str) -> dict:
    """
    Ansible PlaybookのYAMLをパースして構造化データを返す

    返却値:
    {
        "plays": [
            {
                "name": str,
                "hosts": str,
                "become": bool,
                "gather_facts": bool,
                "tasks": [
                    {
                        "name": str,
                        "module": str,           # 使用モジュール名（FQCN含む）
                        "args": dict,            # モジュール引数
                        "become": bool,
                        "no_log": bool,
                        "ignore_errors": bool,
                        "changed_when": any,
                        "failed_when": any,
                        "tags": list,
                        "loop": any,
                        "with_items": any,       # 非推奨ループ
                        "register": str,
                    }
                ],
                "handlers": [...],
                "vars": dict,
                "roles": list,
            }
        ],
        "statistics": {
            "total_tasks": int,
            "total_plays": int,
            "modules_used": list[str],    # ユニークなモジュール一覧
            "has_handlers": bool,
            "has_tags": bool,
            "uses_roles": bool,
        },
        "pre_scan_warnings": [           # 事前スキャンで検出した警告
            {
                "pattern": str,
                "locations": list[str],  # タスク名など
                "severity": str,
            }
        ],
        "parse_errors": list[str],       # パースエラーがあれば
    }

    エラーハンドリング:
    - 無効なYAMLの場合は parse_errors にメッセージを追加して返す
    - 空のPlaybookも正常に処理する
    """

def detect_module_name(task_dict: dict) -> str:
    """
    タスクディクショナリからモジュール名を特定する
    ansible.builtin.shell, shell, community.general.xxx など様々な形式に対応
    """

def scan_for_dangerous_patterns(plays: list) -> list[dict]:
    """
    DANGEROUS_PATTERNSに基づいてPlaybook全体をスキャンする
    事前にBedrockへ送る前に明確な問題を検出する
    """
```

## lambda/playbook_reviewer/bedrock_reviewer.py
```python
"""
Bedrock Claude Sonnetを使ってPlaybookをレビューするモジュール
"""

MODEL_ID = "anthropic.claude-sonnet-4-20250514-v1:0"

SYSTEM_PROMPT = """
あなたはAnsible自動化の専門家です。
提供されたAnsible Playbookを詳細にレビューし、以下のJSON形式のみで回答してください。
マークダウンのコードブロックや前置き文章は一切含めず、JSONのみを返すこと。

{
  "overall_score": 0から100の整数（100が完璧なPlaybook）,
  "summary": "レビュー全体の概要（日本語、200文字以内）",
  "issues": [
    {
      "severity": "CRITICAL または HIGH または MEDIUM または LOW",
      "category": "Security または Idempotency または ErrorHandling または Performance または Readability または BestPractice",
      "task_name": "問題のあるタスク名（なければ null）",
      "description": "問題の詳細説明（日本語）",
      "suggestion": "改善提案（具体的なコード例を含む、日本語）",
      "reference": "参考URL または Ansible公式ドキュメントへの参照（あれば）"
    }
  ],
  "recommendations": ["全体的な改善提案のリスト（日本語）"],
  "positive_aspects": ["良い点のリスト（日本語）"],
  "estimated_risk_level": "HIGH または MEDIUM または LOW"
}

レビュー観点:
1. セキュリティ: no_log、become権限、ハードコードされた認証情報、shell/commandの過剰使用
2. 冪等性: changed_when設定、command/shellモジュールの適切な使用
3. エラーハンドリング: failed_when、block/rescue/always構造
4. パフォーマンス: gather_factsの必要性、ループの効率性
5. 可読性: タスク名の明確さ、コメント、変数名
6. ベストプラクティス: FQCNモジュール名、タグ付け、handlers活用、loopvswith_items
"""

def review_playbook(parsed_playbook: dict, original_yaml: str) -> dict:
    """
    パース済みPlaybook情報をBedrockへ送信してレビューを取得する

    - プロンプトにはparsed_playbookの構造化データとoriginal_yamlの両方を含める
    - pre_scan_warningsも含めることでBedrockの分析精度を向上
    - max_tokens: 4096
    - temperature: 0（再現性を重視）
    """

def build_review_prompt(parsed_playbook: dict, original_yaml: str) -> str:
    """
    ユーザープロンプトを構築する
    - Playbook統計情報
    - 事前スキャン結果
    - 元のYAMLコード
    を構造化して記載
    """
```

## lambda/playbook_reviewer/review_validator.py
```python
"""
Bedrockのレビュー出力をバリデーションするモジュール
CLAUDE.mdに定義した6項目チェックを実装
"""

VALID_SEVERITIES = {"CRITICAL", "HIGH", "MEDIUM", "LOW"}
VALID_CATEGORIES = {
    "Security", "Idempotency", "ErrorHandling",
    "Performance", "Readability", "BestPractice"
}

def validate_review_output(raw_output: str) -> dict:
    """
    Bedrockの生出力をパース・バリデーションする

    バリデーション6項目:
    1. overall_score が 0-100 の数値
    2. issues がリスト形式
    3. 各 issue に severity（CRITICAL/HIGH/MEDIUM/LOW）が存在
    4. 各 issue に category と description が存在
    5. summary が文字列
    6. recommendations がリスト形式

    - マークダウンコードブロック除去してからJSONパース
    - バリデーション失敗時は ValueError を raise
    - 成功時はパース済みdictを返す
    """
```

## lambda/playbook_reviewer/github_commenter.py
```python
"""
GitHubのPRにレビューコメントを投稿するモジュール
重複コメント防止機能付き
"""

# コメントの識別マーカー（既存コメントの検索・更新に使用）
REVIEW_MARKER = "<!-- ansible-ai-reviewer -->"

def post_review_comment(
    github_token: str,
    repo_owner: str,
    repo_name: str,
    pr_number: int,
    review_result: dict,
    playbook_filename: str,
) -> dict:
    """
    PRにAIレビューコメントを投稿する（既存コメントは更新）

    処理フロー:
    1. 既存のREVIEW_MARKERを含むコメントを検索
    2. 存在すれば更新、なければ新規作成
    3. コメント本文はformat_review_comment()で生成

    返却値: {"comment_url": str, "action": "created" or "updated"}
    """

def format_review_comment(review_result: dict, playbook_filename: str) -> str:
    """
    レビュー結果をMarkdown形式のコメントに変換する

    フォーマット例:
    <!-- ansible-ai-reviewer -->
    ## 🤖 Ansible Playbook AI Review: `{filename}`

    **総合スコア**: {score}/100 | **リスクレベル**: {risk}

    ### 📊 サマリー
    {summary}

    ### ✅ 良い点
    - ...

    ### ⚠️ 検出された問題 ({count}件)

    #### 🔴 CRITICAL ({n}件)
    | タスク | 問題 | 改善提案 |
    |---|---|---|
    | ... | ... | ... |

    #### 🟠 HIGH ({n}件)
    ...（MEDIUMとLOWも同様）

    ### 💡 全体的な改善提案
    - ...

    ---
    *🤖 このレビューはAmazon Bedrock (Claude Sonnet 3.5)によって生成されました*
    *レビュー時刻: {timestamp}*
    """

def add_pr_labels(
    github_token: str,
    repo_owner: str,
    repo_name: str,
    pr_number: int,
    risk_level: str,
) -> None:
    """
    リスクレベルに応じてPRにラベルを付与する
    HIGH -> "ai-review: high-risk"
    MEDIUM -> "ai-review: medium-risk"
    LOW -> "ai-review: approved"
    ラベルが存在しない場合は作成する
    """
```

## lambda/playbook_reviewer/index.py
```python
"""
playbook-reviewer Lambda メインハンドラー
API Gateway (POST /review) から呼び出される

リクエストボディ (JSON):
{
    "playbook_content": str,      # Playbookの全文（YAML文字列）
    "playbook_filename": str,     # ファイル名（表示用）
    "github_repo_owner": str,
    "github_repo_name": str,
    "pr_number": int,
    "api_secret": str,            # 追加認証（SSMの api-key-secret と照合）
}

レスポンス (JSON):
{
    "status": "success" or "error",
    "overall_score": int,
    "risk_level": str,
    "issues_count": int,
    "comment_url": str,
    "message": str,
}

処理フロー:
1. リクエストボディのバリデーション（必須フィールドチェック）
2. api_secret の検証（SSMから取得して照合）
3. playbook_parser.py でYAMLパース
4. bedrock_reviewer.py でレビュー実行
5. review_validator.py でバリデーション
6. github_commenter.py でPRコメント投稿・ラベル付与
7. レスポンス返却

エラーハンドリング:
- バリデーションエラー → 400 Bad Request
- 認証エラー → 403 Forbidden
- Bedrockエラー → 500 (ログ出力)
- GitHubエラー → 500 (ログ出力)

環境変数:
- GITHUB_TOKEN_SSM_PATH
- BEDROCK_REGION (default: us-east-1)
- POWERTOOLS_SERVICE_NAME = "ansible-ai-reviewer"
- LOG_LEVEL = "INFO"

AWS Lambda Powertools:
- @logger.inject_lambda_context
- @tracer.capture_lambda_handler
- structured logging
"""
```

## 完了確認

- [ ] 全モジュールにdocstringが記載されていること
- [ ] review_validator.pyの6項目バリデーションが実装されていること
- [ ] github_commenter.pyの重複コメント防止（REVIEW_MARKERによる検索・更新）が実装されていること
- [ ] PRコメントのMarkdownにスコア・リスクレベル・問題一覧・改善提案が含まれていること
- [ ] エラーレスポンスが適切なHTTPステータスコード（400/403/500）を返すこと
- [ ] Lambda Powertoolsデコレータが適用されていること
- [ ] 日本語コメントで設計意図が記載されていること