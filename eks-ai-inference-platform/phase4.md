# Phase 4: AI Gateway — コスト認識ルーティング + Bedrock Fallback

## 前提条件 (Phase 1-3 完了済み)

- vLLM が ClusterIP `vllm-service:8000` で稼働中
- OTEL Collector が稼働中 (カスタムメトリクス受信ポート 4317/4318)
- Bedrock VPC Endpoint 設定済み
- SSM Parameter Store にChatwork Token 格納済み

---

## このフェーズの目標

**AI Gateway (FastAPI)** を EKS にデプロイし、以下を実現する:

1. **コスト認識ルーティング**: リクエストのtoken数を事前推定し、vLLM vs Bedrock のコストを比較して最安ルートを選択
2. **可用性フォールバック**: vLLM が応答しない場合は自動的に Bedrock (Claude Haiku) に切り替え
3. **予算ガード**: 時間あたりコストが閾値を超えた場合 Bedrock に強制切り替え + Chatwork 通知
4. **OTEL計装**: 全リクエストのレイテンシ・コスト・ルーティング先を AMP に送信

---

## 実装手順

### Step 1: AI Gateway ソースコード (`src/gateway/`)

#### `src/gateway/main.py`

```python
"""
AI Gateway: コスト認識型LLMルーター
vLLM (GPU Spot) と Amazon Bedrock (Claude Haiku) を動的に切り替える
"""
from __future__ import annotations

import asyncio
import time
import os
from contextlib import asynccontextmanager

import boto3
import httpx
import tiktoken
from aws_lambda_powertools import Logger
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import StreamingResponse
from opentelemetry import metrics, trace
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from pydantic import BaseModel

logger = Logger(service="ai-gateway")

# === OTEL 計装設定 ===
resource = Resource.create({"service.name": "ai-gateway", "service.version": "1.0"})

# メトリクスプロバイダー: OTEL CollectorにgRPCで送信
otel_endpoint = os.getenv("OTEL_ENDPOINT", "http://otel-collector:4317")
metric_exporter = OTLPMetricExporter(endpoint=otel_endpoint, insecure=True)
reader = PeriodicExportingMetricReader(metric_exporter, export_interval_millis=15000)
provider = MeterProvider(resource=resource, metric_readers=[reader])
metrics.set_meter_provider(provider)
meter = metrics.get_meter("ai-gateway")

# カスタムメトリクス定義
inference_latency = meter.create_histogram(
    "inference_latency_seconds",
    description="推論エンドツーエンドレイテンシ",
    unit="s",
)
cost_per_request = meter.create_histogram(
    "inference_cost_usd",
    description="リクエストあたりコスト (USD)",
    unit="USD",
)
routing_counter = meter.create_counter(
    "inference_routing_total",
    description="バックエンドごとのルーティング数",
)


# === コスト計算 ===
class CostCalculator:
    """
    vLLM vs Bedrock のリクエストコストを試算するクラス

    コスト根拠 (2024年時点):
    - g4dn.xlarge Spot: ~$0.16/h → 1トークン生成に要する時間で按分
    - Claude Haiku: $0.25/1M input tokens + $1.25/1M output tokens
    """

    # g4dn.xlarge Spot 東京リージョン (概算)
    GPU_SPOT_COST_PER_HOUR = 0.16
    # Claude Haiku の公式料金 (ap-northeast-1)
    BEDROCK_INPUT_COST_PER_1M = 0.25
    BEDROCK_OUTPUT_COST_PER_1M = 1.25
    # Phi-3-mini の実測スループット (g4dn.xlarge): 約 50 tokens/sec
    VLLM_THROUGHPUT_TOKENS_PER_SEC = 50.0

    @classmethod
    def estimate_vllm_cost(cls, prompt_tokens: int, max_tokens: int) -> float:
        """vLLMでの推論コスト試算"""
        # 生成トークン数 × 生成時間 × GPU時間単価
        estimated_output_tokens = max_tokens * 0.7  # 実際の生成はmax_tokensより少ない
        generation_time_sec = estimated_output_tokens / cls.VLLM_THROUGHPUT_TOKENS_PER_SEC
        cost = (generation_time_sec / 3600) * cls.GPU_SPOT_COST_PER_HOUR
        return cost

    @classmethod
    def estimate_bedrock_cost(cls, prompt_tokens: int, max_tokens: int) -> float:
        """Bedrockでの推論コスト試算"""
        input_cost = (prompt_tokens / 1_000_000) * cls.BEDROCK_INPUT_COST_PER_1M
        output_cost = (max_tokens / 1_000_000) * cls.BEDROCK_OUTPUT_COST_PER_1M
        return input_cost + output_cost


# === ルーティングロジック ===
class Router:
    """
    コスト・可用性・予算を考慮してバックエンドを選択するルーター
    """

    VLLM_URL = os.getenv("VLLM_URL", "http://vllm-service:8000")
    BUDGET_SSM_KEY = os.getenv("BUDGET_SSM_KEY", "/ai-inference/hourly-budget-usd")

    def __init__(self):
        self.ssm = boto3.client("ssm", region_name="ap-northeast-1")
        self.bedrock = boto3.client("bedrock-runtime", region_name="ap-northeast-1")
        self._hourly_cost = 0.0
        self._cost_window_start = time.time()

    def _get_budget_limit(self) -> float:
        """SSMから時間あたり予算上限を取得"""
        try:
            response = self.ssm.get_parameter(Name=self.BUDGET_SSM_KEY)
            return float(response["Parameter"]["Value"])
        except Exception:
            # SSM取得失敗時はデフォルト予算 $1.00/h
            return 1.0

    def _is_budget_exceeded(self) -> bool:
        """時間ウィンドウをリセットしながら予算を確認"""
        now = time.time()
        if now - self._cost_window_start > 3600:
            # 1時間経過したらコストウィンドウをリセット
            self._hourly_cost = 0.0
            self._cost_window_start = now
        return self._hourly_cost >= self._get_budget_limit()

    async def _is_vllm_available(self) -> bool:
        """vLLM ヘルスチェック (タイムアウト: 3秒)"""
        try:
            async with httpx.AsyncClient(timeout=3.0) as client:
                resp = await client.get(f"{self.VLLM_URL}/health")
                return resp.status_code == 200
        except Exception:
            return False

    async def route(
        self, prompt_tokens: int, max_tokens: int
    ) -> tuple[str, str]:
        """
        ルーティング決定ロジック (優先順位):
        1. 予算超過 → Bedrock (コスト制御)
        2. vLLM 不可 → Bedrock (可用性)
        3. vLLM コスト < Bedrock コスト → vLLM (コスト最適)
        4. デフォルト → vLLM (GPU活用率向上)
        """
        if self._is_budget_exceeded():
            return "bedrock", "budget_exceeded"

        if not await self._is_vllm_available():
            return "bedrock", "vllm_unavailable"

        vllm_cost = CostCalculator.estimate_vllm_cost(prompt_tokens, max_tokens)
        bedrock_cost = CostCalculator.estimate_bedrock_cost(prompt_tokens, max_tokens)

        if vllm_cost <= bedrock_cost:
            return "vllm", "cost_optimal"
        else:
            return "bedrock", "cost_optimal"


# === FastAPI アプリ ===
router_instance = Router()


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("AI Gateway 起動: OTEL計装完了")
    yield
    logger.info("AI Gateway シャットダウン")


app = FastAPI(
    title="AI Gateway",
    description="コスト認識型 LLM ルーター (vLLM / Amazon Bedrock)",
    lifespan=lifespan,
)


class ChatRequest(BaseModel):
    model: str = "auto"  # "auto" でルーター自動選択
    messages: list[dict]
    max_tokens: int = 512
    temperature: float = 0.7
    stream: bool = False


@app.get("/health")
async def health():
    return {"status": "ok", "vllm_url": Router.VLLM_URL}


@app.post("/v1/chat/completions")
async def chat_completions(req: ChatRequest, request: Request):
    start_time = time.time()

    # トークン数を事前推定 (OpenAI tiktoken使用)
    enc = tiktoken.get_encoding("cl100k_base")
    prompt_text = " ".join(
        [m.get("content", "") for m in req.messages if isinstance(m.get("content"), str)]
    )
    prompt_tokens = len(enc.encode(prompt_text))

    # ルーティング決定
    backend, reason = await router_instance.route(prompt_tokens, req.max_tokens)

    logger.info(f"ルーティング決定: {backend} (理由: {reason}, 推定トークン: {prompt_tokens})")

    # ルーティングカウンター更新
    routing_counter.add(1, {"backend": backend, "reason": reason})

    try:
        if backend == "vllm":
            response_data = await _call_vllm(req)
            actual_cost = CostCalculator.estimate_vllm_cost(prompt_tokens, req.max_tokens)
        else:
            response_data = await _call_bedrock(req)
            actual_cost = CostCalculator.estimate_bedrock_cost(prompt_tokens, req.max_tokens)

        # コスト記録 (予算監視用)
        router_instance._hourly_cost += actual_cost

        latency = time.time() - start_time

        # OTELメトリクス送信
        inference_latency.record(latency, {"backend": backend})
        cost_per_request.record(actual_cost, {"backend": backend})

        logger.info(
            f"推論完了: backend={backend}, latency={latency:.3f}s, cost=${actual_cost:.6f}"
        )

        return response_data

    except Exception as e:
        logger.error(f"推論エラー (backend={backend}): {e}")
        raise HTTPException(status_code=502, detail=str(e))


async def _call_vllm(req: ChatRequest) -> dict:
    """vLLM OpenAI互換APIを呼び出す"""
    async with httpx.AsyncClient(timeout=60.0) as client:
        resp = await client.post(
            f"{Router.VLLM_URL}/v1/chat/completions",
            json={
                "model": "microsoft/Phi-3-mini-4k-instruct",
                "messages": req.messages,
                "max_tokens": req.max_tokens,
                "temperature": req.temperature,
            },
        )
        resp.raise_for_status()
        data = resp.json()
        # レスポンスにバックエンド情報を付与 (デバッグ用)
        data["_backend"] = "vllm"
        return data


async def _call_bedrock(req: ChatRequest) -> dict:
    """Amazon Bedrock (Claude Haiku) を呼び出し、OpenAI互換形式で返す"""
    import json

    bedrock = boto3.client("bedrock-runtime", region_name="ap-northeast-1")

    # Bedrock Messages API形式に変換
    body = json.dumps({
        "anthropic_version": "bedrock-2023-05-31",
        "messages": req.messages,
        "max_tokens": req.max_tokens,
        "temperature": req.temperature,
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

    # OpenAI互換形式に変換して返す
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
```

