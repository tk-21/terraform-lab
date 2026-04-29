import json
import urllib.request
import urllib.parse
import boto3
from datetime import datetime, timezone
from aws_lambda_powertools import Logger, Tracer, Metrics
from aws_lambda_powertools.metrics import MetricUnit

logger = Logger()
tracer = Tracer()
metrics = Metrics(namespace="bmao/reporter")

s3_client = boto3.client("s3")
ssm_client = boto3.client("ssm")

PRESIGNED_URL_EXPIRY = 7 * 24 * 3600  # 7日間


def _get_ssm_param(name: str) -> str:
    response = ssm_client.get_parameter(Name=name, WithDecryption=True)
    return response["Parameter"]["Value"]


def _build_html(title: str, findings: list, recommendations: list, execution_id: str) -> str:
    findings_html = "".join(
        f"<li><strong>{f.get('type', 'Finding')}</strong>: {f.get('detail', str(f))}</li>"
        for f in findings
    )
    recommendations_html = "".join(
        f"<li>{r.get('action', str(r))}"
        + (f" <span class='priority'>[{r.get('priority', '')}]</span>" if r.get("priority") else "")
        + "</li>"
        for r in recommendations
    )
    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

    return f"""<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{title}</title>
  <style>
    body {{ font-family: 'Segoe UI', sans-serif; margin: 0; background: #f5f7fa; color: #333; }}
    .header {{ background: #1a2a4a; color: #fff; padding: 24px 32px; }}
    .header h1 {{ margin: 0; font-size: 1.6rem; }}
    .header .meta {{ font-size: 0.85rem; margin-top: 8px; opacity: 0.7; }}
    .container {{ max-width: 960px; margin: 32px auto; padding: 0 16px; }}
    .card {{ background: #fff; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,.08); margin-bottom: 24px; padding: 24px; }}
    .card h2 {{ margin-top: 0; font-size: 1.1rem; color: #1a2a4a; border-bottom: 2px solid #e8ecf0; padding-bottom: 10px; }}
    ul {{ padding-left: 20px; line-height: 1.8; }}
    .priority {{ background: #fff3cd; color: #856404; padding: 2px 6px; border-radius: 4px; font-size: 0.8rem; }}
    .footer {{ text-align: center; font-size: 0.8rem; color: #888; padding: 16px; }}
  </style>
</head>
<body>
  <div class="header">
    <h1>{title}</h1>
    <div class="meta">Execution ID: {execution_id} &nbsp;|&nbsp; Generated: {generated_at}</div>
  </div>
  <div class="container">
    <div class="card">
      <h2>調査結果 (Findings)</h2>
      <ul>{findings_html or "<li>なし</li>"}</ul>
    </div>
    <div class="card">
      <h2>推奨アクション (Recommendations)</h2>
      <ul>{recommendations_html or "<li>なし</li>"}</ul>
    </div>
  </div>
  <div class="footer">bmao-ops-autopilot &copy; {datetime.now(timezone.utc).year}</div>
</body>
</html>"""


# Agent実行結果を人間が読みやすいHTMLレポートに変換。Presigned URLで安全に共有
@tracer.capture_method
def generate_html_report(params: dict) -> dict:
    execution_id = params.get("execution_id", "unknown")
    title = params.get("title", "AWS運用レポート")
    findings = params.get("findings", [])
    recommendations = params.get("recommendations", [])

    if isinstance(findings, str):
        try:
            findings = json.loads(findings)
        except Exception:
            findings = [{"detail": findings}]
    if isinstance(recommendations, str):
        try:
            recommendations = json.loads(recommendations)
        except Exception:
            recommendations = [{"action": recommendations}]

    html_content = _build_html(title, findings, recommendations, execution_id)

    bucket_name = _get_ssm_param("/bmao/s3/reports_bucket")
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    s3_key = f"reports/{execution_id}/{timestamp}.html"

    s3_client.put_object(
        Bucket=bucket_name,
        Key=s3_key,
        Body=html_content.encode("utf-8"),
        ContentType="text/html; charset=utf-8",
    )

    presigned_url = s3_client.generate_presigned_url(
        "get_object",
        Params={"Bucket": bucket_name, "Key": s3_key},
        ExpiresIn=PRESIGNED_URL_EXPIRY,
    )

    metrics.add_metric(name="ReportsGenerated", unit=MetricUnit.Count, value=1)
    logger.info(f"HTMLレポート生成完了: s3_key={s3_key}")
    return {"s3_key": s3_key, "presigned_url": presigned_url}


# 全エージェント実行結果の最終通知先。Slackではなく必ずChatworkに送信すること
@tracer.capture_method
def send_chatwork_notification(params: dict) -> dict:
    message = params.get("message", "")
    report_url = params.get("report_url")

    if report_url:
        message = f"{message}\n\nレポート: {report_url}"

    room_id = _get_ssm_param("/bmao/chatwork/room_id")
    api_token = _get_ssm_param("/bmao/chatwork/api_token")

    url = f"https://api.chatwork.com/v2/rooms/{room_id}/messages"
    body = urllib.parse.urlencode({"body": message}).encode()
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "X-ChatWorkToken": api_token,
            "Content-Type": "application/x-www-form-urlencoded",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        response_body = json.loads(resp.read().decode())
        message_id = str(response_body.get("message_id", ""))

    metrics.add_metric(name="NotificationsSent", unit=MetricUnit.Count, value=1)
    logger.info(f"Chatwork通知送信完了: message_id={message_id}")
    return {"message_id": message_id, "status": "sent"}


@logger.inject_lambda_context
@tracer.capture_lambda_handler
@metrics.log_metrics
def lambda_handler(event: dict, context) -> dict:
    logger.info("レポーターAgent Action Group呼び出し", extra={"event": event})

    function_name = event.get("function", "")
    parameters = {p["name"]: p["value"] for p in event.get("parameters", [])}

    dispatch = {
        "generate_html_report": generate_html_report,
        "send_chatwork_notification": send_chatwork_notification,
    }

    if function_name not in dispatch:
        result = {"error": f"不明な関数: {function_name}"}
    else:
        result = dispatch[function_name](parameters)

    return {
        "messageVersion": "1.0",
        "response": {
            "actionGroup": event.get("actionGroup", ""),
            "function": function_name,
            "functionResponse": {
                "responseBody": {
                    "TEXT": {
                        "body": json.dumps(result, ensure_ascii=False, default=str)
                    }
                }
            },
        },
    }
