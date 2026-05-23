# ベースイメージ: arm64対応のslim版でイメージサイズを最小化
# platform指定でFargate arm64（Graviton2）との整合性を担保
FROM --platform=linux/arm64 python:3.12-slim

# セキュリティのため非rootユーザーで実行
RUN useradd -m -u 1000 appuser

WORKDIR /app

# 依存関係のインストールレイヤーをコードより先にコピー
# コードのみの変更でこのレイヤーをキャッシュ再利用するため
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

# 書き込み権限をappuserに付与
RUN chown -R appuser:appuser /app
USER appuser

# 環境変数でS3バケット名を受け取る（タスク定義から注入）
ENV INPUT_BUCKET=""
ENV OUTPUT_BUCKET=""
ENV S3_KEY=""

CMD ["python", "main.py"]
