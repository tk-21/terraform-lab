"""
AI Gateway: コスト認識型 LLM ルーター
vLLM (GPU Spot) と Amazon Bedrock (Claude Haiku) をコスト・可用性に応じて動的切り替え
"""
from __future__ import annotations

import asyncio
import json
import os
import time
from contextlib import asynccontextmanager

import boto3
import httpx
import tiktoken
from aws_lambda_powertools import Logger
from fastapi import FastAPI, HTTPException
from opentelemetry import metrics as otel_metrics
from pydantic import BaseModel

from metrics import (
    cost_per_request,
    inference_latency,
    init_metrics,
    routing_counter,
)

logger = Logger(service="ai-gateway")


# ─────────────────────────────────────────────────
# コスト試算
# ─────────────────────────────────────────────────

class CostCalculator:
    """
    vLLM vs Bedrock のリクエストコストを試算する

    コスト根拠 (2024年時点):
      - g4dn.xlarge Spot 東京: ~$0.16/h
      - Claude Haiku 3.5: $0.80/1M input + $4.00/1M output tokens
        (ap-northeast-1 Bedrock 料金表より)
      - Phi-3-mini の実測スループット (g4dn.xlarge): 約 50 tokens/s
    """

    GPU_SPOT_COST_PER_HOUR: float = 0.16
    BEDROCK_INPUT_COST_PER_1M: float = 0.80
    BEDROCK_OUTPUT_COST_PER_1M: float = 4.00
    # g4dn.xlarge 1枚での実測値
    VLLM_THROUGHPUT_TOKENS_PER_SEC: float = 50.0

    @classmethod
    def estimate_vllm_cost(cls, prompt_tokens: int, max_tokens: int) -> float:
        # 生成トークン数の期待値: max_tokens × 0.7 (実測補正係数)
        estimated_output_tokens = max_tokens * 0.7
        generation_time_sec = estimated_output_tokens / cls.VLLM_THROUGHPUT_TOKENS_PER_SEC
        return (generation_time_sec / 3600.0) * cls.GPU_SPOT_COST_PER_HOUR

    @classmethod
    def estimate_bedrock_cost(cls, prompt_tokens: int, max_tokens: int) -> float:
        input_cost = (prompt_tokens / 1_000_000) * cls.BEDROCK_INPUT_COST_PER_1M
        output_cost = (max_tokens / 1_000_000) * cls.BEDROCK_OUTPUT_COST_PER_1M
        return input_cost + output_cost


# ─────────────────────────────────────────────────
# ルーティングロジック
# ─────────────────────────────────────────────────

class Router:
    """
    コスト・可用性・予算を考慮してバックエンド (vLLM / Bedrock) を選択する

    優先順位:
      1. 予算超過        → Bedrock (コスト制御: 時間ウィンドウ内コストが上限を超えた場合)
      2. vLLM 不可      → Bedrock (可用性: 3秒 HealthCheck タイムアウトで判定)
      3. vLLM が安価    → vLLM    (コスト最適)
      4. デフォルト     → vLLM    (GPU稼働率を最大化してSpotコストを回収する)
    """

    VLLM_URL: str = os.getenv("VLLM_URL", "http://vllm-service:8000")
    BUDGET_SSM_KEY: str = os.getenv("BUDGET_SSM_KEY", "/ai-inference/hourly-budget-usd")
    # vLLM HealthCheck の最大待機時間: 3秒を超えるとユーザー体験に影響するため短く設定
    HEALTH_CHECK_TIMEOUT_SEC: float = 3.0

    def __init__(self) -> None:
        # AWS_DEFAULT_REGION は k8s/gateway/deployment.yaml の env で注入される
        self._ssm = boto3.client("ssm", region_name=os.getenv("AWS_DEFAULT_REGION", "ap-northeast-1"))
        self._hourly_cost: float = 0.0
        self._cost_window_start: float = time.time()

    def _get_budget_limit(self) -> float:
        """SSM から時間あたり予算上限を取得 (取得失敗時はデフォルト $1.00/h)"""
        try:
            resp = self._ssm.get_parameter(Name=self.BUDGET_SSM_KEY)
            return float(resp["Parameter"]["Value"])
        except Exception:
            return 1.0

    def _is_budget_exceeded(self) -> bool:
        now = time.time()
        # 1時間経過でウィンドウをリセット: 累積コストが次の時間帯に持ち越されないようにする
        if now - self._cost_window_start > 3600:
            self._hourly_cost = 0.0
            self._cost_window_start = now
        return self._hourly_cost >= self._get_budget_limit()

    async def _is_vllm_available(self) -> bool:
        """vLLM ヘルスチェック (HEALTH_CHECK_TIMEOUT_SEC 秒でタイムアウト)"""
        try:
            async with httpx.AsyncClient(timeout=self.HEALTH_CHECK_TIMEOUT_SEC) as client:
                resp = await client.get(f"{self.VLLM_URL}/health")
                return resp.status_code == 200
        except Exception:
            return False

    async def select_backend(self, prompt_tokens: int, max_tokens: int) -> tuple[str, str]:
        """(backend, reason) のタプルを返す"""
        if self._is_budget_exceeded():
            return "bedrock", "budget_exceeded"

        if not await self._is_vllm_available():
            return "bedrock", "vllm_unavailable"

        vllm_cost = CostCalculator.estimate_vllm_cost(prompt_tokens, max_tokens)
        bedrock_cost = CostCalculator.estimate_bedrock_cost(prompt_tokens, max_tokens)

        if vllm_cost <= bedrock_cost:
            return "vllm", "cost_optimal"
        return "bedrock", "cost_optimal"

    def record_cost(self, cost: float) -> None:
        self._hourly_cost += cost


