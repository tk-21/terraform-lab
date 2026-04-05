"""
report-generator Lambda

役割:
    4 エージェント + supervisor の結果を受け取り、
    HTML レポートを生成して S3 に保存する。
    DynamoDB の final_report_url を更新し、
    署名付き URL（7 日間有効）を返す。

入力（Step Functions から渡される）:
    {
        "session_id":       "uuid4",
        "input_type":       "terraform" | "architecture",
        "s3_key":           "reviews/{session_id}/{filename}",
        "agent_results":    [ security, cost, reliability, operations の結果 ],
        "supervisor_result": { tradeoffs, priority_actions, overall_score, executive_summary }
    }

出力:
    {
        "report_url":   "https://s3.../reports/{session_id}/report.html?...",
        "report_s3_key": "reports/{session_id}/report.html"
    }
"""

import json
import os
import logging
import html
from datetime import datetime, timezone, timedelta

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3", region_name="ap-northeast-1")
dynamodb = boto3.resource("dynamodb", region_name="ap-northeast-1")

TABLE_NAME = os.environ["DYNAMODB_TABLE_NAME"]
REPORTS_BUCKET_NAME = os.environ["REPORTS_BUCKET_NAME"]

# レポートの署名付き URL 有効期限: 7 日
REPORT_URL_EXPIRY_SECONDS = 7 * 24 * 3600

# エージェント表示名のマッピング
AGENT_DISPLAY_NAMES = {
    "security":    "セキュリティ",
    "cost":        "コスト",
    "reliability": "信頼性・可用性",
    "operations":  "運用性",
}


# =============================================================================
# スコアに応じた CSS クラスを返すヘルパー
# =============================================================================
def score_css_class(score: int) -> str:
    if score >= 80:
        return "score-excellent"
    if score >= 60:
        return "score-good"
    if score >= 40:
        return "score-warning"
    return "score-danger"


def severity_css_class(severity: str) -> str:
    return {"HIGH": "high", "MEDIUM": "medium", "LOW": "low"}.get(
        severity.upper(), "low"
    )


def severity_badge_class(severity: str) -> str:
    return {"HIGH": "badge-high", "MEDIUM": "badge-medium", "LOW": "badge-low"}.get(
        severity.upper(), "badge-low"
    )


def e(text: str) -> str:
    """HTML エスケープの短縮形"""
    return html.escape(str(text))


