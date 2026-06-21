# --- ビルドステージ ---
# マルチステージビルドでイメージサイズを最小化
FROM python:3.12-slim AS builder

WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt

# --- 実行ステージ ---
FROM python:3.12-slim

# セキュリティ: root 以外のユーザーで実行
RUN useradd --create-home --shell /bin/bash appuser

WORKDIR /app
COPY --from=builder /root/.local /home/appuser/.local
COPY app.py .

USER appuser
ENV PATH=/home/appuser/.local/bin:$PATH

EXPOSE 8080
CMD ["python", "app.py"]
