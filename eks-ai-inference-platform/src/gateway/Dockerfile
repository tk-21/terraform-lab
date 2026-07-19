# arm64/Graviton2 向けビルド: AI Gateway は CPU バウンドなので GPU 不要
# multi-stage ビルドで最終イメージからビルドツール類を除去しサイズを最小化する
FROM --platform=linux/arm64 python:3.12-slim-bookworm AS builder

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --target=/app/deps -r requirements.txt

FROM --platform=linux/arm64 python:3.12-slim-bookworm
WORKDIR /app

# root 以外で実行: EKS の PodSecurityStandard restricted プロファイルへの準拠
RUN groupadd -r appgroup && useradd -r -g appgroup appuser

COPY --from=builder /app/deps /app/deps
COPY . .

ENV PYTHONPATH=/app/deps
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

USER appuser

# EKS readinessProbe が参照するヘルスチェック
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')"

CMD ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "2"]