# =============================================================================
# HTML レポート生成
# =============================================================================
def generate_html_report(
    session_id: str,
    input_type: str,
    s3_key: str,
    agent_results: list,
    supervisor_result: dict,
) -> str:
    """
    レビュー結果から HTML レポートを生成する

    Args:
        session_id:       セッション ID
        input_type:       "terraform" | "architecture"
        s3_key:           S3 オブジェクトキー（レビュー対象ファイル）
        agent_results:    4 エージェントの結果リスト
        supervisor_result: supervisor の統合結果

    Returns:
        HTML 文字列
    """
    now = datetime.now(timezone(timedelta(hours=9)))  # JST
    generated_at = now.strftime("%Y年%m月%d日 %H:%M JST")

    overall_score = supervisor_result.get("overall_score", {})
    total = overall_score.get("total", 0)
    executive_summary = supervisor_result.get("executive_summary", "")
    priority_actions = supervisor_result.get("priority_actions", [])
    tradeoffs = supervisor_result.get("tradeoffs", [])

    input_type_label = "Terraform コード" if input_type == "terraform" else "アーキテクチャ構成"
    filename = s3_key.split("/")[-1] if s3_key else "不明"

    # ---------- ヘッダー ----------
    header_html = f"""
    <header>
      <div class="container">
        <div class="header-top">
          <div>
            <h1>🔍 AWS インフラレビューレポート</h1>
            <p class="meta">
              セッション ID: <code>{e(session_id)}</code> ｜
              対象: {e(input_type_label)}（{e(filename)}）｜
              生成日時: {generated_at}
            </p>
          </div>
          <div class="total-score-box">
            <div class="total-score-label">総合スコア</div>
            <div class="total-score {score_css_class(total)}">{total}</div>
            <div class="total-score-max">/100</div>
          </div>
        </div>
      </div>
    </header>"""

    # ---------- 総合スコア ----------
    score_items = []
    for agent_key, display_name in AGENT_DISPLAY_NAMES.items():
        score = overall_score.get(agent_key, 0)
        css = score_css_class(score)
        score_items.append(f"""
        <div class="score-box">
          <div class="score-circle {css}">{score}</div>
          <div class="score-label">{display_name}</div>
        </div>""")

    scores_html = f"""
    <div class="card">
      <h2>各エージェントスコア</h2>
      <div class="scores-grid">{''.join(score_items)}
      </div>
    </div>"""

    # ---------- エグゼクティブサマリー ----------
    summary_html = f"""
    <div class="card">
      <h2>エグゼクティブサマリー</h2>
      <p class="executive-summary">{e(executive_summary)}</p>
    </div>"""

    # ---------- 優先対応アクション ----------
    action_items = []
    for action in priority_actions[:10]:
        rank = action.get("rank", "?")
        act = e(action.get("action", ""))
        source = e(action.get("source_agent", ""))
        severity = action.get("severity", "LOW")
        badge_cls = severity_badge_class(severity)
        action_items.append(f"""
        <div class="priority-item">
          <div class="priority-rank">#{rank}</div>
          <div class="priority-body">
            <div class="priority-action">{act}</div>
            <div class="priority-meta">
              <span class="badge {badge_cls}">{e(severity)}</span>
              <span class="source-agent">by {source}</span>
            </div>
          </div>
        </div>""")

    actions_html = f"""
    <div class="card">
      <h2>優先対応アクション TOP {len(action_items)}</h2>
      {''.join(action_items) if action_items else '<p class="empty">指摘事項なし</p>'}
    </div>"""

    # ---------- トレードオフ ----------
    tradeoff_items = []
    for t in tradeoffs:
        description = e(t.get("description", ""))
        agents = " ↔ ".join(e(a) for a in t.get("agents", []))
        recommendation = e(t.get("recommendation", ""))
        tradeoff_items.append(f"""
        <div class="tradeoff-card">
          <div class="tradeoff-agents">対立する観点: {agents}</div>
          <div class="tradeoff-description">{description}</div>
          <div class="tradeoff-recommendation">
            <strong>推奨:</strong> {recommendation}
          </div>
        </div>""")

    tradeoffs_html = f"""
    <div class="card">
      <h2>トレードオフ分析</h2>
      {''.join(tradeoff_items) if tradeoff_items else '<p class="empty">重大なトレードオフなし</p>'}
    </div>"""

    # ---------- エージェント別詳細 ----------
    agent_sections = []
    for result in agent_results:
        agent_key = result.get("agent", "unknown")
        display_name = AGENT_DISPLAY_NAMES.get(agent_key, agent_key)
        score = result.get("score", 0)
        summary = e(result.get("summary", ""))
        findings = result.get("findings", [])

        finding_items = []
        for f in findings:
            severity = f.get("severity", "LOW")
            sev_css = severity_css_class(severity)
            badge_cls = severity_badge_class(severity)
            resource = e(f.get("resource", ""))
            issue = e(f.get("issue", ""))
            recommendation = e(f.get("recommendation", ""))

            finding_items.append(f"""
            <div class="finding {sev_css}">
              <div class="finding-header">
                <span class="badge {badge_cls}">{e(severity)}</span>
                <span class="resource">{resource}</span>
              </div>
              <div class="issue">{issue}</div>
              {'<div class="recommendation"><strong>推奨:</strong> ' + recommendation + '</div>' if recommendation else ''}
            </div>""")

        css = score_css_class(score)
        agent_sections.append(f"""
        <div class="agent-section">
          <div class="agent-header">
            <span class="agent-name">{display_name}</span>
            <div class="agent-score">
              <div class="score-circle-sm {css}">{score}</div>
            </div>
          </div>
          <p class="agent-summary">{summary}</p>
          {''.join(finding_items) if finding_items else '<p class="empty">指摘事項なし</p>'}
        </div>""")

    details_html = f"""
    <div class="card">
      <h2>エージェント別詳細レビュー</h2>
      {''.join(agent_sections)}
    </div>"""

    # ---------- CSS ----------
    css = """
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
           background: #f5f7fa; color: #2c3e50; line-height: 1.7; font-size: 15px; }
    .container { max-width: 1100px; margin: 0 auto; padding: 24px 16px; }
    code { font-family: 'SFMono-Regular', Consolas, monospace; font-size: 13px;
           background: rgba(255,255,255,0.2); padding: 2px 6px; border-radius: 4px; }
    header { background: linear-gradient(135deg, #1a252f 0%, #2c3e50 50%, #e67e22 100%);
             color: white; padding: 32px 0; margin-bottom: 24px; }
    .header-top { display: flex; justify-content: space-between; align-items: center; gap: 20px; flex-wrap: wrap; }
    header h1 { font-size: 26px; margin-bottom: 8px; }
    header .meta { opacity: 0.8; font-size: 13px; }
    .total-score-box { text-align: center; background: rgba(255,255,255,0.15);
                       border-radius: 12px; padding: 16px 24px; }
    .total-score-label { font-size: 13px; opacity: 0.85; }
    .total-score { font-size: 52px; font-weight: 800; line-height: 1; }
    .total-score-max { font-size: 14px; opacity: 0.7; }
    .total-score.score-excellent { color: #2ecc71; }
    .total-score.score-good { color: #74b9ff; }
    .total-score.score-warning { color: #fdcb6e; }
    .total-score.score-danger { color: #ff7675; }
    .card { background: white; border-radius: 10px; padding: 24px; margin-bottom: 20px;
            box-shadow: 0 2px 12px rgba(0,0,0,0.07); }
    .card h2 { font-size: 18px; margin-bottom: 16px; padding-bottom: 10px;
               border-bottom: 3px solid #e67e22; color: #2c3e50; }
    .scores-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 16px; }
    .score-box { text-align: center; padding: 20px; border-radius: 8px; background: #f8f9fa;
                 border: 1px solid #ecf0f1; }
    .score-circle { width: 72px; height: 72px; border-radius: 50%; display: flex; align-items: center;
                    justify-content: center; margin: 0 auto 10px; font-size: 22px; font-weight: 800; color: white; }
    .score-circle-sm { width: 44px; height: 44px; border-radius: 50%; display: flex; align-items: center;
                       justify-content: center; font-size: 16px; font-weight: 700; color: white; }
    .score-excellent { background: #27ae60; }
    .score-good { background: #2980b9; }
    .score-warning { background: #e67e22; }
    .score-danger { background: #c0392b; }
    .score-label { font-size: 13px; color: #7f8c8d; font-weight: 600; }
    .executive-summary { font-size: 16px; line-height: 1.8; color: #34495e;
                         border-left: 4px solid #e67e22; padding-left: 16px; }
    .badge { display: inline-block; padding: 2px 10px; border-radius: 20px; font-size: 11px; font-weight: 700; }
    .badge-high { background: #fde8e8; color: #c0392b; }
    .badge-medium { background: #fef3e2; color: #e67e22; }
    .badge-low { background: #eafaf1; color: #27ae60; }
    .priority-item { display: flex; gap: 16px; padding: 14px; border-radius: 8px; margin: 8px 0;
                     background: #fafafa; border: 1px solid #ecf0f1; align-items: flex-start; }
    .priority-rank { font-size: 22px; font-weight: 800; color: #e67e22; min-width: 36px; text-align: center; }
    .priority-action { font-weight: 600; margin-bottom: 6px; }
    .priority-meta { display: flex; gap: 8px; align-items: center; }
    .source-agent { font-size: 12px; color: #95a5a6; }
    .tradeoff-card { background: #fff8f0; border: 1px solid #f0a500; border-radius: 8px;
                     padding: 16px; margin: 10px 0; }
    .tradeoff-agents { font-size: 12px; font-weight: 600; color: #e67e22; margin-bottom: 6px; }
    .tradeoff-description { font-weight: 600; color: #2c3e50; }
    .tradeoff-recommendation { margin-top: 10px; padding: 10px; background: white; border-radius: 6px;
                                font-size: 14px; color: #555; }
    .agent-section { border: 1px solid #ecf0f1; border-radius: 8px; padding: 16px; margin: 14px 0; }
    .agent-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px; }
    .agent-name { font-size: 17px; font-weight: 700; color: #2c3e50; }
    .agent-summary { font-size: 14px; color: #7f8c8d; margin-bottom: 12px;
                     padding: 10px; background: #f8f9fa; border-radius: 6px; }
    .finding { border-left: 4px solid #bdc3c7; padding: 12px 16px; margin: 8px 0;
               background: #fdfdfd; border-radius: 0 6px 6px 0; }
    .finding.high { border-color: #c0392b; background: #fff9f9; }
    .finding.medium { border-color: #e67e22; background: #fffaf5; }
    .finding.low { border-color: #27ae60; background: #f9fffe; }
    .finding-header { display: flex; gap: 8px; align-items: center; margin-bottom: 6px; }
    .finding .resource { font-family: 'SFMono-Regular', monospace; font-size: 12px; color: #7f8c8d; }
    .finding .issue { font-weight: 600; color: #2c3e50; }
    .finding .recommendation { margin-top: 8px; font-size: 14px; color: #555;
                                background: white; padding: 8px; border-radius: 4px; }
    .empty { color: #95a5a6; font-style: italic; text-align: center; padding: 16px; }
    footer { text-align: center; padding: 24px; color: #95a5a6; font-size: 13px; }
    footer a { color: #e67e22; text-decoration: none; }
    """

    # ---------- 全体組み立て ----------
    return f"""<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>AWS インフラレビューレポート - {e(session_id[:8])}...</title>
  <style>{css}</style>
</head>
<body>

{header_html}

<div class="container">
{scores_html}
{summary_html}
{actions_html}
{tradeoffs_html}
{details_html}

  <footer>
    <p>AWS インフラレビュー AI by <a href="#">aws-infra-review-ai</a> ｜
       セッション <code>{e(session_id)}</code> ｜ {generated_at}</p>
  </footer>
</div>

</body>
</html>"""


