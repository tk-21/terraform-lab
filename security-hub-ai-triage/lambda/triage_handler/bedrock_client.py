"""
bedrock_client - Amazon Bedrock（Claude Haiku）呼び出しラッパー

ThrottlingException に対して指数バックオフでリトライし、
JSON パース失敗時はデフォルト値を返して処理を継続させる。
"""

import json
import logging
import os
import time

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger(__name__)

SYSTEM_PROMPT = """あなたはAWSセキュリティの専門家です。Security Hubの検出結果を分析し、
以下のJSONフォーマットのみで回答してください。説明文やMarkdownは不要です。

{
  "verdict": "即対応" | "監視継続" | "無視可能",
  "reason": "判断理由（日本語2〜3文）",
  "action": "推奨する具体的なアクション（日本語）",
  "risk_score": 1〜10の整数
}

判定基準:
- 即対応: 本番環境への即時影響リスクがある（risk_score 8以上）
- 監視継続: 対応は必要だが緊急性は低い（risk_score 4〜7）
- 無視可能: 誤検知または許容リスク（risk_score 1〜3）"""

# 最大リトライ回数と初期待機時間（指数バックオフ: 1秒→2秒→4秒）
MAX_RETRIES = 3
INITIAL_BACKOFF_SECONDS = 1


class BedrockClient:
    """Amazon Bedrock（Claude Haiku）を使ってセキュリティ Findings をトリアージするクライアント。"""

    def __init__(self) -> None:
        """Bedrock ランタイムクライアントを初期化する。"""
        # iam: bedrock:InvokeModel
        self._client = boto3.client("bedrock-runtime")
        self._model_id = os.environ.get("BEDROCK_MODEL_ID", "jp.anthropic.claude-haiku-4-5-20251001-v1:0")

    def triage(
        self,
        finding_title: str,
        severity: str,
        resource_type: str,
        resource_id: str,
        description: str,
        region: str,
    ) -> dict:
        """
        Security Hub Finding を Bedrock に渡してトリアージ結果を返す。

        Args:
            finding_title: Finding のタイトル
            severity: 重大度ラベル（CRITICAL / HIGH / MEDIUM / LOW / INFORMATIONAL）
            resource_type: 影響リソースの種別
            resource_id: 影響リソースの ID（ARN 等）
            description: Finding の説明文
            region: 検出リージョン

        Returns:
            dict: verdict, reason, action, risk_score を含むトリアージ結果
        """
        user_prompt = (
            f"以下の Security Hub Findings を分析してください。\n\n"
            f"FindingTitle: {finding_title}\n"
            f"Severity: {severity}\n"
            f"ResourceType: {resource_type}\n"
            f"ResourceId: {resource_id}\n"
            f"Description: {description}\n"
            f"検出リージョン: {region}"
        )

        request_body = {
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 512,
            "system": SYSTEM_PROMPT,
            "messages": [
                {"role": "user", "content": user_prompt}
            ],
        }

        backoff = INITIAL_BACKOFF_SECONDS
        for attempt in range(1, MAX_RETRIES + 1):
            try:
                # iam: bedrock:InvokeModel
                response = self._client.invoke_model(
                    modelId=self._model_id,
                    contentType="application/json",
                    accept="application/json",
                    body=json.dumps(request_body),
                )
                response_body = json.loads(response["body"].read())
                raw_text = response_body["content"][0]["text"]
                return self._parse_response(raw_text)

            except ClientError as e:
                error_code = e.response["Error"]["Code"]
                if error_code == "ThrottlingException" and attempt < MAX_RETRIES:
                    # ThrottlingException: 指数バックオフでリトライ
                    logger.warning(
                        "ThrottlingException が発生しました（試行 %d/%d）。%d 秒後にリトライします。",
                        attempt, MAX_RETRIES, backoff
                    )
                    time.sleep(backoff)
                    backoff *= 2
                else:
                    logger.error("Bedrock 呼び出しエラー: %s", e, exc_info=True)
                    return self._default_result()

        return self._default_result()

    def _parse_response(self, raw_text: str) -> dict:
        """
        Bedrock レスポンスのテキストから JSON を安全にパースする。

        Markdown コードブロック（```json ... ```）が混入する場合があるため、
        json.loads() の前に除去する。

        Args:
            raw_text: Bedrock が返したテキスト

        Returns:
            dict: パース済みのトリアージ結果
        """
        # Markdown コードブロックを除去
        text = raw_text.strip()
        if text.startswith("```"):
            lines = text.splitlines()
            # 先頭行（```json 等）と末尾行（```）を除去
            text = "\n".join(lines[1:-1]) if lines[-1].strip() == "```" else "\n".join(lines[1:])

        try:
            result = json.loads(text)
            # 必須キーの存在確認
            if "verdict" not in result or "risk_score" not in result:
                raise ValueError("必須キーが見つかりません")
            return result
        except (json.JSONDecodeError, ValueError) as e:
            logger.warning("Bedrock レスポンスのパースに失敗しました: %s\nraw_text: %s", e, raw_text)
            return self._default_result()

    def _default_result(self) -> dict:
        """
        パース失敗時またはエラー時のデフォルトトリアージ結果を返す。

        処理を止めないために、安全なデフォルト値を返す。

        Returns:
            dict: デフォルトのトリアージ結果
        """
        return {
            "verdict": "監視継続",
            "reason": "AI トリアージの実行に失敗しました。手動で確認してください。",
            "action": "Security Hub コンソールで直接確認してください。",
            "risk_score": 5,
        }
