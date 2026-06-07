from fastapi import APIRouter
from db.connection import get_connection

router = APIRouter()


@router.get("/health")
def health_check():
    """ALB ヘルスチェック用エンドポイント + DB 接続確認"""
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT 1")
    return {"status": "healthy", "db": "connected"}
