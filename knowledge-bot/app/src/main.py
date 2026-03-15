import json
import logging
import os
from pathlib import Path

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

REGION = os.getenv("AWS_REGION", "ap-northeast-1")
MODE = os.getenv("RAG_MODE", "MVP")  # MVP or KB
MODEL_ID = os.getenv("BEDROCK_MODEL_ID", "anthropic.claude-3-5-sonnet-20240620-v1:0")
KB_ID = os.getenv("KNOWLEDGE_BASE_ID", "")
KB_MODEL_ARN = os.getenv(
    "KB_MODEL_ARN", ""
)  # 例: arn:aws:bedrock:ap-northeast-1::foundation-model/anthropic.claude-3-5-sonnet-20240620-v1:0

# MVP用ダミーチャンク（発表時は docs/ からロードでもOK）
CHUNKS = [
    {"source": "Wiki:VPN", "section": "接続方法", "text": "VPNは…（例）"},
    {"source": "Runbook:障害対応", "section": "一次切り分け", "text": "障害時は…（例）"},
    {"source": "規程:就業", "section": "休暇", "text": "有給は…（例）"},
]

BASE_DIR = Path(__file__).resolve().parent
app = FastAPI(title="Knowledge Bot")
app.mount("/static", StaticFiles(directory=BASE_DIR / "static"), name="static")
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))
logger = logging.getLogger(__name__)


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
        if MODE.upper() == "KB":
            if not KB_ID:
                return {"answer": "KBモード設定が不足しています（KNOWLEDGE_BASE_ID）", "citations": []}
            text, cites = retrieve_and_generate(REGION, KB_ID, KB_MODEL_ARN, req.question)
            return {"answer": text, "citations": cites}

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
