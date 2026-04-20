"""
report-formatter Lambda
ポストモーテムJSONをHTMLレポートに変換してS3に保存し、presigned URLを返す。

設計意図:
- インラインCSSでスタンドアロンHTML（外部依存なし・オフライン閲覧可能）
- presigned URLは7日間有効（notifier Lambdaに渡してChatwork通知）
- レスポンシブデザインでモバイルからも閲覧可能
"""

import os
from datetime import datetime, timezone

import boto3
from aws_lambda_powertools import Logger, Tracer
from aws_lambda_powertools.utilities.typing import LambdaContext

logger = Logger()
tracer = Tracer()

s3_client = boto3.client("s3")

S3_BUCKET_NAME = os.environ["S3_BUCKET_NAME"]
PRESIGNED_URL_EXPIRY = 7 * 24 * 3600  # 7日間


@logger.inject_lambda_context
@tracer.capture_lambda_handler
def handler(event: dict, context: LambdaContext) -> dict:
    experiment_id = event["experiment_id"]
    experiment_type = event["experiment_type"]
    start_time = event["start_time"]
    end_time = event["end_time"]
    postmortem = event["postmortem"]

    logger.info("レポート生成開始", experiment_id=experiment_id)

    html_content = _generate_html_report(
        experiment_id=experiment_id,
        experiment_type=experiment_type,
        start_time=start_time,
        end_time=end_time,
        postmortem=postmortem,
    )

    s3_key = f"reports/{experiment_type}/{experiment_id}/postmortem.html"
    s3_client.put_object(
        Bucket=S3_BUCKET_NAME,
        Key=s3_key,
        Body=html_content.encode("utf-8"),
        ContentType="text/html; charset=utf-8",
    )

    presigned_url = s3_client.generate_presigned_url(
        "get_object",
        Params={"Bucket": S3_BUCKET_NAME, "Key": s3_key},
        ExpiresIn=PRESIGNED_URL_EXPIRY,
    )

    logger.info("レポート生成完了", experiment_id=experiment_id, s3_key=s3_key)

    return {
        "experiment_id": experiment_id,
        "experiment_type": experiment_type,
        "start_time": start_time,
        "end_time": end_time,
        "postmortem": postmortem,
        "report_s3_key": s3_key,
        "presigned_url": presigned_url,
        "report_generated_at": datetime.now(timezone.utc).isoformat(),
    }


