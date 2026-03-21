"""
HTML レポート整形 Lambda

概要:
    ai-reporter の出力を受け取り、月次コストレポートを HTML 形式に整形して S3 に保存する。
    HTML は標準ライブラリのみで生成（外部テンプレートエンジン不使用）。
"""

import json
import logging
import os
from datetime import datetime, timezone

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REPORT_BUCKET_NAME = os.environ["REPORT_BUCKET_NAME"]
DYNAMODB_TABLE_NAME = os.environ["DYNAMODB_TABLE_NAME"]
ENVIRONMENT = os.environ.get("ENVIRONMENT", "dev")
PROJECT_NAME = os.environ.get("PROJECT_NAME", "bedrock-finops-automation")

# 重要度別の色定義
SEVERITY_COLORS = {
    "HIGH":                "#dc2626",  # 赤
    "MEDIUM":              "#d97706",  # オレンジ
    "LOW":                 "#2563eb",  # 青
    "CONCENTRATION_HIGH":  "#d97706",
    "NEW_SERVICE":         "#2563eb",
}

RISK_LEVEL_COLORS = {
    "HIGH":    "#dc2626",
    "MEDIUM":  "#d97706",
    "LOW":     "#16a34a",
    "UNKNOWN": "#6b7280",
}


# ============================================================
# HTML 生成
# ============================================================

