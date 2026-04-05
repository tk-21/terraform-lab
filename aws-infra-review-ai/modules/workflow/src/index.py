"""
workflow-starter Lambda

役割:
    S3 に Terraform コードまたはアーキテクチャ図がアップロードされたとき、
    S3 イベント通知により起動し、Step Functions のレビューワークフローを起動する。

Week 4 追加:
    アーキテクチャ図（PNG/JPG/WEBP/GIF/PDF）に対応。
    Bedrock Claude の Vision/Document API を使って画像を分析し、
    テキスト説明に変換してから Step Functions に渡す。
    これにより全エージェントがテキスト入力のまま画像レビューも対応できる。

トリガー:
    S3 PUT イベント（reviews/{session_id}/{filename} にファイルがアップロードされたとき）

処理フロー:
    1. S3 イベントから session_id と s3_key を抽出
    2. DynamoDB からセッション情報（input_type）を取得
    3. ファイル種別を判定（テキスト / 画像 / PDF）
       - テキスト: UTF-8 文字列としてそのまま使用
       - 画像/PDF: Bedrock Vision/Document API でテキスト説明に変換（前処理）
    4. DynamoDB のステータスを "starting" に更新（重複起動防止）
    5. Step Functions を StartExecution で起動

Step Functions への入力:
    {
        "session_id":     "uuid4",
        "s3_key":         "reviews/{session_id}/{filename}",
        "input_type":     "terraform" | "architecture",
        "review_content": "ファイルの内容またはアーキテクチャ説明（常にテキスト）"
    }

注意:
    - テキストファイルは先頭 200KB に制限（Step Functions 256KB 上限対応）
    - 画像/PDF は Bedrock Vision 前処理後のテキストを渡すため制限なし
    - 同一セッションへの重複アップロードは status チェックでスキップ
"""

import base64
import json
import os
import logging
import urllib.parse

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_region = os.environ.get("AWS_REGION_NAME", "ap-northeast-1")

s3 = boto3.client("s3", region_name=_region)
dynamodb = boto3.resource("dynamodb", region_name=_region)
sfn = boto3.client("stepfunctions", region_name=_region)
bedrock = boto3.client("bedrock-runtime", region_name=_region)

TABLE_NAME = os.environ["DYNAMODB_TABLE_NAME"]
STATE_MACHINE_ARN = os.environ["STATE_MACHINE_ARN"]
BEDROCK_MODEL_ID = os.environ["BEDROCK_MODEL_ID"]

# テキストファイルの最大読み込みサイズ
# Step Functions の実行入力上限（256KB）に review_content が収まるよう制限
MAX_TEXT_BYTES = 100 * 1024  # 100 KB（agent_results × 4 が加わるため余裕を持たせる）

# Bedrock Vision が受け付けるファイルサイズ上限（5MB）の安全マージン
MAX_IMAGE_BYTES = 3 * 1024 * 1024  # 3 MB

# ファイル拡張子 → MIME タイプ（画像）
IMAGE_MEDIA_TYPES: dict[str, str] = {
    ".png":  "image/png",
    ".jpg":  "image/jpeg",
    ".jpeg": "image/jpeg",
    ".gif":  "image/gif",
    ".webp": "image/webp",
}

# テキストとして処理する拡張子
TEXT_EXTENSIONS = {
    ".tf", ".hcl", ".json", ".yaml", ".yml",
    ".txt", ".md", ".ini", ".toml",
}

# =============================================================================
# Bedrock Vision 前処理用プロンプト
# エージェントが運用・セキュリティ・コスト・信頼性レビューできる形式で説明させる
# =============================================================================
ARCHITECTURE_ANALYSIS_PROMPT = """このAWSアーキテクチャ図を詳細に分析し、以下の観点で構造化されたテキスト説明を作成してください。

## 出力フォーマット

### 1. アーキテクチャ概要
（システム全体の目的・用途を1〜2文で説明）

### 2. 使用サービス一覧
（全AWSサービスをリストアップ。各サービスの役割を1行で説明）

### 3. データフロー・通信経路
（どのサービスからどのサービスへデータが流れるかを説明）

### 4. ネットワーク構成
（VPC・サブネット・セキュリティグループ・エンドポイント等の情報）

### 5. 可視化できる設計上の特徴
（マルチAZ・冗長化・スケーリング・バックアップ等の有無）

### 6. レビュー時に確認すべき点（図から読み取れる範囲で）
（セキュリティ・コスト・信頼性・運用性の観点で気になる箇所）

---
テキストとして出力してください（JSONや他の形式は不要）。
図に記載されていない情報は推測で補わず「図に記載なし」と記述してください。"""