# ─────────────────────────────────────────────────
# バックエンド呼び出し
# ─────────────────────────────────────────────────

async def _call_vllm(messages: list[dict], max_tokens: int, temperature: float) -> dict:
    """vLLM OpenAI 互換エンドポイントへ POST"""
    async with httpx.AsyncClient(timeout=60.0) as client:
        resp = await client.post(
            f"{Router.VLLM_URL}/v1/chat/completions",
            json={
                "model": "microsoft/Phi-3-mini-4k-instruct",
                "messages": messages,
                "max_tokens": max_tokens,
                "temperature": temperature,
            },
        )
        resp.raise_for_status()
        data = resp.json()
        data["_backend"] = "vllm"
        return data


async def _call_bedrock(messages: list[dict], max_tokens: int, temperature: float) -> dict:
    """
    Amazon Bedrock (Claude Haiku) を呼び出し OpenAI 互換形式で返す

    boto3 は同期クライアントのため run_in_executor でイベントループをブロックしないようにする
    """
    # AWS_DEFAULT_REGION は k8s/gateway/deployment.yaml の env で注入される
    bedrock = boto3.client("bedrock-runtime", region_name=os.getenv("AWS_DEFAULT_REGION", "ap-northeast-1"))
    body = json.dumps({
        "anthropic_version": "bedrock-2023-05-31",
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": temperature,
    })

    loop = asyncio.get_event_loop()
    response = await loop.run_in_executor(
        None,
        lambda: bedrock.invoke_model(
            modelId="anthropic.claude-haiku-4-5-20251001",
            body=body,
            contentType="application/json",
        ),
    )
    bedrock_resp = json.loads(response["body"].read())

    # Bedrock Messages API → OpenAI Chat Completions 形式に変換
    return {
        "id": f"chatcmpl-bedrock-{int(time.time())}",
        "object": "chat.completion",
        "model": "claude-haiku-via-bedrock",
        "choices": [{
            "index": 0,
            "message": {
                "role": "assistant",
                "content": bedrock_resp["content"][0]["text"],
            },
            "finish_reason": bedrock_resp.get("stop_reason", "stop"),
        }],
        "usage": {
            "prompt_tokens": bedrock_resp.get("usage", {}).get("input_tokens", 0),
            "completion_tokens": bedrock_resp.get("usage", {}).get("output_tokens", 0),
        },
        "_backend": "bedrock",
    }


# ─────────────────────────────────────────────────
# FastAPI アプリ
# ─────────────────────────────────────────────────

_router = Router()
# tiktokenはスレッドセーフなためモジュールレベルで初期化
_enc = tiktoken.get_encoding("cl100k_base")


@asynccontextmanager
async def lifespan(app: FastAPI):
    # OTEL MeterProvider を起動時に一度だけ初期化する
    init_metrics()
    logger.info("AI Gateway 起動: OTEL計装完了")
    yield
    logger.info("AI Gateway シャットダウン")


app = FastAPI(
    title="AI Gateway",
    description="コスト認識型 LLM ルーター (vLLM / Amazon Bedrock)",
    version="1.0.0",
    lifespan=lifespan,
)


class ChatRequest(BaseModel):
    model: str = "auto"
    messages: list[dict]
    max_tokens: int = 512
    temperature: float = 0.7


@app.get("/health")
async def health() -> dict:
    return {"status": "ok", "vllm_url": Router.VLLM_URL}


@app.post("/v1/chat/completions")
async def chat_completions(req: ChatRequest) -> dict:
    start_time = time.time()

    # メッセージ全体をテキスト連結してトークン数を事前推定する
    # 推定値はルーティング判断のみに使用し、実際の課金には影響しない
    prompt_text = " ".join(
        m.get("content", "")
        for m in req.messages
        if isinstance(m.get("content"), str)
    )
    prompt_tokens = len(_enc.encode(prompt_text))

    backend, reason = await _router.select_backend(prompt_tokens, req.max_tokens)
    logger.info(
        "ルーティング決定",
        backend=backend,
        reason=reason,
        prompt_tokens=prompt_tokens,
    )
    routing_counter.add(1, {"backend": backend, "reason": reason})

    try:
        if backend == "vllm":
            response_data = await _call_vllm(req.messages, req.max_tokens, req.temperature)
            actual_cost = CostCalculator.estimate_vllm_cost(prompt_tokens, req.max_tokens)
        else:
            response_data = await _call_bedrock(req.messages, req.max_tokens, req.temperature)
            actual_cost = CostCalculator.estimate_bedrock_cost(prompt_tokens, req.max_tokens)

        _router.record_cost(actual_cost)
        latency = time.time() - start_time

        inference_latency.record(latency, {"backend": backend})
        cost_per_request.record(actual_cost, {"backend": backend})

        logger.info(
            "推論完了",
            backend=backend,
            latency_sec=round(latency, 3),
            cost_usd=round(actual_cost, 6),
        )
        return response_data

    except Exception as exc:
        logger.error("推論エラー", backend=backend, error=str(exc))
        raise HTTPException(status_code=502, detail=str(exc)) from exc