#### `src/gateway/requirements.txt`

```
fastapi==0.111.0
uvicorn[standard]==0.30.1
httpx==0.27.0
boto3==1.34.0
tiktoken==0.7.0
opentelemetry-sdk==1.25.0
opentelemetry-exporter-otlp-proto-grpc==1.25.0
aws-lambda-powertools==2.39.0
pydantic==2.7.0
```

#### `src/gateway/Dockerfile`

```dockerfile
# arm64/Graviton2 向けビルド (コスト最適化)
FROM python:3.12-slim-bookworm AS builder

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --target=/app/deps -r requirements.txt

FROM python:3.12-slim-bookworm
WORKDIR /app

# セキュリティ: root以外で実行
RUN groupadd -r appgroup && useradd -r -g appgroup appuser

COPY --from=builder /app/deps /app/deps
COPY . .

ENV PYTHONPATH=/app/deps
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

USER appuser

# ヘルスチェック: EKS readinessProbeが参照
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')"

CMD ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "2"]
```

### Step 2: Kubernetes マニフェスト (`k8s/gateway/`)

#### `k8s/gateway/deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ai-gateway
  namespace: ai-inference
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ai-gateway
  template:
    metadata:
      labels:
        app: ai-gateway
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
    spec:
      serviceAccountName: ai-gateway-sa
      # arm64ノード (Graviton) に配置: Gateway はCPUバウンドなのでGPU不要
      nodeSelector:
        kubernetes.io/arch: arm64
      containers:
        - name: ai-gateway
          # ECR にプッシュしたイメージを使用 (VPC Endpoint経由でPull)
          image: ACCOUNT_ID.dkr.ecr.ap-northeast-1.amazonaws.com/ai-gateway:latest
          ports:
            - containerPort: 8080
          env:
            - name: VLLM_URL
              value: "http://vllm-service.ai-inference.svc.cluster.local:8000"
            - name: OTEL_ENDPOINT
              value: "http://otel-collector.monitoring.svc.cluster.local:4317"
            - name: BUDGET_SSM_KEY
              value: "/ai-inference/hourly-budget-usd"
            - name: AWS_DEFAULT_REGION
              value: "ap-northeast-1"
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              cpu: "1000m"
              memory: "512Mi"
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 30
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: ai-gateway-service
  namespace: ai-inference
