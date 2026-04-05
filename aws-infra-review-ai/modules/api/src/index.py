"""
session-handler Lambda

役割:
    API Gateway からのリクエストを受け付け、レビューセッションを作成・取得する。

エンドポイント:
    POST /reviews
        レビューセッションを作成し、S3 プリサインド URL を返す。
        リクエスト: { "input_type": "terraform" | "architecture", "filename": "main.tf" }
        レスポンス: { "session_id", "upload_url", "s3_key", "status", "message" }

    GET /reviews/{session_id}
        セッションの進捗・レビュー結果を返す。
        レスポンス: {
            "session_id", "status", "input_type", "created_at",
            "final_report_url",   # completed 時のみ
            "scores",             # completed 時のみ { security, cost, reliability, operations, total }
            "executive_summary",  # completed 時のみ
            "priority_actions"    # completed 時のみ
        }

エラー時:
    { "error": "エラーメッセージ", "status_code": 400 | 500 }
"""

import json
import os
import uuid
import logging
from datetime import datetime, timezone, timedelta

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource("dynamodb", region_name=os.environ.get("AWS_REGION_NAME", "ap-northeast-1"))
s3 = boto3.client("s3", region_name=os.environ.get("AWS_REGION_NAME", "ap-northeast-1"))

TABLE_NAME = os.environ["DYNAMODB_TABLE_NAME"]
BUCKET_NAME = os.environ["INPUT_BUCKET_NAME"]

# S3 署名付き URL の有効期限（秒）: 1時間
PRESIGNED_URL_EXPIRY = 3600

# DynamoDB TTL: セッションデータを 365 日後に自動削除
SESSION_TTL_DAYS = 365


def create_response(status_code: int, body: dict) -> dict:
    """
    API Gateway Lambda プロキシ統合用のレスポンス形式に変換する

    Args:
        status_code: HTTP ステータスコード
        body: レスポンスボディ dict

    Returns:
        API Gateway が期待する dict 形式
    """
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",  # CORS（学習用途: 本番では制限すること）
        },
        "body": json.dumps(body, ensure_ascii=False),
    }


def generate_presigned_url(s3_key: str) -> str:
    """
    S3 へのファイルアップロード用の署名付き URL を生成する

    署名付き URL を使うことで:
    - Lambda に直接ファイルを送らなくて済む（Lambda のペイロード制限 6MB を回避）
    - 一時的なアクセス権限を安全に委譲できる

    Args:
        s3_key: S3 オブジェクトキー（例: reviews/{session_id}/main.tf）

    Returns:
        有効期限付きの署名済み PUT URL
    """
    url = s3.generate_presigned_url(
        "put_object",
        Params={
            "Bucket": BUCKET_NAME,
            "Key": s3_key,
        },
        ExpiresIn=PRESIGNED_URL_EXPIRY,
    )
    return url


def create_session(session_id: str, input_type: str, s3_key: str) -> None:
    """
    DynamoDB にレビューセッションレコードを作成する

    スキーマ（CLAUDE.md 定義）:
        session_id  (PK)
        input_type  "terraform" | "architecture"
        created_at  ISO8601 タイムスタンプ
        status      "pending" → "running" → "completed" | "failed"
        s3_key      アップロードされたファイルのパス
        rounds      {} （各エージェントの結果がここに書き込まれる）
        expires_at  TTL: UNIX タイムスタンプ

    Args:
        session_id: 生成した UUID
        input_type: 入力種別
        s3_key: S3 ファイルパス
    """
    table = dynamodb.Table(TABLE_NAME)

    now = datetime.now(timezone.utc)
    expires_at = int((now + timedelta(days=SESSION_TTL_DAYS)).timestamp())

    table.put_item(
        Item={
            "session_id": session_id,
            "input_type": input_type,
            "created_at": now.isoformat(),
            "status": "pending",
            "s3_key": s3_key,
            # rounds は各エージェント Lambda が更新する
            # 初期値として空の Map を設定しておくことで UpdateItem の SET が失敗しないようにする
            "rounds": {
                "round_1": {
                    "security": {},
                    "cost": {},
                    "reliability": {},
                    "operations": {},
                }
            },
            "expires_at": expires_at,
        }
    )
    logger.info(f"セッション作成完了: session_id={session_id}")


