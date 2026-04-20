"""
bedrock-analyzer Lambda
data-collectorの収集データをBedrock Claude Sonnet 3.5に渡してポストモーテムを生成する。

設計意図:
- 収集データをBedrockへの入力に整形し、構造化されたポストモーテムを生成する
- 出力は6項目の存在チェックを通過してから次ステップへ渡す（CLAUDE.md準拠）
- temperature=0で再現性重視（毎回同じ品質のレポートを生成）
"""

import json
import os
from datetime import datetime, timezone

import boto3
from aws_lambda_powertools import Logger, Tracer
from aws_lambda_powertools.utilities.typing import LambdaContext

logger = Logger()
tracer = Tracer()

bedrock_client = boto3.client("bedrock-runtime")

BEDROCK_MODEL_ID = os.environ.get(
    "BEDROCK_MODEL_ID", "anthropic.claude-3-5-sonnet-20241022-v2:0"
)

# Bedrock出力バリデーション: CLAUDE.md準拠の6項目
REQUIRED_KEYS = ["summary", "timeline", "root_cause", "impact", "prevention", "action_items"]

SYSTEM_PROMPT = """あなたはSREエンジニアです。
Kubernetes障害のポストモーテムを日本語で作成してください。
必ず以下の6項目をJSON形式で返してください。
JSON以外の文字列（説明文・マークダウン）は絶対に含めないでください。

{
  "summary": "障害の概要（2-3文）",
  "timeline": [
    {"time": "HH:MM:SS", "event": "発生したこと"}
  ],
  "root_cause": "根本原因の詳細説明",
  "impact": {
    "duration_minutes": 数値,
    "affected_pods": 数値,
    "affected_services": ["サービス名"]
  },
  "prevention": [
    {
      "title": "対策タイトル",
      "description": "対策の説明",
      "code_example": "TerraformまたはKubernetes YAMLのコード例"
    }
  ],
  "action_items": [
    {"priority": "high|medium|low", "task": "タスク内容", "owner": "担当チーム"}
  ]
}"""


@logger.inject_lambda_context
@tracer.capture_lambda_handler
def handler(event: dict, context: LambdaContext) -> dict:
    experiment_id = event["experiment_id"]
    experiment_type = event["experiment_type"]
    start_time = event["start_time"]
    end_time = event["end_time"]
    duration_seconds = event["duration_seconds"]
    collected_data = event["collected_data"]

    logger.info("Bedrock分析開始", experiment_id=experiment_id, model=BEDROCK_MODEL_ID)

    user_prompt = _build_user_prompt(
        experiment_type=experiment_type,
        experiment_id=experiment_id,
        start_time=start_time,
        end_time=end_time,
        duration_seconds=duration_seconds,
        collected_data=collected_data,
    )

    postmortem = _invoke_bedrock(user_prompt)

    # 6項目バリデーション（CLAUDE.md準拠）
    if not validate_postmortem(postmortem):
        raise ValueError(
            f"Bedrockの出力が6項目バリデーションに失敗: keys={list(postmortem.keys())}"
        )

    logger.info("Bedrock分析完了・バリデーション通過", experiment_id=experiment_id)

    return {
        "experiment_id": experiment_id,
        "experiment_type": experiment_type,
        "start_time": start_time,
        "end_time": end_time,
        "duration_seconds": duration_seconds,
        "postmortem": postmortem,
        "analysis_timestamp": datetime.now(timezone.utc).isoformat(),
        "model_id": BEDROCK_MODEL_ID,
    }


def _build_user_prompt(
    experiment_type: str,
    experiment_id: str,
    start_time: str,
    end_time: str,
    duration_seconds: int,
    collected_data: dict,
) -> str:
    """収集データを要約してBedrockへのユーザープロンプトを構築する（8,000トークン以下）"""

    # CloudWatch Logsは最大50件に絞る（トークン数削減）
    cw_logs = collected_data.get("cloudwatch_logs", [])[:50]
    cw_summary = "\n".join(
        f"[{e.get('timestamp', '')}] {e.get('message', '')}" for e in cw_logs
    ) or "ログなし"

    metrics = collected_data.get("metrics_summary", {})
    metrics_text = "\n".join(
        f"{k}: avg={v.get('avg')}%, max={v.get('max')}%"
        for k, v in metrics.items()
    ) or "メトリクスなし"

    # CloudTrailは最大20件に絞る
    ct_events = collected_data.get("cloudtrail_events", [])[:20]
    ct_summary = "\n".join(
        f"{e.get('event_time', '')} {e.get('event_source', '')} {e.get('event_name', '')}"
        for e in ct_events
    ) or "CloudTrailイベントなし"

    # K8s Eventsは最大30件に絞る
    k8s_events = collected_data.get("k8s_events", [])[:30]
    k8s_summary = "\n".join(
        f"[{e.get('namespace', '')}] {e.get('reason', '')}: {e.get('message', '')}"
        for e in k8s_events
    ) or "K8sイベントなし"

    return f"""実験種別: {experiment_type}
実験ID: {experiment_id}
障害期間: {start_time} 〜 {end_time}（{duration_seconds}秒）

【CloudWatch Logsから検出したエラー】
{cw_summary[:2000]}

【Container Insightsメトリクス（最大値）】
{metrics_text}

【CloudTrail APIコール】
{ct_summary[:1000]}

【Kubernetes Events（Warning）】
{k8s_summary[:2000]}"""


def _invoke_bedrock(user_prompt: str) -> dict:
    """Bedrock Claude Sonnet 3.5を呼び出してJSONレスポンスをパースする"""

    response = bedrock_client.invoke_model(
        modelId=BEDROCK_MODEL_ID,
        contentType="application/json",
        accept="application/json",
        body=json.dumps({
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 4096,
            "temperature": 0,
            "system": SYSTEM_PROMPT,
            "messages": [
                {"role": "user", "content": user_prompt}
            ],
        }),
    )

    response_body = json.loads(response["body"].read())
    content = response_body["content"][0]["text"].strip()

    # Claudeが ```json...``` で囲む場合に対応
    if content.startswith("```"):
        parts = content.split("```")
        content = parts[1]
        if content.startswith("json"):
            content = content[4:]

    return json.loads(content)


def validate_postmortem(result: dict) -> bool:
    """
    Bedrock出力の6項目バリデーション（CLAUDE.md準拠）。
    summary/timeline/root_cause/impact/prevention/action_items の全存在を確認する。
    """
    for key in REQUIRED_KEYS:
        if key not in result:
            logger.warning(f"バリデーション失敗: {key}が存在しません")
            return False

    # timelineが空でないことを確認
    if not result.get("timeline"):
        logger.warning("バリデーション失敗: timelineが空です")
        return False

    # action_itemsが空でないことを確認
    if not result.get("action_items"):
        logger.warning("バリデーション失敗: action_itemsが空です")
        return False

    return True
