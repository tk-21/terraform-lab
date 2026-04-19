"""
Bedrockのレビュー出力をバリデーションするモジュール
CLAUDE.mdに定義した6項目チェックを実装する
"""

import json
import re

VALID_SEVERITIES = {"CRITICAL", "HIGH", "MEDIUM", "LOW"}
VALID_CATEGORIES = {
    "Security", "Idempotency", "ErrorHandling",
    "Performance", "Readability", "BestPractice",
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
    # マークダウンコードブロック除去
    clean = raw_output.strip()
    clean = re.sub(r"^```[a-z]*\n?", "", clean)
    clean = re.sub(r"\n?```$", "", clean).strip()

    try:
        data = json.loads(clean)
    except json.JSONDecodeError as e:
        raise ValueError(f"JSONパース失敗: {e}") from e

    # 1. overall_score が 0-100 の数値
    score = data.get("overall_score")
    if not isinstance(score, (int, float)):
        raise ValueError(f"overall_scoreが数値ではありません: {score!r}")
    if not (0 <= score <= 100):
        raise ValueError(f"overall_scoreが0-100の範囲外です: {score}")

    # 2. issues がリスト形式
    issues = data.get("issues")
    if not isinstance(issues, list):
        raise ValueError(f"issuesがリストではありません: {type(issues)}")

    # 3. 各 issue に severity が存在、4. category と description が存在
    for i, issue in enumerate(issues):
        if not isinstance(issue, dict):
            raise ValueError(f"issues[{i}]がdictではありません")

        severity = issue.get("severity")
        if severity not in VALID_SEVERITIES:
            raise ValueError(
                f"issues[{i}].severityが不正です: {severity!r} "
                f"(有効値: {VALID_SEVERITIES})"
            )

        if not issue.get("category"):
            raise ValueError(f"issues[{i}].categoryが存在しません")

        if not issue.get("description"):
            raise ValueError(f"issues[{i}].descriptionが存在しません")

    # 5. summary が文字列
    summary = data.get("summary")
    if not isinstance(summary, str):
        raise ValueError(f"summaryが文字列ではありません: {type(summary)}")

    # 6. recommendations がリスト形式
    recommendations = data.get("recommendations")
    if not isinstance(recommendations, list):
        raise ValueError(f"recommendationsがリストではありません: {type(recommendations)}")

    return data