def get_file_type(filename: str) -> str:
    """
    ファイル名から種別を判定する

    Returns:
        "text" | "image" | "pdf"
    """
    ext = os.path.splitext(filename.lower())[1]
    if ext in IMAGE_MEDIA_TYPES:
        return "image"
    if ext == ".pdf":
        return "pdf"
    # 不明な拡張子はテキストとして扱う（最善努力）
    return "text"


def describe_architecture_with_bedrock(
    file_bytes: bytes, file_type: str, filename: str
) -> str:
    """
    Bedrock Claude の Vision（画像）または Document（PDF）API で
    アーキテクチャ図を分析し、テキスト説明を生成する。

    エージェント Lambda はテキスト入力のみ想定しているため、
    このステップで画像を一度テキスト化することで
    全エージェントが画像レビューに対応できる。

    Args:
        file_bytes: ファイルのバイトデータ
        file_type:  "image" | "pdf"
        filename:   元のファイル名（ログ用）

    Returns:
        アーキテクチャの詳細テキスト説明
    """
    b64_data = base64.b64encode(file_bytes).decode("utf-8")

    if file_type == "image":
        ext = os.path.splitext(filename.lower())[1]
        media_type = IMAGE_MEDIA_TYPES.get(ext, "image/png")
        file_block = {
            "type": "image",
            "source": {
                "type": "base64",
                "media_type": media_type,
                "data": b64_data,
            },
        }
    else:  # pdf
        # Claude 3.5 Sonnet v2 は PDF のドキュメントブロックをサポート
        file_block = {
            "type": "document",
            "source": {
                "type": "base64",
                "media_type": "application/pdf",
                "data": b64_data,
            },
        }

    request_body = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 4096,
        "messages": [
            {
                "role": "user",
                "content": [
                    file_block,
                    {"type": "text", "text": ARCHITECTURE_ANALYSIS_PROMPT},
                ],
            }
        ],
    }

    logger.info(
        f"Bedrock Vision 呼び出し開始: model={BEDROCK_MODEL_ID}, "
        f"file_type={file_type}, filename={filename}, "
        f"bytes={len(file_bytes)}"
    )

    response = bedrock.invoke_model(
        modelId=BEDROCK_MODEL_ID,
        contentType="application/json",
        accept="application/json",
        body=json.dumps(request_body),
    )

    response_body = json.loads(response["body"].read())
    description = response_body["content"][0]["text"]

    logger.info(f"Bedrock Vision 完了: {len(description)} 文字の説明を生成")

    return (
        f"[アーキテクチャ図分析 - {filename}]\n"
        f"（Bedrock Claude Vision による前処理済みテキスト）\n\n"
        f"{description}"
    )


def read_s3_file(bucket: str, key: str) -> tuple[bytes, int]:
    """
    S3 からファイルをバイトデータとして読み込む

    Args:
        bucket: S3 バケット名
        key:    S3 オブジェクトキー

    Returns:
        (file_bytes, total_content_length) のタプル
    """
    response = s3.get_object(Bucket=bucket, Key=key)
    total_size = response["ContentLength"]
    # 画像は 3MB 上限、テキストは 200KB 上限（後続で判定）
    # ここでは最大 3MB だけ読む（どちらの上限も超えないため）
    file_bytes = response["Body"].read(MAX_IMAGE_BYTES)
    return file_bytes, total_size


def get_review_content(
    file_bytes: bytes, total_size: int, file_type: str, filename: str
) -> str:
    """
    ファイル種別に応じて review_content を生成する

    - テキスト: UTF-8 デコードして文字列化（200KB 上限）
    - 画像/PDF: Bedrock Vision でテキスト説明に変換

    Args:
        file_bytes:  読み込んだバイトデータ
        total_size:  S3 上のオリジナルファイルサイズ
        file_type:   "text" | "image" | "pdf"
        filename:    元のファイル名

    Returns:
        review_content 文字列
    """
    if file_type == "text":
        # テキストとして処理
        text_bytes = file_bytes[:MAX_TEXT_BYTES]
        try:
            content = text_bytes.decode("utf-8-sig")
        except UnicodeDecodeError:
            content = text_bytes.decode("latin-1")

        if total_size > MAX_TEXT_BYTES:
            content += (
                f"\n\n... [ファイルが大きいため先頭 200KB のみ表示。"
                f"全体サイズ: {total_size} bytes]"
            )
            logger.warning(
                f"テキストファイル切り捨て: filename={filename}, "
                f"total_size={total_size}"
            )
        return content

    else:
        # 画像 / PDF: Bedrock Vision で前処理
        if len(file_bytes) > MAX_IMAGE_BYTES:
            raise ValueError(
                f"ファイルサイズが上限（3MB）を超えています: "
                f"filename={filename}, size={total_size} bytes。"
                "画像を圧縮するか、アーキテクチャ説明をテキストファイルで提出してください。"
            )
        return describe_architecture_with_bedrock(file_bytes, file_type, filename)


