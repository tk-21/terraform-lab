"""
Bedrock Claude Sonnetを使ってPlaybookをレビューするモジュール
"""

import json
import os
import re

import boto3

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

    - max_tokens: 4096, temperature: 0（再現性重視）
    - 戻り値はパース済みdictを返す（validate前の段階）
    """
    region = os.environ.get("BEDROCK_REGION", "us-east-1")
    client = boto3.client("bedrock-runtime", region_name=region)

    prompt = build_review_prompt(parsed_playbook, original_yaml)

    body = json.dumps({
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 4096,
        "temperature": 0,
        "system": SYSTEM_PROMPT,
        "messages": [
            {"role": "user", "content": prompt}
        ],
    })

    response = client.invoke_model(
        modelId=MODEL_ID,
        contentType="application/json",
        accept="application/json",
        body=body,
    )

    response_body = json.loads(response["body"].read())
    raw_text: str = response_body["content"][0]["text"]

    # マークダウンコードブロックを除去してからパース
    clean_text = raw_text.strip()
    if clean_text.startswith("```"):
        clean_text = re.sub(r"^```[a-z]*\n?", "", clean_text)
        clean_text = re.sub(r"\n?```$", "", clean_text)

    return json.loads(clean_text)


def build_review_prompt(parsed_playbook: dict, original_yaml: str) -> str:
    """
    ユーザープロンプトを構築する
    - Playbook統計情報
    - 事前スキャン結果
    - 元のYAMLコード
    を構造化して記載する
    """
    stats = parsed_playbook.get("statistics", {})
    warnings = parsed_playbook.get("pre_scan_warnings", [])
    parse_errors = parsed_playbook.get("parse_errors", [])

    sections: list[str] = []

    # 統計情報
    sections.append("## Playbook統計情報")
    sections.append(f"- Plays数: {stats.get('total_plays', 0)}")
    sections.append(f"- Tasks数: {stats.get('total_tasks', 0)}")
    sections.append(f"- 使用モジュール: {', '.join(stats.get('modules_used', []))}")
    sections.append(f"- Handlers定義あり: {stats.get('has_handlers', False)}")
    sections.append(f"- Tags設定あり: {stats.get('has_tags', False)}")
    sections.append(f"- Roles使用あり: {stats.get('uses_roles', False)}")

    # パースエラー
    if parse_errors:
        sections.append("\n## パースエラー")
        for err in parse_errors:
            sections.append(f"- {err}")

    # 事前スキャン警告
    if warnings:
        sections.append("\n## 事前スキャン検出の警告")
        for w in warnings:
            sections.append(
                f"- [{w['severity']}] {w['pattern']}: {', '.join(w.get('locations', []))}"
            )

    # 元のPlaybook
    sections.append("\n## Ansible Playbookコード")
    sections.append("```yaml")
    sections.append(original_yaml)
    sections.append("```")

    sections.append("\n上記のAnsible Playbookを詳細にレビューし、指定のJSON形式のみで回答してください。")

    return "\n".join(sections)
