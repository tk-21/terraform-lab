FROM python:3.12-slim
WORKDIR /app

# セキュリティ: root以外で実行
RUN useradd -m -u 1000 appuser

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .
USER appuser
EXPOSE 8080

# ECSのHEALTHYヘルスチェック条件に使われる
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')" || exit 1

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
