"""
playbook-reviewer Lambda メインハンドラー
API Gateway (POST /review) から呼び出される

リクエストボディ (JSON):
  playbook_content    : Playbookの全文（YAML文字列）
  playbook_filename   : ファイル名（表示用）
  github_repo_owner   : GitHubリポジトリオーナー
  github_repo_name    : GitHubリポジトリ名
  pr_number           : PRナンバー
  api_secret          : 追加認証（SSMの api-key-secret と照合）

レスポンス (JSON):
  status        : "success" or "error"
  overall_score : int
  risk_level    : str
  issues_count  : int
  comment_url   : str
  message       : str
"""

import json
import os

import boto3
from aws_lambda_powertools import Logger, Tracer
from aws_lambda_powertools.utilities.typing import LambdaContext

from bedrock_reviewer import review_playbook
from github_commenter import add_pr_labels, post_review_comment
from playbook_parser import parse_playbook
from review_validator import validate_review_output

logger = Logger()
tracer = Tracer()

# 必須リクエストフィールド
_REQUIRED_FIELDS = (
    "playbook_content",
    "playbook_filename",
    "github_repo_owner",
    "github_repo_name",
    "pr_number",
    "api_secret",
)


def _ssm_get(path: str) -> str:
    """SSM Parameter Storeからパラメータを取得する（SecureString対応）"""
    ssm = boto3.client("ssm")
    response = ssm.get_parameter(Name=path, WithDecryption=True)
    return response["Parameter"]["Value"]


def _build_response(status_code: int, body: dict) -> dict:
    """API Gateway Lambda Proxy形式のレスポンスを構築する"""
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, ensure_ascii=False),
    }


@logger.inject_lambda_context
@tracer.capture_lambda_handler
def handler(event: dict, context: LambdaContext) -> dict:
    """
    メインハンドラー

    処理フロー:
    1. リクエストボディのバリデーション（必須フィールドチェック）
    2. api_secretの検証（SSMから取得して照合）
    3. playbook_parserでYAMLパース
    4. bedrock_reviewerでレビュー実行
    5. review_validatorでバリデーション
    6. github_commenterでPRコメント投稿・ラベル付与
    7. レスポンス返却
    """
    # リクエストボディのパース
    try:
        body_raw = event.get("body") or "{}"
        body: dict = json.loads(body_raw) if isinstance(body_raw, str) else body_raw
    except json.JSONDecodeError as e:
        logger.warning("リクエストボディのJSONパース失敗", extra={"error": str(e)})
        return _build_response(400, {"status": "error", "error": f"リクエストボディが不正なJSONです: {e}"})

    # 必須フィールドチェック
    missing = [f for f in _REQUIRED_FIELDS if f not in body]
    if missing:
        logger.warning("必須フィールド不足", extra={"missing_fields": missing})
        return _build_response(400, {"status": "error", "error": f"必須フィールドが不足しています: {missing}"})

    playbook_content: str = body["playbook_content"]
    playbook_filename: str = body["playbook_filename"]
    repo_owner: str = body["github_repo_owner"]
    repo_name: str = body["github_repo_name"]
    pr_number: int = int(body["pr_number"])
    api_secret: str = body["api_secret"]

    # api_secret の検証
    api_secret_ssm_path = os.environ.get(
        "API_SECRET_SSM_PATH", "/ansible-ai-reviewer/api-key-secret"
    )
    try:
        expected_secret = _ssm_get(api_secret_ssm_path)
    except Exception as e:
        logger.error("SSMからapi-key-secret取得失敗", extra={"error": str(e)})
        return _build_response(500, {"status": "error", "error": "内部エラー: シークレット取得に失敗しました"})

    if api_secret != expected_secret:
        logger.warning("api_secret認証失敗", extra={"pr_number": pr_number})
        return _build_response(403, {"status": "error", "error": "認証に失敗しました"})

    # GitHubトークン取得
    github_token_ssm_path = os.environ.get(
        "GITHUB_TOKEN_SSM_PATH", "/ansible-ai-reviewer/github-token"
    )
    try:
        github_token = _ssm_get(github_token_ssm_path)
    except Exception as e:
        logger.error("SSMからgithub-token取得失敗", extra={"error": str(e)})
        return _build_response(500, {"status": "error", "error": "内部エラー: GitHubトークン取得に失敗しました"})

    # Playbookパース
    logger.info("Playbookパース開始", extra={"filename": playbook_filename})
    parsed = parse_playbook(playbook_content)
    if parsed["parse_errors"]:
        logger.warning("Playbookパースエラーあり", extra={"errors": parsed["parse_errors"]})

    # Bedrockでレビュー実行
    logger.info("Bedrockレビュー開始")
    try:
        raw_review = review_playbook(parsed, playbook_content)
    except Exception as e:
        logger.error("Bedrockレビュー失敗", extra={"error": str(e)})
        return _build_response(500, {"status": "error", "error": f"レビュー実行に失敗しました: {e}"})

    # バリデーション
    try:
        review_result = validate_review_output(
            raw_review if isinstance(raw_review, str) else json.dumps(raw_review)
        )
    except ValueError as e:
        logger.error("レビュー出力バリデーション失敗", extra={"error": str(e)})
        return _build_response(500, {"status": "error", "error": f"レビュー結果のバリデーション失敗: {e}"})

    # PRコメント投稿
    logger.info("PRコメント投稿開始", extra={"pr_number": pr_number})
    try:
        comment_result = post_review_comment(
            github_token=github_token,
            repo_owner=repo_owner,
            repo_name=repo_name,
            pr_number=pr_number,
            review_result=review_result,
            playbook_filename=playbook_filename,
        )
    except Exception as e:
        logger.error("PRコメント投稿失敗", extra={"error": str(e)})
        return _build_response(500, {"status": "error", "error": f"PRコメント投稿に失敗しました: {e}"})

    # ラベル付与
    risk_level: str = review_result.get("estimated_risk_level", "LOW")
    try:
        add_pr_labels(
            github_token=github_token,
            repo_owner=repo_owner,
            repo_name=repo_name,
            pr_number=pr_number,
            risk_level=risk_level,
        )
    except Exception as e:
        # ラベル付与失敗はログのみ（コメント投稿成功を優先）
        logger.warning("ラベル付与失敗", extra={"error": str(e)})

    issues_count = len(review_result.get("issues", []))
    logger.info(
        "レビュー完了",
        extra={
            "score": review_result.get("overall_score"),
            "risk_level": risk_level,
            "issues_count": issues_count,
            "comment_action": comment_result["action"],
        },
    )

    return _build_response(200, {
        "status": "success",
        "overall_score": review_result.get("overall_score"),
        "risk_level": risk_level,
        "issues_count": issues_count,
        "comment_url": comment_result["comment_url"],
        "message": f"レビュー完了: {issues_count}件の問題を検出しました（スコア: {review_result.get('overall_score')}/100）",
    })
