"""
Bedrockへ送るプロンプトを構築するモジュール
ドリフト情報を構造化してClaude Sonnetへの入力テキストを組み立てる
"""

import json

SYSTEM_PROMPT = """あなたはAWSインフラストラクチャの専門家です。
Terraformで管理されているAWSリソースと実際の環境の差分（ドリフト）を分析し、
以下の形式で回答してください。必ずJSONのみを返し、それ以外のテキストは一切含めないこと。

{
  "drift_summary": "ドリフトの概要説明（日本語、100文字以内）",
  "root_cause": "推定される原因（日本語、200文字以内）",
  "severity": "HIGH または MEDIUM または LOW",
  "affected_resources": ["リソースアドレスのリスト"],
  "remediation_hcl": "修復用のTerraform HCLコード（完全なresourceブロック）",
  "remediation_steps": ["手動で対応すべき手順のリスト（日本語）"],
  "risk_assessment": "このドリフトを放置した場合のリスク（日本語、150文字以内）"
}"""


def build_user_prompt(drifts: list) -> str:
    """
    ドリフト情報リストからユーザープロンプトを構築する。
    各ドリフトのリソースタイプ・変更プロパティ・期待値・実際値を構造化して記載する。

    Args:
        drifts: compare_states()の戻り値リスト

    Returns:
        Bedrockへ送るユーザープロンプト文字列
    """
    # ドリフト件数をヘッダーとして記載
    lines = [
        f"以下のTerraformドリフトが検出されました。合計{len(drifts)}件のドリフトを分析してください。",
        "",
    ]

    for i, drift in enumerate(drifts, start=1):
        # 各ドリフトの概要を見出しで区切る
        lines.append(f"## ドリフト {i}: {drift.get('resource_address', 'unknown')}")
        lines.append(f"- リソースタイプ: {drift.get('resource_type', 'unknown')}")
        lines.append(f"- 物理ID: {drift.get('physical_id', 'unknown')}")
        lines.append(f"- ドリフト種別: {drift.get('drift_type', 'unknown')}")
        lines.append(f"- 重要度: {drift.get('severity', 'unknown')}")
        lines.append("")

        # 変更されたプロパティを列挙
        changed = drift.get("changed_properties", [])
        if changed:
            lines.append("### 変更されたプロパティ:")
            for prop in changed:
                path = prop.get("property_path", "")
                expected = json.dumps(prop.get("expected_value"), ensure_ascii=False)
                actual = json.dumps(prop.get("actual_value"), ensure_ascii=False)
                lines.append(f"- **{path}**")
                lines.append(f"  - 期待値（tfstate）: {expected}")
                lines.append(f"  - 実際の値: {actual}")
            lines.append("")

    lines.append("上記のドリフトを分析し、指定のJSON形式で回答してください。")

    return "\n".join(lines)
