"""
シンプルな HTTP サーバー — ECS Fargate 動作確認用
デプロイされたコミット SHA を返すことで CD が正しく動いたか確認できる
"""
import os
import http.server
import json
from datetime import datetime, timezone

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            body = json.dumps({"status": "healthy"}).encode()
            self.send_response(200)
        else:
            body = json.dumps({
                "message": "Hello from ECS Fargate!",
                "image_tag": os.environ.get("IMAGE_TAG", "unknown"),
                "hostname": os.environ.get("HOSTNAME", "unknown"),
                "timestamp": datetime.now(timezone.utc).isoformat(),
            }).encode()
            self.send_response(200)

        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        print(f"[{datetime.now(timezone.utc).isoformat()}] {format % args}")

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    server = http.server.HTTPServer(("", port), Handler)
    print(f"Server starting on port {port}")
    server.serve_forever()
