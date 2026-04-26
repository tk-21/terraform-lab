"""
Bedrock Claude Sonnet呼び出しモジュール
ドリフト情報をBedrockで分析し、構造化されたJSON結果を返す
"""

import json
import os

import boto3

from prompt_builder import SYSTEM_PROMPT, build_user_prompt

# 使用するモデルIDとリージョン
MODEL_ID = "anthropic.claude-sonnet-4-20250514-v1:0"
BEDROCK_REGION = os.environ.get("BEDROCK_REGION", "us-east-1")


def analyze_drifts(drifts: list) -> dict:
    """
    ドリフト情報をBedrockで分析して構造化JSON結果を返す。
    CLAUDE.mdに定義されたバリデーション5項目を実施し、失敗時はValueErrorを送出する。

    Args:
        drifts: compare_states()の戻り値リスト

    Returns:
        Bedrockが返した分析結果のdict

    Raises:
        ValueError: Bedrockレスポンスのバリデーション失敗時
    """
    # Bedrockクライアントを初期化（us-east-1固定）
    bedrock_client = boto3.client("bedrock-runtime", region_name=BEDROCK_REGION)

    # プロンプトを構築
    user_prompt = build_user_prompt(drifts)

    # Bedrock InvokeModel APIリクエストを組み立てる
    request_body = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 4096,
        "system": SYSTEM_PROMPT,
        "messages": [
            {
                "role": "user",
                "content": user_prompt,
            }
        ],
    }

    # Bedrock InvokeModelを呼び出してレスポンスを取得
    response = bedrock_client.invoke_model(
        modelId=MODEL_ID,
        body=json.dumps(request_body),
        contentType="application/json",
        accept="application/json",
    )

    # レスポンスボディをパース
    response_body = json.loads(response["body"].read())
    content_text = response_body["content"][0]["text"]

    # Bedrockが返したテキストをJSONとしてパース
    try:
        analysis_result = json.loads(content_text)
    except json.JSONDecodeError as e:
        raise ValueError(f"BedrockレスポンスのJSONパース失敗: {e}") from e

    # バリデーション1: drift_summary が文字列であること
    if not isinstance(analysis_result.get("drift_summary"), str):
        raise ValueError("バリデーション失敗: drift_summary が文字列ではありません")

    # バリデーション2: root_cause が存在すること
    if "root_cause" not in analysis_result:
        raise ValueError("バリデーション失敗: root_cause フィールドが存在しません")

    # バリデーション3: remediation_hcl が存在し "resource" キーワードを含むこと
    remediation_hcl = analysis_result.get("remediation_hcl", "")
    if not remediation_hcl or "resource" not in remediation_hcl:
        raise ValueError("バリデーション失敗: remediation_hcl が不正です（resourceブロックが含まれていません）")

    # バリデーション4: severity が HIGH/MEDIUM/LOW のいずれかであること
    valid_severities = {"HIGH", "MEDIUM", "LOW"}
    if analysis_result.get("severity") not in valid_severities:
        raise ValueError(f"バリデーション失敗: severity が不正な値です ({analysis_result.get('severity')})")

    # バリデーション5: affected_resources がリスト形式であること
    if not isinstance(analysis_result.get("affected_resources"), list):
        raise ValueError("バリデーション失敗: affected_resources がリストではありません")

    return analysis_result