def _generate_html_report(
    experiment_id: str,
    experiment_type: str,
    start_time: str,
    end_time: str,
    postmortem: dict,
) -> str:
    """ポストモーテムJSONからスタンドアロンHTMLレポートを生成する"""
    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

    action_items_html = ""
    for item in postmortem.get("action_items", []):
        priority = item.get("priority", "medium")
        priority_color = {
            "high": "#e74c3c",
            "medium": "#f39c12",
            "low": "#27ae60",
        }.get(priority, "#95a5a6")
        action_items_html += f"""
        <tr>
          <td><span style="background:{priority_color};color:white;padding:2px 8px;border-radius:3px;font-size:12px;font-weight:bold">{priority.upper()}</span></td>
          <td>{item.get("task", "")}</td>
          <td>{item.get("owner", "")}</td>
        </tr>"""

    timeline_html = ""
    for entry in postmortem.get("timeline", []):
        timeline_html += f"""
        <tr>
          <td style="white-space:nowrap;font-family:monospace;font-weight:bold;color:#2c3e50">{entry.get("time", "")}</td>
          <td>{entry.get("event", "")}</td>
        </tr>"""

    prevention_html = ""
    for prev in postmortem.get("prevention", []):
        code_example = prev.get("code_example", "")
        code_block = ""
        if code_example:
            # コードブロックはシンタックスハイライト風インラインCSS
            code_block = (
                f'<pre style="background:#2d2d2d;color:#f8f8f2;padding:15px;'
                f'border-radius:5px;overflow-x:auto;font-size:13px;line-height:1.5;'
                f'margin-top:10px"><code>{_escape_html(code_example)}</code></pre>'
            )
        prevention_html += f"""
        <div style="background:#f8f9fa;border-left:4px solid #3498db;padding:15px;margin:10px 0;border-radius:0 5px 5px 0">
          <h4 style="margin:0 0 8px 0;color:#2c3e50">{prev.get("title", "")}</h4>
          <p style="margin:0 0 10px 0;color:#555;line-height:1.6">{prev.get("description", "")}</p>
          {code_block}
        </div>"""

    impact = postmortem.get("impact", {})
    affected_services = impact.get("affected_services", [])
    services_text = "、".join(affected_services) if affected_services else "なし"

    return f"""<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>ポストモーテム - {experiment_id}</title>
  <style>
    * {{ box-sizing: border-box; }}
    body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Helvetica Neue', sans-serif; margin: 0; padding: 20px; background: #f0f2f5; color: #333; line-height: 1.6; }}
    .container {{ max-width: 960px; margin: 0 auto; }}
    .header {{ background: linear-gradient(135deg, #1a252f 0%, #2980b9 100%); color: white; padding: 32px; border-radius: 10px; margin-bottom: 24px; box-shadow: 0 4px 12px rgba(0,0,0,0.15); }}
    .header h1 {{ margin: 0 0 12px 0; font-size: 26px; font-weight: 700; }}
    .header .badge {{ display: inline-block; background: rgba(255,255,255,0.2); color: white; padding: 3px 10px; border-radius: 12px; font-size: 13px; margin-right: 8px; }}
    .header .meta {{ font-size: 13px; opacity: 0.85; margin-top: 10px; }}
    .card {{ background: white; border-radius: 10px; padding: 28px; margin-bottom: 20px; box-shadow: 0 2px 8px rgba(0,0,0,0.08); }}
    .card h2 {{ margin: 0 0 18px 0; color: #1a252f; font-size: 18px; font-weight: 700; padding-bottom: 10px; border-bottom: 3px solid #3498db; display: flex; align-items: center; gap: 8px; }}
    .summary {{ font-size: 16px; line-height: 1.8; color: #444; }}
    .impact-grid {{ display: grid; grid-template-columns: repeat(3, 1fr); gap: 16px; }}
    .impact-item {{ background: linear-gradient(135deg, #f8f9fa, #fff); border: 1px solid #e9ecef; border-radius: 8px; padding: 20px; text-align: center; }}
    .impact-item .value {{ font-size: 32px; font-weight: 800; color: #e74c3c; line-height: 1; }}
    .impact-item .label {{ font-size: 12px; color: #6c757d; margin-top: 6px; font-weight: 500; }}
    .impact-item .detail {{ font-size: 13px; color: #555; margin-top: 8px; }}
    table {{ width: 100%; border-collapse: collapse; font-size: 14px; }}
    th {{ background: #f8f9fa; padding: 12px 14px; text-align: left; font-size: 12px; font-weight: 700; color: #6c757d; text-transform: uppercase; letter-spacing: 0.05em; border-bottom: 2px solid #dee2e6; }}
    td {{ padding: 12px 14px; border-bottom: 1px solid #f0f0f0; vertical-align: top; }}
    tr:last-child td {{ border-bottom: none; }}
    .root-cause {{ background: #fff8e1; border: 1px solid #ffc107; border-radius: 8px; padding: 20px; line-height: 1.8; color: #444; }}
    .footer {{ text-align: center; color: #adb5bd; font-size: 12px; padding: 24px; }}
    .footer a {{ color: #6c757d; text-decoration: none; }}
    @media (max-width: 640px) {{
      .impact-grid {{ grid-template-columns: 1fr; }}
      body {{ padding: 12px; }}
      .header {{ padding: 20px; }}
      .card {{ padding: 16px; }}
    }}
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <h1>EKS障害ポストモーテム</h1>
      <div>
        <span class="badge">{experiment_type}</span>
        <span class="badge">{experiment_id}</span>
      </div>
      <div class="meta">
        障害期間: {start_time} 〜 {end_time}<br>
        レポート生成: {generated_at}
      </div>
    </div>

    <div class="card">
      <h2>📋 概要</h2>
      <div class="summary">{postmortem.get("summary", "")}</div>
    </div>

    <div class="card">
      <h2>💥 影響範囲</h2>
      <div class="impact-grid">
        <div class="impact-item">
          <div class="value">{impact.get("duration_minutes", 0)}</div>
          <div class="label">継続時間（分）</div>
        </div>
        <div class="impact-item">
          <div class="value">{impact.get("affected_pods", 0)}</div>
          <div class="label">影響Pod数</div>
        </div>
        <div class="impact-item">
          <div class="value">{len(affected_services)}</div>
          <div class="label">影響サービス数</div>
          <div class="detail">{services_text}</div>
        </div>
      </div>
    </div>

    <div class="card">
      <h2>⏱️ タイムライン</h2>
      <table>
        <thead><tr><th>時刻</th><th>イベント</th></tr></thead>
        <tbody>{timeline_html}</tbody>
      </table>
    </div>

    <div class="card">
      <h2>🔍 根本原因</h2>
      <div class="root-cause">{postmortem.get("root_cause", "")}</div>
    </div>

    <div class="card">
      <h2>🛡️ 再発防止策</h2>
      {prevention_html}
    </div>

    <div class="card">
      <h2>✅ アクションアイテム</h2>
      <table>
        <thead><tr><th>優先度</th><th>タスク</th><th>担当チーム</th></tr></thead>
        <tbody>{action_items_html}</tbody>
      </table>
    </div>

    <div class="footer">
      Generated by <strong>Amazon Bedrock Claude Sonnet 3.5</strong> | eks-chaos-postmortem-generator
    </div>
  </div>
</body>
</html>"""


def _escape_html(text: str) -> str:
    """HTMLエスケープ（コードブロック内でのXSS防止）"""
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )
