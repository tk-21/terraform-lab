FROM nginx:alpine

# ヘルスチェックエンドポイントと静的コンテンツを配置
COPY html/ /usr/share/nginx/html/

# /health エンドポイント用の設定
RUN echo 'server { \
    listen 80; \
    location /health { \
        access_log off; \
        return 200 "ok\n"; \
        add_header Content-Type text/plain; \
    } \
    location / { \
        root /usr/share/nginx/html; \
        index index.html; \
    } \
}' > /etc/nginx/conf.d/default.conf

EXPOSE 80
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
    CMD wget -qO- http://localhost/health || exit 1
