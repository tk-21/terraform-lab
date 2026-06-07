from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from db.connection import get_connection
from db import queries

router = APIRouter(prefix="/items")


class Item(BaseModel):
    name: str


@router.get("/")
def list_items():
    with get_connection() as conn:
        return queries.list_items(conn)


@router.post("/", status_code=201)
def create_item(item: Item):
    with get_connection() as conn:
        return queries.create_item(conn, item.name)