# =============================================================================
# S3 アップロード + 署名付き URL 生成
# =============================================================================
def upload_report(session_id: str, html_content: str) -> tuple[str, str]:
    """
    HTML レポートを S3 にアップロードし、署名付き URL を返す

    Args:
        session_id:   セッション ID
        html_content: HTML 文字列

    Returns:
        (s3_key, presigned_url) のタプル
    """
    s3_key = f"reports/{session_id}/report.html"

    s3.put_object(
        Bucket=REPORTS_BUCKET_NAME,
        Key=s3_key,
        Body=html_content.encode("utf-8"),
        ContentType="text/html; charset=utf-8",
        ContentDisposition=f'inline; filename="review-report-{session_id[:8]}.html"',
    )
    logger.info(f"S3 アップロード完了: s3://{REPORTS_BUCKET_NAME}/{s3_key}")

    presigned_url = s3.generate_presigned_url(
        "get_object",
        Params={"Bucket": REPORTS_BUCKET_NAME, "Key": s3_key},
        ExpiresIn=REPORT_URL_EXPIRY_SECONDS,
    )
    return s3_key, presigned_url


def update_report_url(session_id: str, report_url: str) -> None:
    """
    DynamoDB の final_report_url を更新する

    Args:
        session_id:  セッション ID
        report_url:  レポートの署名付き URL
    """
    table = dynamodb.Table(TABLE_NAME)
    table.update_item(
        Key={"session_id": session_id},
        UpdateExpression="SET final_report_url = :url",
        ExpressionAttributeValues={":url": report_url},
    )
    logger.info(f"DynamoDB 更新完了（final_report_url）: session_id={session_id}")


