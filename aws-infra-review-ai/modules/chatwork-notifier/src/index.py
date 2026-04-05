"""
chatwork-notifier Lambda

役割:
    レビュー完了後に Chatwork ルームへサマリーとレポートリンクを通知する。

    Chatwork API を利用して以下の情報を送信する:
    - 総合スコア（各エージェント別スコア）
    - エグゼクティブサマリー
    - 優先対応アクション TOP 5
    - HTML レポートへのリンク（7 日間有効の署名付き URL）

入力（Step Functions から渡される）:
    {
        "session_id":        "uuid4",
        "input_type":        "terraform" | "architecture",
        "supervisor_result": {
            "tradeoffs":       [...],
            "priority_actions": [...],
            "overall_score":   { "security": 72, "cost": 88, ... "total": 75 },
            "executive_summary": "..."
        },
        "report_url":    "https://s3...（署名付き URL）",
        "report_s3_key": "reports/{session_id}/report.html"
    }

出力:
    {
        "message_id": "12345678" | null,
        "status": "sent" | "skipped" | "error",
        "error": "エラーメッセージ"（エラー時のみ）
    }

注意:
    Chatwork 通知の失敗はワークフローを止めない。
    Lambda 内で例外をキャッチし、status="error" として返す。
"""

import json
import os
import logging
import urllib.request
import urllib.parse
import urllib.error

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ssm = boto3.client("ssm", region_name="ap-northeast-1")

CHATWORK_ROOM_ID = os.environ["CHATWORK_ROOM_ID"]
CHATWORK_TOKEN_SSM_PATH = os.environ["CHATWORK_TOKEN_SSM_PATH"]

# Chatwork API エンドポイント
CHATWORK_API_BASE = "https://api.chatwork.com/v2"

# スコアに応じた絵文字
SCORE_EMOJI = {
    "excellent": "🟢",  # >= 80
    "good":      "🔵",  # >= 60
    "warning":   "🟡",  # >= 40
    "danger":    "🔴",  # < 40
}


def score_emoji(score: int) -> str:
    if score >= 80:
        return SCORE_EMOJI["excellent"]
    if score >= 60:
        return SCORE_EMOJI["good"]
    if score >= 40:
        return SCORE_EMOJI["warning"]
    return SCORE_EMOJI["danger"]


def get_chatwork_token() -> str:
    """
    SSM Parameter Store から Chatwork API トークンを取得する

    Secrets Manager ではなく SSM SecureString を使う理由:
    - シンプルな文字列シークレットには SSM で十分
    - Secrets Manager は rotation 機能が必要な場合に使用する

    Returns:
        Chatwork API トークン文字列

    Raises:
        ClientError: SSM パラメータが見つからない場合
    """
    response = ssm.get_parameter(
        Name=CHATWORK_TOKEN_SSM_PATH,
        WithDecryption=True,  # SecureString を復号して取得
    )
    return response["Parameter"]["Value"]


def format_message(
    session_id: str,
    input_type: str,
    supervisor_result: dict,
    report_url: str,
) -> str:
    """
    Chatwork に投稿するメッセージを Chatwork 記法で組み立てる

    Chatwork 記法:
        [info][title]タイトル[/title]本文[/info]
        [code]コード[/code]

    Args:
        session_id:       セッション ID
        input_type:       "terraform" | "architecture"
        supervisor_result: supervisor の統合結果
        report_url:        HTML レポートの署名付き URL

    Returns:
        Chatwork メッセージ文字列
    """
    overall_score = supervisor_result.get("overall_score", {})
    total = overall_score.get("total", 0)
    security = overall_score.get("security", 0)
    cost = overall_score.get("cost", 0)
    reliability = overall_score.get("reliability", 0)
    operations = overall_score.get("operations", 0)
    executive_summary = supervisor_result.get("executive_summary", "")
    priority_actions = supervisor_result.get("priority_actions", [])

    input_type_label = "Terraform" if input_type == "terraform" else "アーキテクチャ構成"

    # 優先アクション TOP 5
    actions_text = ""
    for action in priority_actions[:5]:
        rank = action.get("rank", "?")
        act = action.get("action", "")
        severity = action.get("severity", "LOW")
        source = action.get("source_agent", "")
        severity_mark = {"HIGH": "⚠️", "MEDIUM": "📌", "LOW": "ℹ️"}.get(severity, "ℹ️")
        actions_text += f"\n{severity_mark} #{rank} [{source}] {act}"

    message = f"""[info][title]🔍 AWS インフラレビュー完了 - {input_type_label}[/title]
セッション ID: {session_id[:8]}...

【総合スコア】 {score_emoji(total)} {total}/100
  セキュリティ　: {score_emoji(security)} {security}/100
  コスト　　　　: {score_emoji(cost)} {cost}/100
  信頼性・可用性: {score_emoji(reliability)} {reliability}/100
  運用性　　　　: {score_emoji(operations)} {operations}/100

【サマリー】
{executive_summary}

【優先対応アクション TOP {min(5, len(priority_actions))}】{actions_text}

【詳細レポート（7日間有効）】
{report_url}
[/info]"""

    return message


