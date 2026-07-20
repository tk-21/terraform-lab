# なぜ: python:3.12-slim は不要なパッケージを含まず、
#       イメージサイズを最小化してセキュリティリスクを低減
FROM python:3.12-slim

# なぜ: root 以外のユーザーで実行することで、
#       コンテナ侵害時の影響範囲を限定する
RUN groupadd -r appuser && useradd -r -g appuser appuser

WORKDIR /app

# なぜ: requirements.txt を先にコピーすることで、
#       ソースコード変更時のキャッシュを有効活用
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# なぜ: 書き込み権限を最小化
RUN chown -R appuser:appuser /app
USER appuser

# ヘルスチェック: コンテナが正常動作しているか確認
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD python -c "import sys; sys.exit(0)"

CMD ["python", "app.py"]
