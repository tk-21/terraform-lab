"""
GitHubのPRにレビューコメントを投稿するモジュール
重複コメント防止機能付き（REVIEW_MARKERで既存コメントを検索・更新）
"""

from datetime import datetime, timezone, timedelta
from typing import Optional

from github import Github, GithubException

# コメントの識別マーカー（既存コメントの検索・更新に使用）
REVIEW_MARKER = "<!-- ansible-ai-reviewer -->"

# 重大度別の絵文字とラベル色
_SEVERITY_ICONS = {
    "CRITICAL": "🔴",
    "HIGH": "🟠",
    "MEDIUM": "🟡",
    "LOW": "🔵",
}

_RISK_LABELS = {
    "HIGH": ("ai-review: high-risk", "d73a4a"),
    "MEDIUM": ("ai-review: medium-risk", "e4e669"),
    "LOW": ("ai-review: approved", "0075ca"),
}


def post_review_comment(
    github_token: str,
    repo_owner: str,
    repo_name: str,
    pr_number: int,
    review_result: dict,
    playbook_filename: str,
) -> dict:
    """
    PRにAIレビューコメントを投稿する（既存コメントは更新して重複を防ぐ）

    処理フロー:
    1. 既存のREVIEW_MARKERを含むコメントを検索
    2. 存在すれば edit() で更新、なければ新規作成
    """
    g = Github(github_token)
    repo = g.get_repo(f"{repo_owner}/{repo_name}")
    pr = repo.get_pull(pr_number)

    comment_body = format_review_comment(review_result, playbook_filename)

    existing_comment = _find_existing_comment(pr)

    if existing_comment:
        existing_comment.edit(comment_body)
        return {"comment_url": existing_comment.html_url, "action": "updated"}
    else:
        new_comment = pr.create_issue_comment(comment_body)
        return {"comment_url": new_comment.html_url, "action": "created"}


def _find_existing_comment(pr) -> Optional[object]:
    """REVIEW_MARKERを含む既存コメントを返す（なければNone）"""
    for comment in pr.get_issue_comments():
        if REVIEW_MARKER in comment.body:
            return comment
    return None


def format_review_comment(review_result: dict, playbook_filename: str) -> str:
    """
    レビュー結果をMarkdown形式のコメントに変換する
    先頭にREVIEW_MARKERを含めることで更新時の検索に対応する
    """
    score: int = review_result.get("overall_score", 0)
    risk: str = review_result.get("estimated_risk_level", "UNKNOWN")
    summary: str = review_result.get("summary", "")
    issues: list = review_result.get("issues", [])
    recommendations: list = review_result.get("recommendations", [])
    positive_aspects: list = review_result.get("positive_aspects", [])

    # スコアに応じたバッジ色
    score_badge = _score_badge(score)

    jst = timezone(timedelta(hours=9))
    timestamp = datetime.now(jst).strftime("%Y-%m-%d %H:%M:%S JST")

    lines: list[str] = [
        REVIEW_MARKER,
        f"## 🤖 Ansible Playbook AI Review: `{playbook_filename}`",
        "",
        f"**総合スコア**: {score_badge} {score}/100 | **リスクレベル**: {_risk_icon(risk)} {risk}",
        "",
        "### 📊 サマリー",
        summary,
        "",
    ]

    # 良い点
    if positive_aspects:
        lines.append("### ✅ 良い点")
        for item in positive_aspects:
            lines.append(f"- {item}")
        lines.append("")

    # 問題一覧
    lines.append(f"### ⚠️ 検出された問題 ({len(issues)}件)")
    lines.append("")

    for severity in ("CRITICAL", "HIGH", "MEDIUM", "LOW"):
        severity_issues = [i for i in issues if i.get("severity") == severity]
        if not severity_issues:
            continue
        icon = _SEVERITY_ICONS.get(severity, "")
        lines.append(f"#### {icon} {severity} ({len(severity_issues)}件)")
        lines.append("")
        lines.append("| タスク | カテゴリ | 問題 | 改善提案 |")
        lines.append("|---|---|---|---|")
        for issue in severity_issues:
            task = issue.get("task_name") or "—"
            category = issue.get("category", "")
            desc = issue.get("description", "").replace("\n", " ")
            suggestion = issue.get("suggestion", "").replace("\n", " ")
            lines.append(f"| {task} | {category} | {desc} | {suggestion} |")
        lines.append("")

    # 全体的な改善提案
    if recommendations:
        lines.append("### 💡 全体的な改善提案")
        for rec in recommendations:
            lines.append(f"- {rec}")
        lines.append("")

    lines.extend([
        "---",
        "*🤖 このレビューはAmazon Bedrock (Claude Sonnet)によって生成されました*",
        f"*レビュー時刻: {timestamp}*",
    ])

    return "\n".join(lines)


def add_pr_labels(
    github_token: str,
    repo_owner: str,
    repo_name: str,
    pr_number: int,
    risk_level: str,
) -> None:
    """
    リスクレベルに応じてPRにラベルを付与する
    ラベルが存在しない場合は作成してから付与する
    """
    if risk_level not in _RISK_LABELS:
        return

    label_name, label_color = _RISK_LABELS[risk_level]

    g = Github(github_token)
    repo = g.get_repo(f"{repo_owner}/{repo_name}")
    pr = repo.get_pull(pr_number)

    # ラベルが存在しなければ作成
    try:
        repo.get_label(label_name)
    except GithubException:
        repo.create_label(name=label_name, color=label_color)

    # ai-review系の既存ラベルを一旦除去してから付与（重複防止）
    issue = repo.get_issue(pr_number)
    current_labels = [lbl.name for lbl in issue.labels if not lbl.name.startswith("ai-review:")]
    current_labels.append(label_name)
    issue.set_labels(*current_labels)


def _score_badge(score: int) -> str:
    """スコアに応じた絵文字を返す"""
    if score >= 80:
        return "🟢"
    if score >= 50:
        return "🟡"
    return "🔴"


def _risk_icon(risk: str) -> str:
    """リスクレベルに応じた絵文字を返す"""
    return {"HIGH": "🔴", "MEDIUM": "🟡", "LOW": "🟢"}.get(risk, "⚪")