spec:
  selector:
    app: ai-gateway
  ports:
    - port: 80
      targetPort: 8080
  type: ClusterIP
---
# ALB Ingress: 外部クライアントからのエントリポイント
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ai-gateway-ingress
  namespace: ai-inference
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    # レート制限: APIの過剰利用を防ぐ (Phase 5のKEDAスケーリングと連動)
    alb.ingress.kubernetes.io/load-balancer-attributes: >
      routing.http2.enabled=true,
      idle_timeout.timeout_seconds=60
spec:
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ai-gateway-service
                port:
                  number: 80
```

### Step 3: 予算アラート Lambda + Chatwork通知

```python
# src/cost_lambda/main.py
"""
時間コスト監視Lambda:
CloudWatch Alarmが発火 → EventBridge → このLambda → Chatwork通知
"""
import json
import urllib.parse
import urllib.request

import boto3
from aws_lambda_powertools import Logger
from aws_lambda_powertools.utilities.typing import LambdaContext

logger = Logger(service="cost-alert-lambda")
ssm = boto3.client("ssm", region_name="ap-northeast-1")


def _get_chatwork_credentials() -> tuple[str, str]:
    """SSMからChatwork認証情報を取得"""
    token_param = ssm.get_parameter(
        Name="/chatwork/token", WithDecryption=True
    )
    room_param = ssm.get_parameter(Name="/chatwork/room-id")
    return token_param["Parameter"]["Value"], room_param["Parameter"]["Value"]


