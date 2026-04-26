"""
GitHub APIクライアントモジュール
PyGithubライブラリを使用してPR作成・ブランチ操作を行う
"""

from datetime import datetime, timezone

import requests
from github import Github, GithubException


def create_drift_pr(
    github_token: str,
    repo_owner: str,
    repo_name: str,
    analysis_result: dict,
    base_branch: str = "main",
) -> dict:
    """
    ドリフト修復用のGitHub PRを作成する。
    ブランチ作成 → HCLコミット → PR作成の順に処理する。
    """
    severity = analysis_result.get("severity", "UNKNOWN")
    drift_summary = analysis_result.get("drift_summary", "")
    root_cause = analysis_result.get("root_cause", "")
    remediation_hcl = analysis_result.get("remediation_hcl", "")
    risk_assessment = analysis_result.get("risk_assessment", "")
    affected_resources = analysis_result.get("affected_resources", [])

    now = datetime.now(timezone.utc)
    date_str = now.strftime("%Y-%m-%d")
    timestamp_compact = now.strftime("%Y%m%dT%H%M%SZ")

    # ブランチ名: fix/drift-{YYYY-MM-DD}-{severity.lower()}
    branch_name = f"fix/drift-{date_str}-{severity.lower()}"

    g = Github(github_token)
    repo = g.get_repo(f"{repo_owner}/{repo_name}")

    # mainブランチのSHAからブランチを作成
    base_sha = repo.get_branch(base_branch).commit.sha
    repo.create_git_ref(ref=f"refs/heads/{branch_name}", sha=base_sha)

    # 修復HCLファイルをコミット
    hcl_file_path = f"terraform/drift-fixes/fix-{timestamp_compact}.tf"
    commit_message = f"fix: Terraform drift remediation - {severity} severity"
    repo.create_file(
        path=hcl_file_path,
        message=commit_message,
        content=remediation_hcl.encode("utf-8"),
        branch=branch_name,
    )

    # 影響リソースをMarkdownリスト形式に変換
    resources_list = "\n".join(f"- `{r}`" for r in affected_resources) or "- (不明)"

    # PR本文をMarkdown形式で構築
    pr_body = f"""## 🔍 ドリフト概要
{drift_summary}

## 🎯 影響リソース
{resources_list}

## 💡 原因分析
{root_cause}

## ⚠️ リスク評価
{risk_assessment}

## 🔧 修復手順
1. このPRのHCLを確認する
2. `terraform plan` で差分を確認する
3. 問題なければ `terraform apply` を実行する
4. 実環境との一致を確認する

## 📋 修復用HCL
```hcl
{remediation_hcl}
```

## ✅ レビュー観点
- このHCLを適用することで実環境と一致するか
- 他のリソースへの影響がないか
- terraform plan の実行確認

---
*このPRはIaC Drift Detectiveによって自動生成されました。必ず人間がレビューしてから適用してください。*
"""

    # タイトルは60文字で切り詰め（GitHub UI表示の可読性確保）
    summary_short = drift_summary[:60]
    pr_title = f"[Drift Fix] {severity} severity drift detected - {summary_short}"

    pr = repo.create_pull(
        title=pr_title,
        body=pr_body,
        head=branch_name,
        base=base_branch,
    )

    # ラベル付与（存在しない場合はスキップして処理を継続）
    labels_to_add = ["drift-fix", severity.lower()]
    for label_name in labels_to_add:
        try:
            label = repo.get_label(label_name)
            pr.add_to_labels(label)
        except GithubException:
            pass

    return {
        "pr_url": pr.html_url,
        "pr_number": pr.number,
        "branch_name": branch_name,
    }


def notify_chatwork(
    api_token: str,
    room_id: str,
    pr_url: str,
    analysis_result: dict,
) -> None:
    """
    ChatworkにPR作成を通知する。
    エラーは呼び出し元に伝播させる（呼び出し元でWARNINGとして扱う）。
    """
    severity = analysis_result.get("severity", "UNKNOWN")
    drift_summary = analysis_result.get("drift_summary", "")
    affected_resources = analysis_result.get("affected_resources", [])

    message = (
        f"[info][title]🚨 Terraformドリフト検知[/title]\n"
        f"重要度: {severity}\n"
        f"概要: {drift_summary}\n"
        f"修復PR: {pr_url}\n"
        f"影響リソース数: {len(affected_resources)}件\n"
        f"[/info]"
    )

    response = requests.post(
        f"https://api.chatwork.com/v2/rooms/{room_id}/messages",
        headers={"X-ChatWorkToken": api_token},
        data={"body": message},
        timeout=10,
    )
    response.raise_for_status()
