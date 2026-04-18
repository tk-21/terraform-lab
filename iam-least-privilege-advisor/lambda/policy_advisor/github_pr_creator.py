"""
GithubPrCreator モジュール

GitHub REST API を使用して IAM 最小権限化の Terraform PR を自動作成する。
GitHub API エラーは raise して Lambda エラーとして記録する（PR 未作成のまま終了させない）。
"""

import base64
import json
import logging
import urllib.error
import urllib.request
from datetime import datetime, timezone, timedelta

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger(__name__)

JST = timezone(timedelta(hours=9))
GITHUB_API_BASE = "https://api.github.com"
ROLE_NAME_MAX_LEN = 20


class GithubPrCreator:
    """GitHub REST API で Terraform PR を作成するクライアント。"""

    def __init__(
        self,
        token_secret_arn: str,
        owner: str,
        repo: str,
        secrets_client=None,
    ):
        """
        初期化。

        Args:
            token_secret_arn: GitHub Token を格納した Secrets Manager シークレットの ARN
            owner: GitHub リポジトリオーナー（ユーザー名または組織名）
            repo: GitHub リポジトリ名
            secrets_client: boto3 secretsmanager クライアント（省略時は自動生成）
        """
        self._token_secret_arn = token_secret_arn
        self._owner = owner
        self._repo = repo
        self._secrets_client = secrets_client or boto3.client("secretsmanager")

    def create_pr(
        self,
        role_arn: str,
        role_name: str,
        terraform_hcl: str,
        removed_actions: list[str],
        reason: str,
        warnings: list[str],
        scan_date: str,
    ) -> str:
        """
        Terraform HCL ファイルをコミットして GitHub PR を作成し、PR URL を返す。

        処理フロー:
          1. Secrets Manager から GitHub Token 取得
          2. デフォルトブランチ（main）の最新 SHA 取得
          3. 新規ブランチ作成: fix/iam-least-privilege-{YYYYMMDD}-{role_name_short}
          4. terraform/iam_policies/{role_name_short}.tf をコミット
          5. PR 作成

        GitHub API 失敗時は例外を raise する（呼び出し元でエラーとして記録される）。

        IAM アクション: secretsmanager:GetSecretValue

        Args:
            role_arn: 対象 IAM ロールの ARN
            role_name: 対象 IAM ロール名
            terraform_hcl: TerraformFormatter が生成した HCL 文字列
            removed_actions: 削除されたアクションの一覧
            reason: Bedrock が生成した変更理由
            warnings: Bedrock が生成した警告メッセージの一覧
            scan_date: Access Analyzer スキャン日時文字列

        Returns:
            作成した PR の URL 文字列

        Raises:
            urllib.error.HTTPError: GitHub API が 4xx/5xx を返した場合
            urllib.error.URLError: ネットワーク接続エラーの場合
        """
        token = self._get_github_token()

        role_name_short = role_name[:ROLE_NAME_MAX_LEN]
        today = datetime.now(JST).strftime("%Y%m%d")
        branch_name = f"fix/iam-least-privilege-{today}-{role_name_short}"

        base_sha = self._get_main_sha(token)
        logger.info("base SHA: %s", base_sha)

        self._create_branch(token, branch_name, base_sha)
        logger.info("ブランチ作成: %s", branch_name)

        file_path = f"terraform/iam_policies/{role_name_short}.tf"
        self._commit_file(token, branch_name, file_path, terraform_hcl, role_name_short)
        logger.info("ファイルコミット: %s", file_path)

        pr_url = self._create_pull_request(
            token=token,
            branch_name=branch_name,
            role_arn=role_arn,
            role_name=role_name,
            role_name_short=role_name_short,
            removed_actions=removed_actions,
            reason=reason,
            warnings=warnings,
            scan_date=scan_date,
        )
        logger.info("PR 作成完了: %s", pr_url)
        return pr_url

    # ------------------------------------------------------------------
    # 内部メソッド
    # ------------------------------------------------------------------

    def _get_github_token(self) -> str:
        """
        Secrets Manager から GitHub Personal Access Token を取得して返す。

        IAM アクション: secretsmanager:GetSecretValue

        シークレット形式: {"token": "<ghp_...>"}

        Returns:
            GitHub Personal Access Token 文字列

        Raises:
            ClientError: Secrets Manager API エラー
            KeyError: シークレット内に "token" キーが存在しない場合
        """
        # IAM アクション: secretsmanager:GetSecretValue
        response = self._secrets_client.get_secret_value(SecretId=self._token_secret_arn)
        secret = json.loads(response["SecretString"])
        return secret["token"]

    def _get_main_sha(self, token: str) -> str:
        """
        main ブランチの最新コミット SHA を取得して返す。

        Args:
            token: GitHub Personal Access Token

        Returns:
            最新コミットの SHA 文字列

        Raises:
            urllib.error.HTTPError: API エラー
        """
        url = f"{GITHUB_API_BASE}/repos/{self._owner}/{self._repo}/git/ref/heads/main"
        data = self._github_request(token, "GET", url)
        return data["object"]["sha"]

    def _create_branch(self, token: str, branch_name: str, base_sha: str) -> None:
        """
        指定 SHA を起点に新規ブランチを作成する。

        Args:
            token: GitHub Personal Access Token
            branch_name: 作成するブランチ名
            base_sha: ブランチの起点となるコミット SHA

        Raises:
            urllib.error.HTTPError: API エラー
        """
        url = f"{GITHUB_API_BASE}/repos/{self._owner}/{self._repo}/git/refs"
        payload = {
            "ref": f"refs/heads/{branch_name}",
            "sha": base_sha,
        }
        self._github_request(token, "POST", url, payload)

    def _commit_file(
        self,
        token: str,
        branch_name: str,
        file_path: str,
        content: str,
        role_name_short: str,
    ) -> None:
        """
        ブランチに Terraform HCL ファイルを新規コミットする。

        content は base64 エンコードして GitHub Contents API に送信する。

        Args:
            token: GitHub Personal Access Token
            branch_name: コミット先ブランチ名
            file_path: リポジトリ内のファイルパス
            content: コミットするファイル内容（HCL 文字列）
            role_name_short: コミットメッセージ用のロール名（短縮形）

        Raises:
            urllib.error.HTTPError: API エラー
        """
        url = (
            f"{GITHUB_API_BASE}/repos/{self._owner}/{self._repo}"
            f"/contents/{file_path}"
        )
        encoded_content = base64.b64encode(content.encode("utf-8")).decode("ascii")
        payload = {
            "message": f"[IAM] {role_name_short} の最小権限化（自動生成）",
            "content": encoded_content,
            "branch": branch_name,
        }
        self._github_request(token, "PUT", url, payload)

    def _create_pull_request(
        self,
        token: str,
        branch_name: str,
        role_arn: str,
        role_name: str,
        role_name_short: str,
        removed_actions: list[str],
        reason: str,
        warnings: list[str],
        scan_date: str,
    ) -> str:
        """
        PR を作成して PR URL を返す。

        タイトル・本文は CLAUDE.md のフォーマット仕様に準拠する。

        Args:
            token: GitHub Personal Access Token
            branch_name: PR のヘッドブランチ名
            role_arn: 対象ロールの ARN
            role_name: 対象ロール名（タイトル表示用）
            role_name_short: ファイル名用の短縮ロール名
            removed_actions: 削除されたアクションの一覧
            reason: 変更理由
            warnings: 警告メッセージの一覧
            scan_date: Access Analyzer スキャン日時文字列

        Returns:
            作成した PR の HTML URL 文字列

        Raises:
            urllib.error.HTTPError: API エラー
        """
        url = f"{GITHUB_API_BASE}/repos/{self._owner}/{self._repo}/pulls"
        now_jst = datetime.now(JST).strftime("%Y/%m/%d")
        title = f"[IAM] {role_name} の最小権限化 ({now_jst})"
        body = self._build_pr_body(
            role_arn=role_arn,
            removed_actions=removed_actions,
            reason=reason,
            warnings=warnings,
            scan_date=scan_date,
        )
        payload = {
            "title": title,
            "head": branch_name,
            "base": "main",
            "body": body,
        }
        data = self._github_request(token, "POST", url, payload)
        return data["html_url"]

    def _build_pr_body(
        self,
        role_arn: str,
        removed_actions: list[str],
        reason: str,
        warnings: list[str],
        scan_date: str,
    ) -> str:
        """
        CLAUDE.md 仕様の PR 本文を組み立てて返す。

        Args:
            role_arn: 対象ロールの ARN
            removed_actions: 削除されたアクションの一覧
            reason: 変更理由
            warnings: 警告メッセージの一覧
            scan_date: Access Analyzer スキャン日時文字列

        Returns:
            PR 本文 Markdown 文字列
        """
        now_jst = datetime.now(JST).strftime("%Y-%m-%d %H:%M:%S JST")
        actions_bullet = "\n".join(f"- `{a}`" for a in removed_actions) or "- (なし)"

        warning_section = ""
        if warnings:
            warning_lines = "\n".join(f"- ⚠️ {w}" for w in warnings)
            warning_section = f"\n## ⚠️ 警告\n{warning_lines}\n"

        return (
            "## 概要\n"
            "Amazon Bedrock (Claude Sonnet) による IAM ポリシー最小権限化の提案です。\n"
            "**このPRは自動生成です。マージ前に必ずレビューしてください。**\n\n"
            f"## 対象ロール\n`{role_arn}`\n\n"
            "## 変更内容\n"
            f"### 削除されたアクション ({len(removed_actions)}件)\n"
            f"{actions_bullet}\n\n"
            f"### 変更理由\n{reason}\n"
            f"{warning_section}\n"
            "## レビューチェックリスト\n"
            "- [ ] 削除されたアクションが実際に不要であることを確認した\n"
            "- [ ] Conditionが変更されていないことを確認した\n"
            "- [ ] Resourceの指定が変更されていないことを確認した\n"
            "- [ ] アプリケーションの動作に影響しないことを確認した\n\n"
            "## 生成情報\n"
            f"- 生成日時: {now_jst}\n"
            "- 使用モデル: anthropic.claude-sonnet-4-5\n"
            f"- Access Analyzer スキャン日: {scan_date}\n"
        )

    def _github_request(
        self,
        token: str,
        method: str,
        url: str,
        payload: dict | None = None,
    ) -> dict:
        """
        GitHub REST API にリクエストを送信してレスポンス JSON を返す。

        失敗時は例外を raise する（呼び出し元で Lambda エラーとして記録される）。

        Args:
            token: GitHub Personal Access Token
            method: HTTP メソッド（GET / POST / PUT）
            url: リクエスト先 URL
            payload: リクエストボディ（省略時はボディなし）

        Returns:
            レスポンス JSON をパースした辞書

        Raises:
            urllib.error.HTTPError: 4xx / 5xx レスポンス
            urllib.error.URLError: ネットワークエラー
        """
        data = json.dumps(payload).encode("utf-8") if payload else None
        req = urllib.request.Request(
            url,
            data=data,
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/vnd.github+json",
                "Content-Type": "application/json",
                "X-GitHub-Api-Version": "2022-11-28",
            },
            method=method,
        )

        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="replace")
            logger.error(
                "GitHub API エラー: method=%s url=%s status=%d body=%s",
                method,
                url,
                e.code,
                body[:500],
            )
            raise