def _send_chatwork(message: str) -> None:
    """Chatwork REST APIへ通知送信"""
    token, room_id = _get_chatwork_credentials()
    url = f"https://api.chatwork.com/v2/rooms/{room_id}/messages"
    data = urllib.parse.urlencode({"body": message}).encode()
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "X-ChatWorkToken": token,
            "Content-Type": "application/x-www-form-urlencoded",
        },
        method="POST",
    )
    with urllib.request.urlopen(req) as resp:
        logger.info(f"Chatwork通知送信完了: {resp.status}")


@logger.inject_lambda_context
def handler(event: dict, context: LambdaContext) -> dict:
    """CloudWatch Alarm → EventBridge → Lambda"""
    alarm_name = event.get("detail", {}).get("alarmName", "unknown")
    state = event.get("detail", {}).get("state", {}).get("value", "unknown")

    message = f"""[info][title]🚨 AI推論コストアラート[/title]
アラーム: {alarm_name}
状態: {state}
詳細: 1時間あたりの推論コストが上限を超えました。
自動でBedrockへのルーティングに切り替わっています。
[/info]"""

    _send_chatwork(message)
    logger.info("コストアラート通知完了", alarm_name=alarm_name)
    return {"statusCode": 200}
```

### Step 4: CloudWatch Alarm (Terraform)

```hcl
# terraform/modules/observability/alarms.tf

resource "aws_cloudwatch_metric_alarm" "inference_cost_alarm" {
  alarm_name          = "ai-inference-hourly-cost-exceeded"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  # AMPカスタムメトリクスをCloudWatchに転送 (OTEL → AMP → CW Metric Streams)
  metric_name         = "inference_cost_usd"
  namespace           = "AI/Inference"
  period              = 3600
  statistic           = "Sum"
  # $1.00/h を超えたら通知
  threshold           = 1.0
  alarm_description   = "AI推論の時間コストが上限を超過"

  alarm_actions = [aws_sns_topic.cost_alert.arn]
  ok_actions    = [aws_sns_topic.cost_alert.arn]
}

resource "aws_sns_topic" "cost_alert" {
  name = "ai-inference-cost-alert"
}

resource "aws_sns_topic_subscription" "lambda" {
  topic_arn = aws_sns_topic.cost_alert.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.cost_alert.arn
}
```

---

## 検証手順

```bash
# 1. AI Gateway Pod が稼働していること
kubectl get pods -n ai-inference -l app=ai-gateway

# 2. vLLM経由での推論テスト
ALB_URL=$(kubectl get ingress -n ai-inference ai-gateway-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

curl -s -X POST "https://${ALB_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"EKSとは何ですか？50文字で。"}],"max_tokens":100}' \
  | python3 -m json.tool

# 3. レスポンスに "_backend": "vllm" が含まれていることを確認

# 4. vLLMを停止してBedrockフォールバックを確認
kubectl scale deployment vllm-server -n ai-inference --replicas=0

curl -s -X POST "https://${ALB_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Bedrockとは？"}],"max_tokens":50}' \
  | python3 -m json.tool
# "_backend": "bedrock" であることを確認

# 5. vLLMを元に戻す
kubectl scale deployment vllm-server -n ai-inference --replicas=1

# 6. Grafanaでコストメトリクスが可視化されていることを確認
# inference_cost_usd{backend="vllm"} と inference_cost_usd{backend="bedrock"} が記録されていること
```

---

## Phase 4 完了チェックリスト

- [ ] AI Gateway イメージをECRにプッシュ済み
- [ ] ai-gateway Deployment が arm64ノードで稼働中 (2 replica)
- [ ] vLLM経由の推論確認済み (`_backend: vllm`)
- [ ] vLLM停止時のBedrock自動切り替え確認済み (`_backend: bedrock`)
- [ ] OTEL経由でコストメトリクスがAMPに届いていること確認済み
- [ ] コストアラートLambdaデプロイ済み
- [ ] CloudWatch Alarm設定済み

---

## 口頭説明チェックポイント (15分ノートなし)

- コスト試算ロジック (GPU時間 vs Bedrockトークン課金) を数値で説明できるか?
- tiktokenでプロンプトトークン数を事前推定する意図を説明できるか?
- HealthCheckの3秒タイムアウトがユーザー体験に与える影響を説明できるか?
- Bedrockへのフォールバックで増加するレイテンシをどう許容するか説明できるか?