def get_session(session_id: str) -> dict | None:
    """
    DynamoDB からレビューセッション情報を取得する

    Args:
        session_id: セッション ID

    Returns:
        セッションレコード dict。存在しない場合は None。
    """
    table = dynamodb.Table(TABLE_NAME)
    response = table.get_item(Key={"session_id": session_id})
    return response.get("Item")


def handle_get_session(session_id: str) -> dict:
    """
    GET /reviews/{session_id} ハンドラ

    セッション状態に応じて返すフィールドを調整する:
    - pending / running / starting: status のみ
    - completed: scores・executive_summary・priority_actions・final_report_url も含む
    - failed: status + error 情報

    Args:
        session_id: URL パスパラメータから抽出したセッション ID

    Returns:
        API Gateway レスポンス形式 dict
    """
    if not session_id:
        return create_response(400, {"error": "session_id が指定されていません"})

    try:
        item = get_session(session_id)
    except ClientError as e:
        error_code = e.response["Error"]["Code"]
        logger.error(f"DynamoDB GetItem エラー: {error_code} - {str(e)}")
        return create_response(500, {"error": f"内部エラーが発生しました: {error_code}"})

    if item is None:
        return create_response(404, {"error": f"セッション '{session_id}' が見つかりません"})

    status = item.get("status", "unknown")

    body: dict = {
        "session_id": item["session_id"],
        "status": status,
        "input_type": item.get("input_type", ""),
        "created_at": item.get("created_at", ""),
    }

    if status == "completed":
        # supervisor の round_2 結果からスコア・サマリーを取得
        round2 = item.get("rounds", {}).get("round_2", {})
        body["scores"] = round2.get("overall_score", {})
        body["executive_summary"] = round2.get("executive_summary", "")
        body["priority_actions"] = round2.get("priority_actions", [])
        body["final_report_url"] = item.get("final_report_url", "")

    logger.info(f"セッション取得完了: session_id={session_id}, status={status}")
    return create_response(200, body)


def lambda_handler(event: dict, context) -> dict:
    """
    Lambda エントリーポイント（API Gateway Lambda プロキシ統合）

    POST /reviews        → セッション作成 + S3 署名付き URL 発行
    GET  /reviews/{id}   → セッション状態・レビュー結果取得

    Args:
        event: API Gateway から渡されるイベント
        context: Lambda コンテキスト

    Returns:
        API Gateway レスポンス形式 dict
    """
    logger.info(f"リクエスト受信: {json.dumps(event)}")

    http_method = event.get("httpMethod", "POST")

    # GET /reviews/{session_id} — セッション取得
    if http_method == "GET":
        session_id = (event.get("pathParameters") or {}).get("session_id", "")
        return handle_get_session(session_id)

    # POST /reviews — セッション作成（以下は既存処理）
    # リクエストボディのパース
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return create_response(400, {"error": "リクエストボディが不正な JSON です"})

    input_type = body.get("input_type", "terraform")
    filename = body.get("filename", "review.tf")

    # バリデーション
    if input_type not in ("terraform", "architecture"):
        return create_response(
            400,
            {"error": "input_type は 'terraform' または 'architecture' を指定してください"},
        )

    # セッション ID 生成（UUID v4）
    session_id = str(uuid.uuid4())
    s3_key = f"reviews/{session_id}/{filename}"

    try:
        # DynamoDB にセッションレコードを作成
        create_session(session_id, input_type, s3_key)

        # S3 署名付きアップロード URL を生成
        upload_url = generate_presigned_url(s3_key)

        logger.info(
            f"セッション作成・URL 生成完了: session_id={session_id}, "
            f"input_type={input_type}, s3_key={s3_key}"
        )

        return create_response(
            201,
            {
                "session_id": session_id,
                "upload_url": upload_url,
                "s3_key": s3_key,
                "status": "pending",
                "message": (
                    f"upload_url に {filename} をアップロードしてください。"
                    "アップロード完了後、S3 イベントにより自動でレビューワークフローが起動します。"
                ),
            },
        )

    except ClientError as e:
        error_code = e.response["Error"]["Code"]
        logger.error(f"AWS API エラー: {error_code} - {str(e)}")
        return create_response(
            500,
            {"error": f"内部エラーが発生しました: {error_code}"},
        )
