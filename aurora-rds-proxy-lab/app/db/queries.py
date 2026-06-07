"""
サンプル CRUD クエリ

items テーブル DDL:
  CREATE TABLE IF NOT EXISTS items (
    id         SERIAL PRIMARY KEY,
    name       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
  );
"""
import psycopg


def ensure_table(conn: psycopg.Connection) -> None:
    """items テーブルが存在しない場合に作成する"""
    with conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS items (
                id         SERIAL PRIMARY KEY,
                name       TEXT NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        """)
    conn.commit()


def list_items(conn: psycopg.Connection) -> list[dict]:
    with conn.cursor() as cur:
        cur.execute("SELECT id, name, created_at FROM items ORDER BY id")
        rows = cur.fetchall()
    return [{"id": r[0], "name": r[1], "created_at": str(r[2])} for r in rows]


def create_item(conn: psycopg.Connection, name: str) -> dict:
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO items (name) VALUES (%s) RETURNING id, name, created_at",
            (name,),
        )
        row = cur.fetchone()
    conn.commit()
    return {"id": row[0], "name": row[1], "created_at": str(row[2])}