def send_chatwork_message(token: str, room_id: str, message: str) -> str | None:
    """
    Chatwork API にメッセージを投稿する

    Args:
        token:   Chatwork API トークン
        room_id: 通知先ルーム ID
        message: 投稿するメッセージ

    Returns:
        メッセージ ID（成功時）

    Raises:
        urllib.error.HTTPError: API 呼び出しエラー
    """
    url = f"{CHATWORK_API_BASE}/rooms/{room_id}/messages"
    data = urllib.parse.urlencode({"body": message}).encode("utf-8")

    req = urllib.request.Request(
        url,
        data=data,
        method="POST",
        headers={
            "X-ChatWorkToken": token,
            "Content-Type": "application/x-www-form-urlencoded",
        },
    )

    with urllib.request.urlopen(req, timeout=15) as response:
        body = response.read().decode("utf-8")
        result = json.loads(body)
        message_id = str(result.get("message_id", ""))
        logger.info(f"Chatwork 送信完了: message_id={message_id}")
        return message_id


def lambda_handler(event: dict, context) -> dict:
    """
    Lambda エントリーポイント

    Step Functions の SendNotification ステートから呼び出される。
    Chatwork 通知に失敗してもワークフローを止めないよう、
    例外はキャッチして status="error" で返す。

    Args:
        event: {
            "session_id":        str,
            "input_type":        str,
            "supervisor_result": dict,
            "report_url":        str,
            "report_s3_key":     str
        }

    Returns:
        { "message_id": str|null, "status": "sent"|"skipped"|"error" }
    """
    logger.info(f"chatwork-notifier 開始: session_id={event.get('session_id')}")

    session_id = event.get("session_id", "")
    input_type = event.get("input_type", "terraform")
    supervisor_result = event.get("supervisor_result", {})
    report_url = event.get("report_url", "")

    # Chatwork 設定がない場合はスキップ（開発環境での未設定を考慮）
    if not CHATWORK_ROOM_ID or CHATWORK_ROOM_ID == "0":
        logger.info("CHATWORK_ROOM_ID 未設定のため通知をスキップ")
        return {"message_id": None, "status": "skipped"}

    try:
        # SSM から API トークン取得
        token = get_chatwork_token()

        # メッセージ組み立て
        message = format_message(session_id, input_type, supervisor_result, report_url)

        # Chatwork へ投稿
        message_id = send_chatwork_message(token, CHATWORK_ROOM_ID, message)

        logger.info(
            f"chatwork-notifier 完了: "
            f"session_id={session_id}, message_id={message_id}"
        )
        return {"message_id": message_id, "status": "sent"}

    except ClientError as e:
        # SSM 取得エラー（パラメータ未設定等）
        error_code = e.response["Error"]["Code"]
        logger.error(f"SSM 取得エラー: {error_code} - {str(e)}")
        return {"message_id": None, "status": "error", "error": str(e)}

    except urllib.error.HTTPError as e:
        # Chatwork API エラー
        body = e.read().decode("utf-8") if e.fp else ""
        logger.error(f"Chatwork API エラー: status={e.code}, body={body}")
        return {
            "message_id": None,
            "status": "error",
            "error": f"HTTP {e.code}: {body}",
        }

    except Exception as e:
        # その他のエラー（ネットワーク障害等）
        logger.error(f"予期せぬエラー: {str(e)}")
        return {"message_id": None, "status": "error", "error": str(e)}