def _escape(text: str) -> str:
    """XSS 対策の HTML エスケープ。"""
    return (
        str(text)
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def build_anomaly_section(anomalies: list[dict]) -> str:
    """異常検知セクションの HTML を生成する。"""
    if not anomalies:
        return '<p style="color:#16a34a;">異常は検知されませんでした。</p>'

    rows = ""
    for a in anomalies:
        color = SEVERITY_COLORS.get(a.get("severity", ""), "#6b7280")
        rows += f"""
        <tr>
          <td><span style="color:{color};font-weight:bold;">{_escape(a.get("severity",""))}</span></td>
          <td>{_escape(a.get("type",""))}</td>
          <td>{_escape(a.get("description",""))}</td>
        </tr>"""

    return f"""
    <table>
      <thead>
        <tr><th>重要度</th><th>種別</th><th>内容</th></tr>
      </thead>
      <tbody>{rows}
      </tbody>
    </table>"""


def build_services_section(services: list[dict], total_cost: float) -> str:
    """サービス別コスト表の HTML を生成する。"""
    rows = ""
    for i, svc in enumerate(services, 1):
        pct = (svc["cost"] / total_cost * 100) if total_cost > 0 else 0
        bar_width = min(int(pct), 100)
        rows += f"""
        <tr>
          <td style="text-align:center;">{i}</td>
          <td>{_escape(svc["service"])}</td>
          <td style="text-align:right;">${svc["cost"]:.2f}</td>
          <td style="text-align:right;">{pct:.1f}%</td>
          <td>
            <div style="background:#3b82f6;height:12px;width:{bar_width}%;border-radius:2px;"></div>
          </td>
        </tr>"""

    return f"""
    <table>
      <thead>
        <tr><th>#</th><th>サービス</th><th>コスト</th><th>割合</th><th>バー</th></tr>
      </thead>
      <tbody>{rows}
      </tbody>
    </table>"""


def build_ai_section(ai_report: dict) -> str:
    """AI 所見セクションの HTML を生成する。"""
    risk_level = ai_report.get("risk_level", "UNKNOWN")
    risk_color = RISK_LEVEL_COLORS.get(risk_level, "#6b7280")

    highlights_html = "".join(
        [f"<li>{_escape(h)}</li>" for h in ai_report.get("highlights", [])]
    )
    recommendations_html = "".join(
        [f"<li>{_escape(r)}</li>" for r in ai_report.get("recommendations", [])]
    )

    return f"""
    <div style="margin-bottom:16px;">
      <span style="background:{risk_color};color:white;padding:4px 12px;border-radius:4px;font-weight:bold;">
        リスクレベル: {_escape(risk_level)}
      </span>
    </div>
    <p>{_escape(ai_report.get("summary", ""))}</p>
    <h3>注目ポイント</h3>
    <ul>{highlights_html}</ul>
    <h3>改善提案</h3>
    <ul>{recommendations_html}</ul>"""


def generate_html(event: dict) -> str:
    """レポート全体の HTML を生成する。"""
    report_date = event["report_date"]
    current = event["current_month"]
    prev = event["prev_month"]
    anomalies = event.get("anomalies", [])
    ai_report = event.get("ai_report", {})

    current_total = current["total_cost"]
    prev_total = prev["total_cost"]

    if prev_total > 0.01:
        change_pct = ((current_total - prev_total) / prev_total) * 100
        change_str = f"{change_pct:+.1f}%"
        change_color = "#dc2626" if change_pct > 20 else "#16a34a" if change_pct <= 0 else "#d97706"
    else:
        change_str = "N/A"
        change_color = "#6b7280"

    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    return f"""<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>AWS FinOps レポート {_escape(report_date)}</title>
  <style>
    body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
           max-width: 960px; margin: 0 auto; padding: 24px; color: #1f2937; background: #f9fafb; }}
    h1 {{ color: #111827; border-bottom: 2px solid #3b82f6; padding-bottom: 8px; }}
    h2 {{ color: #374151; margin-top: 32px; }}
    h3 {{ color: #4b5563; }}
    .card {{ background: white; border-radius: 8px; padding: 20px; margin-bottom: 20px;
             box-shadow: 0 1px 3px rgba(0,0,0,0.1); }}
    .metrics {{ display: flex; gap: 16px; flex-wrap: wrap; }}
    .metric {{ background: white; border-radius: 8px; padding: 16px 24px; flex: 1; min-width: 160px;
               box-shadow: 0 1px 3px rgba(0,0,0,0.1); text-align: center; }}
    .metric-value {{ font-size: 2em; font-weight: bold; color: #1d4ed8; }}
    .metric-label {{ color: #6b7280; font-size: 0.9em; margin-top: 4px; }}
    table {{ width: 100%; border-collapse: collapse; }}
    th {{ background: #f3f4f6; padding: 10px 12px; text-align: left; font-weight: 600; }}
    td {{ padding: 8px 12px; border-bottom: 1px solid #e5e7eb; }}
    tr:last-child td {{ border-bottom: none; }}
    ul {{ padding-left: 20px; line-height: 1.8; }}
    .footer {{ color: #9ca3af; font-size: 0.85em; text-align: center; margin-top: 32px; }}
  </style>
</head>
<body>
  <h1>AWS FinOps 月次コストレポート</h1>
  <p style="color:#6b7280;">対象月: <strong>{_escape(report_date)}</strong> &nbsp;|&nbsp; 生成日時: {_escape(generated_at)}</p>

  <h2>コスト概要</h2>
  <div class="metrics">
    <div class="metric">
      <div class="metric-value">${current_total:.2f}</div>
      <div class="metric-label">当月合計コスト</div>
    </div>
    <div class="metric">
      <div class="metric-value">${prev_total:.2f}</div>
      <div class="metric-label">前月合計コスト</div>
    </div>
    <div class="metric">
      <div class="metric-value" style="color:{change_color};">{_escape(change_str)}</div>
      <div class="metric-label">前月比</div>
    </div>
    <div class="metric">
      <div class="metric-value">{len(anomalies)}</div>
      <div class="metric-label">異常検知件数</div>
    </div>
  </div>

  <h2>サービス別コスト内訳（上位10件）</h2>
  <div class="card">
    {build_services_section(current.get("top_services", []), current_total)}
  </div>

  <h2>異常検知結果</h2>
  <div class="card">
    {build_anomaly_section(anomalies)}
  </div>

  <h2>AI 所見・改善提案</h2>
  <div class="card">
    {build_ai_section(ai_report)}
  </div>

  <p class="footer">
    Generated by {_escape(PROJECT_NAME)} ({_escape(ENVIRONMENT)}) &nbsp;|&nbsp;
    Powered by Amazon Bedrock（Claude 3 Haiku）
  </p>
</body>
</html>"""


# ============================================================
# S3 / DynamoDB 操作
# ============================================================

def save_html_to_s3(report_date: str, html: str) -> str:
    """HTML レポートを S3 に保存し、S3 キーを返す。"""
    s3 = boto3.client("s3")
    s3_key = f"html/{report_date}/report.html"

    s3.put_object(
        Bucket=REPORT_BUCKET_NAME,
        Key=s3_key,
        Body=html.encode("utf-8"),
        ContentType="text/html; charset=utf-8",
    )
    logger.info(f"Saved HTML report to s3://{REPORT_BUCKET_NAME}/{s3_key}")
    return s3_key


def generate_presigned_url(s3_key: str, expires_in: int = 604800) -> str:
    """
    S3 オブジェクトの署名付き URL を生成する。

    デフォルト有効期限: 7 日間（604800 秒）
    Chatwork 通知に含めて受信者がブラウザで閲覧できるようにする。
    """
    s3 = boto3.client("s3")
    url = s3.generate_presigned_url(
        "get_object",
        Params={"Bucket": REPORT_BUCKET_NAME, "Key": s3_key},
        ExpiresIn=expires_in,
    )
    return url


def update_dynamodb_status(report_id: str, report_date: str, html_s3_key: str) -> None:
    dynamodb = boto3.resource("dynamodb")
    table = dynamodb.Table(DYNAMODB_TABLE_NAME)

    table.update_item(
        Key={"report_id": report_id, "report_date": report_date},
        UpdateExpression="SET #s = :status, html_s3_key = :key, updated_at = :ts",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":status": "html_generated",
            ":key": html_s3_key,
            ":ts": datetime.now(timezone.utc).isoformat(),
        },
    )


# ============================================================
# Lambda ハンドラ
# ============================================================

def handler(event: dict, context) -> dict:
    """
    Lambda エントリポイント。

    Args:
        event: ai-reporter Lambda の返り値

    Returns:
        event に html_report を追加した dict（chatwork-notifier への入力）
    """
    logger.info(f"Generating HTML report for: {event.get('report_id')}")

    report_id = event["report_id"]
    report_date = event["report_date"]

    # HTML 生成 → S3 保存
    html = generate_html(event)
    html_s3_key = save_html_to_s3(report_date, html)

    # 署名付き URL 生成（7日間有効）
    presigned_url = generate_presigned_url(html_s3_key)

    update_dynamodb_status(report_id, report_date, html_s3_key)

    logger.info(f"HTML report generated: {html_s3_key}")

    return {
        **event,
        "html_report": {
            "s3_key": html_s3_key,
            "presigned_url": presigned_url,
        },
    }
