import asyncio
import time
import aioboto3
from fastapi import FastAPI, Request, Response
from prometheus_client import Counter, Histogram, Gauge, make_asgi_app, REGISTRY
from starlette.middleware.base import BaseHTTPMiddleware

_aioboto3_session = aioboto3.Session()

app = FastAPI()

http_requests_total = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["endpoint", "method", "status_code"],
)
http_request_duration_seconds = Histogram(
    "http_request_duration_seconds",
    "HTTP request duration in seconds",
    ["endpoint"],
    buckets=[0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0],
)
memory_cache_size_bytes = Gauge(
    "memory_cache_size_bytes",
    "Size of in-memory cache in bytes",
)

_memory_cache: list[str] = []


class MetricsMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        endpoint = request.url.path
        method = request.method
        start = time.perf_counter()
        response = await call_next(request)
        duration = time.perf_counter() - start
        status_code = str(response.status_code)
        http_requests_total.labels(endpoint=endpoint, method=method, status_code=status_code).inc()
        http_request_duration_seconds.labels(endpoint=endpoint).observe(duration)
        return response


app.add_middleware(MetricsMiddleware)
app.mount("/metrics", make_asgi_app())


@app.get("/health")
async def health():
    return {"status": "ok"}


def _fib(n: int) -> int:
    if n <= 1:
        return n
    return _fib(n - 1) + _fib(n - 2)


@app.get("/cpu-intensive")
async def cpu_intensive():
    start = time.perf_counter()
    result = _fib(35)
    duration_ms = (time.perf_counter() - start) * 1000
    return {"result": result, "duration_ms": duration_ms}


@app.get("/memory-pressure")
async def memory_pressure():
    chunk = "x" * (1024 * 1024)
    _memory_cache.append(chunk)
    size_mb = len(_memory_cache)
    memory_cache_size_bytes.set(size_mb * 1024 * 1024)
    return {"cache_size_mb": size_mb}


@app.get("/db-latency")
async def db_latency():
    start = time.perf_counter()
    try:
        async with _aioboto3_session.client("dynamodb") as client:
            await client.list_tables()
    except Exception:
        await asyncio.sleep(0.1)
    duration_ms = (time.perf_counter() - start) * 1000
    return {"duration_ms": duration_ms}
