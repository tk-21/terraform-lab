"""
Secrets Manager カスタムローテーション Lambda
4ステップローテーション: createSecret → setSecret → testSecret → finishSecret

設計ポイント:
- RDS Proxy は iam_auth=REQUIRED のため、Lambda は Aurora に直接接続する
- set_secret: マスターユーザー認証情報で Aurora に接続し ALTER USER を実行
- test_secret: 新パスワードで Aurora に直接接続して疎通確認
- ローテーション中も Proxy がセッション維持するため接続断なし
"""
import json
import os
import secrets
import string

import boto3
import psycopg
from psycopg import sql
from aws_lambda_powertools import Logger

logger = Logger()

sm_client = boto3.client("secretsmanager")
ssm_client = boto3.client("ssm")


def lambda_handler(event: dict, context) -> None:
    """
    Secrets Manager から呼び出されるローテーションハンドラー
    Step: createSecret | setSecret | testSecret | finishSecret
    """
    secret_arn = event["SecretId"]
    token = event["ClientRequestToken"]
    step = event["Step"]

    logger.info("ローテーション開始", extra={"step": step, "secret_arn": secret_arn})

    metadata = sm_client.describe_secret(SecretId=secret_arn)
    if not metadata.get("RotationEnabled"):
        raise ValueError(f"ローテーションが無効化されています: {secret_arn}")

    versions = metadata.get("VersionIdsToStages", {})
    if token not in versions:
        raise ValueError(f"トークンが見つかりません: {token}")

    if "AWSCURRENT" in versions[token]:
        logger.info("既に AWSCURRENT — ローテーション不要")
        return
    elif "AWSPENDING" not in versions[token]:
        raise ValueError(f"トークンが AWSPENDING にありません: {token}")

    dispatch = {
        "createSecret": _create_secret,
        "setSecret":    _set_secret,
        "testSecret":   _test_secret,
        "finishSecret": _finish_secret,
    }
    dispatch[step](secret_arn, token)


def _generate_password(length: int = 32) -> str:
    """記号を含む安全なランダムパスワード生成"""
    alphabet = string.ascii_letters + string.digits + "!@#$%^&*"
    return "".join(secrets.choice(alphabet) for _ in range(length))


def _create_secret(arn: str, token: str) -> None:
    """新しいパスワードを AWSPENDING ステージに保存"""
    try:
        sm_client.get_secret_value(SecretId=arn, VersionStage="AWSPENDING", VersionId=token)
        logger.info("AWSPENDING は既に存在 — スキップ")
        return
    except sm_client.exceptions.ResourceNotFoundException:
        pass

    current = json.loads(
        sm_client.get_secret_value(SecretId=arn, VersionStage="AWSCURRENT")["SecretString"]
    )
    current["password"] = _generate_password()

    sm_client.put_secret_value(
        SecretId=arn,
        ClientRequestToken=token,
        SecretString=json.dumps(current),
        VersionStages=["AWSPENDING"],
    )
    logger.info("新しいパスワードを AWSPENDING に保存")


def _set_secret(arn: str, token: str) -> None:
    """
    Aurora に直接接続（マスターユーザー認証）し appuser のパスワードを変更する。
    RDS Proxy は iam_auth=REQUIRED のため Proxy 経由での接続不可。
    """
    pending = json.loads(
        sm_client.get_secret_value(SecretId=arn, VersionStage="AWSPENDING", VersionId=token)["SecretString"]
    )

    # マスターユーザー認証情報を取得
    master = json.loads(
        sm_client.get_secret_value(SecretId=os.environ["MASTER_SECRET_ARN"])["SecretString"]
    )

    aurora_endpoint = ssm_client.get_parameter(
        Name=os.environ["AURORA_ENDPOINT_PARAM"]
    )["Parameter"]["Value"]
    db_name = ssm_client.get_parameter(
        Name=os.environ["DB_NAME_PARAM"]
    )["Parameter"]["Value"]

    # マスターユーザーで Aurora Writer に直接接続
    conninfo = (
        f"host={aurora_endpoint} port=5432 dbname={db_name} "
        f"user={master['username']} password={master['password']} sslmode=require"
    )
    with psycopg.connect(conninfo) as conn:
        conn.autocommit = True
        with conn.cursor() as cur:
            # sql.Identifier でユーザー名を安全にクォートする
            cur.execute(
                sql.SQL("ALTER USER {} WITH PASSWORD %s").format(
                    sql.Identifier(pending["username"])
                ),
                (pending["password"],),
            )
    logger.info("DBパスワード変更完了", extra={"username": pending["username"]})


def _test_secret(arn: str, token: str) -> None:
    """新しいパスワードで Aurora に直接接続して疎通確認"""
    pending = json.loads(
        sm_client.get_secret_value(SecretId=arn, VersionStage="AWSPENDING", VersionId=token)["SecretString"]
    )

    aurora_endpoint = ssm_client.get_parameter(
        Name=os.environ["AURORA_ENDPOINT_PARAM"]
    )["Parameter"]["Value"]
    db_name = ssm_client.get_parameter(
        Name=os.environ["DB_NAME_PARAM"]
    )["Parameter"]["Value"]

    conninfo = (
        f"host={aurora_endpoint} port=5432 dbname={db_name} "
        f"user={pending['username']} password={pending['password']} sslmode=require"
    )
    with psycopg.connect(conninfo) as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT 1")
    logger.info("新パスワードでの接続テスト成功")


def _finish_secret(arn: str, token: str) -> None:
    """AWSPENDING を AWSCURRENT に昇格"""
    metadata = sm_client.describe_secret(SecretId=arn)
    current_version = next(
        v for v, stages in metadata["VersionIdsToStages"].items()
        if "AWSCURRENT" in stages
    )

    if current_version == token:
        logger.info("既に AWSCURRENT — 完了")
        return

    sm_client.update_secret_version_stage(
        SecretId=arn,
        VersionStage="AWSCURRENT",
        MoveToVersionId=token,
        RemoveFromVersionId=current_version,
    )
    logger.info("ローテーション完了: AWSCURRENT 更新")