# =============================================================================
# Lambda エントリーポイント
# =============================================================================
def lambda_handler(event: dict, context) -> dict:
    """
    Step Functions の GenerateReport ステートから呼び出される。

    Args:
        event: {
            "session_id":        str,
            "input_type":        str,
            "s3_key":            str,
            "agent_results":     list,
            "supervisor_result": dict
        }

    Returns:
        { "report_url": str, "report_s3_key": str }
    """
    logger.info(f"report-generator 開始: session_id={event.get('session_id')}")

    session_id = event.get("session_id", "")
    input_type = event.get("input_type", "terraform")
    s3_key = event.get("s3_key", "")
    agent_results = event.get("agent_results", [])
    supervisor_result = event.get("supervisor_result", {})

    if not session_id:
        raise ValueError("session_id が空です")

    try:
        # HTML レポートを生成
        html_content = generate_html_report(
            session_id, input_type, s3_key, agent_results, supervisor_result
        )
        logger.info(f"HTML 生成完了: {len(html_content)} 文字")

        # S3 にアップロードして署名付き URL を取得
        report_s3_key, report_url = upload_report(session_id, html_content)

        # DynamoDB に URL を保存
        if session_id:
            update_report_url(session_id, report_url)

        logger.info(
            f"report-generator 完了: session_id={session_id}, "
            f"s3_key={report_s3_key}"
        )

        return {
            "report_url":    report_url,
            "report_s3_key": report_s3_key,
        }

    except ClientError as e:
        error_code = e.response["Error"]["Code"]
        logger.error(f"AWS API エラー: {error_code} - {str(e)}")
        raise
