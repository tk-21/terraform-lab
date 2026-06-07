"""FastAPI エントリポイント"""
from contextlib import asynccontextmanager

from fastapi import FastAPI
from aws_lambda_powertools import Logger

from db.connection import init_db_config
from db.queries import ensure_table, list_items
from db.connection import get_connection
from api import health, items

logger = Logger(service="aurora-rds-proxy-lab")


@asynccontextmanager
async def lifespan(app: FastAPI):
    """起動時: DB 設定初期化 + テーブル作成"""
    init_db_config()
    with get_connection() as conn:
        ensure_table(conn)
    yield


app = FastAPI(title="aurora-rds-proxy-lab", lifespan=lifespan)
app.include_router(health.router)
app.include_router(items.router)