def get_session(session_id: str) -> dict | None:
    """DynamoDB からセッション情報を取得する"""
    table = dynamodb.Table(TABLE_NAME)
    response = table.get_item(Key={"session_id": session_id})
    return response.get("Item")


def update_session_status(session_id: str, status: str) -> None:
    """DynamoDB のセッションステータスを更新する"""
    table = dynamodb.Table(TABLE_NAME)
    table.update_item(
        Key={"session_id": session_id},
        UpdateExpression="SET #st = :status",
        ExpressionAttributeNames={"#st": "status"},
        ExpressionAttributeValues={":status": status},
    )


def lambda_handler(event: dict, context) -> dict:
    """
    Lambda エントリーポイント（S3 イベント通知）

    テキストファイル: そのまま review_content として Step Functions に渡す
    画像/PDF:        Bedrock Vision で前処理 → テキスト説明として渡す

    Args:
        event:   S3 イベント通知
        context: Lambda コンテキスト

    Returns:
        処理結果 dict
    """
    logger.info(f"S3 イベント受信: {json.dumps(event)}")

    started_count = 0

    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        raw_key = record["s3"]["object"]["key"]
        key = urllib.parse.unquote_plus(raw_key)

        logger.info(f"処理対象: bucket={bucket}, key={key}")

        # キーの形式: reviews/{session_id}/{filename}
        parts = key.split("/")
        if len(parts) < 3 or parts[0] != "reviews":
            logger.warning(f"想定外のキー形式をスキップ: key={key}")
            continue

        session_id = parts[1]
        filename = parts[-1]
        logger.info(f"session_id={session_id}, filename={filename}")

        try:
            # セッション情報取得
            session = get_session(session_id)
            if not session:
                logger.error(f"セッションが見つかりません: session_id={session_id}")
                continue

            # すでにワークフローが起動済みの場合はスキップ
            current_status = session.get("status", "")
            if current_status not in ("pending",):
                logger.info(
                    f"ワークフロー起動済みのためスキップ: "
                    f"session_id={session_id}, status={current_status}"
                )
                continue

            input_type = session.get("input_type", "terraform")
            file_type = get_file_type(filename)

            logger.info(
                f"ファイル種別判定: filename={filename}, "
                f"file_type={file_type}, input_type={input_type}"
            )

            # S3 からファイルを読み込む
            file_bytes, total_size = read_s3_file(bucket, key)
            logger.info(
                f"S3 読み込み完了: "
                f"filename={filename}, total_size={total_size} bytes"
            )

            # ファイル種別に応じて review_content を生成
            review_content = get_review_content(
                file_bytes, total_size, file_type, filename
            )
            logger.info(
                f"review_content 生成完了: "
                f"content_length={len(review_content)} chars, "
                f"file_type={file_type}"
            )

            # ステータスを "starting" に更新してから SF を起動（重複防止）
            update_session_status(session_id, "starting")

            # Step Functions ワークフロー起動
            execution_input = {
                "session_id":     session_id,
                "s3_key":         key,
                "input_type":     input_type,
                "review_content": review_content,
            }

            execution_name = f"review-{session_id}"
            sfn_response = sfn.start_execution(
                stateMachineArn=STATE_MACHINE_ARN,
                name=execution_name,
                input=json.dumps(execution_input, ensure_ascii=False),
            )

            logger.info(
                f"Step Functions 起動完了: "
                f"session_id={session_id}, "
                f"executionArn={sfn_response['executionArn']}"
            )
            started_count += 1

        except ClientError as e:
            error_code = e.response["Error"]["Code"]
            logger.error(
                f"AWS API エラー: "
                f"session_id={session_id}, error={error_code} - {str(e)}"
            )
            try:
                update_session_status(session_id, "failed")
            except Exception:
                pass
            continue

        except ValueError as e:
            # ファイルサイズ超過等のバリデーションエラー
            logger.error(f"バリデーションエラー: session_id={session_id}, error={str(e)}")
            try:
                update_session_status(session_id, "failed")
            except Exception:
                pass
            continue

    return {
        "message": f"{started_count} 件のワークフローを起動しました",
        "started_count": started_count,
    }
