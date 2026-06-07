"""
RDS Proxy IAM 認証による接続管理

IAM 認証フロー:
1. ECS タスクロールで boto3 が IAM 認証トークンを生成（15分有効）
2. トークンをパスワードとして RDS Proxy に渡す
3. Proxy がトークンを検証し、Aurora には Secrets Manager のパスワードで接続
→ アプリコードに DB パスワードが一切現れない
"""
import os
import boto3
import psycopg
from aws_lambda_powertools import Logger

logger = Logger(service="aurora-rds-proxy-lab")

_ssm = boto3.client("ssm", region_name=os.environ.get("AWS_REGION", "ap-northeast-1"))
_rds = boto3.client("rds", region_name=os.environ.get("AWS_REGION", "ap-northeast-1"))

_proxy_endpoint: str = ""
_db_name: str = ""


def _get_ssm(param_name: str) -> str:
    """SSM Parameter Store から値を取得"""
    return _ssm.get_parameter(Name=param_name)["Parameter"]["Value"]


def _generate_iam_token(host: str, port: int, db_user: str) -> str:
    """
    IAM 認証トークン生成
    有効期限 15 分 → 接続ごとに生成してもオーバーヘッドは小さい
    本番では接続プールと組み合わせて 10 分ごとに更新する
    """
    return _rds.generate_db_auth_token(
        DBHostname=host,
        Port=port,
        DBUsername=db_user,
        Region=os.environ.get("AWS_REGION", "ap-northeast-1"),
    )


def init_db_config() -> None:
    """アプリ起動時に DB 設定を初期化"""
    global _proxy_endpoint, _db_name
    _proxy_endpoint = _get_ssm(os.environ["PROXY_ENDPOINT_PARAM"])
    _db_name = _get_ssm(os.environ["DB_NAME_PARAM"])
    logger.info("DB設定初期化完了", extra={"proxy_endpoint": _proxy_endpoint})


def get_connection() -> psycopg.Connection:
    """
    RDS Proxy に IAM 認証で接続して返す
    呼び出し元は with ステートメントで使用すること
    """
    db_user = os.environ.get("DB_USER", "appuser")
    token = _generate_iam_token(_proxy_endpoint, 5432, db_user)

    conn_str = (
        f"host={_proxy_endpoint} "
        f"port=5432 "
        f"dbname={_db_name} "
        f"user={db_user} "
        f"password={token} "
        f"sslmode=require"  # Proxy の require_tls=true に対応
    )
    return psycopg.connect(conn_str)
