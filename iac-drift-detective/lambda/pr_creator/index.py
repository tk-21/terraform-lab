"""
pr-creator Lambda ハンドラー
Step Functions から bedrock-analyzer の出力を受け取る

入力: bedrock-analyzerの出力（analysis_result全体）
出力:
{
    "pr_created": bool,
    "pr_url": str,
    "pr_number": int,
    "branch_name": str,
    "chatwork_notified": bool,
    "severity": str,
}

環境変数:
- GITHUB_OWNER
- GITHUB_REPO
- CHATWORK_ROOM_ID
- POWERTOOLS_SERVICE_NAME = "pr-creator"
- LOG_LEVEL = "INFO"
"""

import os

import boto3
from aws_lambda_powertools import Logger, Tracer
from aws_lambda_powertools.utilities.typing import LambdaContext

from github_client import create_drift_pr, notify_chatwork
from hcl_formatter import add_drift_fix_header, validate_and_format_hcl

logger = Logger()
tracer = Tracer()

# 環境変数から設定値を取得
GITHUB_OWNER = os.environ["GITHUB_OWNER"]
GITHUB_REPO = os.environ["GITHUB_REPO"]
CHATWORK_ROOM_ID = os.environ["CHATWORK_ROOM_ID"]


def _get_ssm_parameter(ssm_client, name: str) -> str:
    """SSMパラメータを取得する（SecureString対応）。"""
    response = ssm_client.get_parameter(Name=name, WithDecryption=True)
    return response["Parameter"]["Value"]


@logger.inject_lambda_context
@tracer.capture_lambda_handler
def handler(event: dict, context: LambdaContext) -> dict:
    """
    Step Functionsから呼び出されるメインハンドラー。
    bedrock-analyzerの出力を受け取り、GitHub PRを作成してChatworkに通知する。
    """
    logger.info("PR作成処理開始", extra={"severity": event.get("severity")})

    ssm_client = boto3.client("ssm")

    # SSMからシークレットを取得（コード内にトークンを直書きしない）
    github_token = _get_ssm_parameter(ssm_client, "/drift-detective/github-token")
    chatwork_api_token = _get_ssm_parameter(ssm_client, "/drift-detective/chatwork-api-token")

    # HCLバリデーション・整形（不正なHCLの場合はValueErrorが上がりStep FunctionsがTaskFailedを発行）
    raw_hcl = event.get("remediation_hcl", "")
    formatted_hcl = validate_and_format_hcl(raw_hcl)
    final_hcl = add_drift_fix_header(formatted_hcl, event)
    logger.info("HCL整形完了")

    # HCLを整形済みコードで上書きしてPR作成へ渡す
    analysis_with_formatted_hcl = {**event, "remediation_hcl": final_hcl}

    # GitHub PR作成（失敗時はreraise → Step FunctionsのTaskFailedとして扱われる）
    pr_result = create_drift_pr(
        github_token=github_token,
        repo_owner=GITHUB_OWNER,
        repo_name=GITHUB_REPO,
        analysis_result=analysis_with_formatted_hcl,
    )
    logger.info("GitHub PR作成完了", extra={"pr_url": pr_result["pr_url"]})

    # Chatwork通知（失敗してもPR作成は成功扱い、WARNINGログのみ記録）
    chatwork_notified = False
    try:
        notify_chatwork(
            api_token=chatwork_api_token,
            room_id=CHATWORK_ROOM_ID,
            pr_url=pr_result["pr_url"],
            analysis_result=event,
        )
        chatwork_notified = True
        logger.info("Chatwork通知完了")
    except Exception as e:
        logger.warning("Chatwork通知失敗（PR作成は成功）", extra={"error": str(e)})

    return {
        "pr_created": True,
        "pr_url": pr_result["pr_url"],
        "pr_number": pr_result["pr_number"],
        "branch_name": pr_result["branch_name"],
        "chatwork_notified": chatwork_notified,
        "severity": event.get("severity", "UNKNOWN"),
    }
