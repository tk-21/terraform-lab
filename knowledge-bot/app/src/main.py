import json
import logging
import os
from pathlib import Path
import re

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel

from .prompts import SYSTEM
from .rag_kb import retrieve_and_generate
from .rag_mvp import simple_retrieve

# アプリ全体で使う実行モードやBedrock接続先を環境変数から読み込む。
REGION = os.getenv("AWS_REGION", "ap-northeast-1")
MODE = os.getenv("RAG_MODE", "MVP")  # MVP or KB
MODEL_ID = os.getenv("BEDROCK_MODEL_ID", "global.anthropic.claude-sonnet-4-20250514-v1:0")
KB_ID = os.getenv("KNOWLEDGE_BASE_ID", "")
KB_MODEL_ARN = os.getenv(
    "KB_MODEL_ARN", ""
)  # 例: global.anthropic.claude-sonnet-4-20250514-v1:0

BASE_DIR = Path(__file__).resolve().parent
REPO_ROOT = BASE_DIR.parents[1]
SAMPLE_KNOWLEDGE_DIR = REPO_ROOT / "docs" / "sample_knowledge"
# FastAPI本体と、静的ファイル・テンプレートの公開設定。
app = FastAPI(title="Knowledge Bot")
app.mount("/static", StaticFiles(directory=BASE_DIR / "static"), name="static")
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))
logger = logging.getLogger(__name__)


def _split_markdown_sections(markdown_text: str) -> list[dict[str, str]]:
    title = ""
    current_section = ""
    body_lines: list[str] = []
    chunks: list[dict[str, str]] = []

    def flush() -> None:
        nonlocal body_lines
        text = "\n".join(line.strip() for line in body_lines if line.strip()).strip()
        if text:
            chunks.append(
                {
                    "source": title or "sample_knowledge",
                    "section": current_section or "本文",
                    "text": text,
                }
            )
        body_lines = []

    for raw_line in markdown_text.splitlines():
        line = raw_line.strip()
        if not line:
            body_lines.append("")
            continue

        heading = re.match(r"^(#{1,3})\s+(.*)$", line)
        if heading:
            level = len(heading.group(1))
            heading_text = heading.group(2).strip()
            if level == 1 and not title:
                title = heading_text
                current_section = "概要"
            else:
                flush()
                current_section = heading_text
            continue

        body_lines.append(raw_line)

    flush()
    return chunks


def load_mvp_chunks() -> list[dict[str, str]]:
    chunks: list[dict[str, str]] = []
    if SAMPLE_KNOWLEDGE_DIR.exists():
        for path in sorted(SAMPLE_KNOWLEDGE_DIR.glob("*.md")):
            if path.name.lower() == "readme.md":
                continue
            text = path.read_text(encoding="utf-8")
            chunks.extend(_split_markdown_sections(text))

    if chunks:
        return chunks

    return [
        {"source": "Wiki:VPN", "section": "接続方法", "text": "VPNは…（例）"},
        {"source": "Runbook:障害対応", "section": "一次切り分け", "text": "障害時は…（例）"},
        {"source": "規程:就業", "section": "休暇", "text": "有給は…（例）"},
    ]


CHUNKS = load_mvp_chunks()


class AskReq(BaseModel):
    question: str


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/", response_class=HTMLResponse)
def index(request: Request):
    return templates.TemplateResponse(
        request=request,
        name="index.html",
        context={"title": "Knowledge Bot"},
    )


def invoke_model_claude(question: str, context: str) -> str:
    # 検索で集めた文脈をClaudeに渡し、最終回答だけを生成する。
    try:
        client = boto3.client("bedrock-runtime", region_name=REGION)
        body = {
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 800,
            "system": SYSTEM,
            "messages": [
                {
                    "role": "user",
                    "content": [{"type": "text", "text": f"質問: {question}\n\nナレッジ:\n{context}"}],
                }
            ],
        }
        resp = client.invoke_model(
            modelId=MODEL_ID,
            body=json.dumps(body).encode("utf-8"),
            accept="application/json",
            contentType="application/json",
        )
        payload = json.loads(resp["body"].read())
        return payload["content"][0]["text"]
    except ClientError as err:
        code = err.response.get("Error", {}).get("Code", "Unknown")
        message = err.response.get("Error", {}).get("Message", str(err))
        logger.exception("Bedrock invoke failed: code=%s", code)
        if code in {"AccessDeniedException", "UnrecognizedClientException"}:
            raise HTTPException(status_code=401, detail="AWS認証または権限設定を確認してください。")
        if code == "ThrottlingException":
            raise HTTPException(status_code=429, detail="Bedrock呼び出しが混雑しています。時間をおいて再試行してください。")
        if code == "ResourceNotFoundException":
            raise HTTPException(
                status_code=400,
                detail="モデル利用設定が未完了です。Bedrockの利用申請状態を確認してください。",
            )
        raise HTTPException(status_code=502, detail=f"Bedrock呼び出しに失敗しました: {message}")
    except (BotoCoreError, ValueError) as err:
        logger.exception("Unexpected model invocation error")
        raise HTTPException(status_code=500, detail=f"モデル呼び出し処理でエラーが発生しました: {err}")


@app.post("/ask")
def ask(req: AskReq):
    try:
        # KBモードでは Bedrock Knowledge Bases を直接検索して回答を作る。
        if MODE.upper() == "KB":
            if not KB_ID:
                return {"answer": "KBモード設定が不足しています（KNOWLEDGE_BASE_ID）", "citations": []}
            text, cites = retrieve_and_generate(REGION, KB_ID, KB_MODEL_ARN, req.question)
            return {"answer": text, "citations": cites}

        # MVPモードではローカルの簡易チャンク検索結果を文脈として使う。
        hits = simple_retrieve(CHUNKS, req.question, k=4)
        if not hits:
            return {
                "answer": "根拠となるナレッジが見つからないため回答できません。原本/窓口を確認してください。",
                "citations": [],
            }
        ctx = "\n\n".join([f"[{h['source']} / {h['section']}]\n{h['text']}" for h in hits])
        ans = invoke_model_claude(req.question, ctx)
        citations = [{"source": h["source"], "section": h["section"]} for h in hits]
        return {"answer": ans, "citations": citations}
    except HTTPException:
        raise
    except (ClientError, BotoCoreError) as err:
        logger.exception("RAG request failed")
        raise HTTPException(status_code=502, detail=f"AWS連携処理で失敗しました: {err}")
