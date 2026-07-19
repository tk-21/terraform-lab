"""
AI Gatewayの負荷試験: 以下を測定する
1. vLLMルーティング時のスループット (tokens/sec)
2. Bedrockフォールバック時のレイテンシ
3. KEDAスケールアウトのトリガー条件
4. コールドスタート時のリクエスト成功率
"""
import json
import random
import time

from locust import HttpUser, between, task


PROMPTS = [
    "AWSのEKSについて100文字で説明してください",
    "Karpenterの特徴を箇条書きで3点述べてください",
    "Kubernetes のDeploymentとStatefulSetの違いは何ですか？",
    "AIモデルの推論最適化手法を説明してください",
    "vLLMのPagedAttentionの仕組みを説明してください",
]


class InferenceUser(HttpUser):
    wait_time = between(1, 3)  # 1〜3秒のランダム待機

    @task(7)
    def chat_completion_short(self):
        """短いプロンプト: 高頻度タスク"""
        prompt = random.choice(PROMPTS[:3])
        start = time.time()

        with self.client.post(
            "/v1/chat/completions",
            json={
                "messages": [{"role": "user", "content": prompt}],
                "max_tokens": 100,
            },
            catch_response=True,
        ) as response:
            latency = time.time() - start

            if response.status_code == 200:
                data = response.json()
                backend = data.get("_backend", "unknown")
                # バックエンドごとのレイテンシをLocustのカスタムメトリクスに記録
                self.environment.events.request.fire(
                    request_type="POST",
                    name=f"/v1/chat/completions [{backend}]",
                    response_time=latency * 1000,
                    response_length=len(response.text),
                )
                response.success()
            else:
                response.failure(f"HTTP {response.status_code}")

    @task(3)
    def chat_completion_long(self):
        """長いプロンプト: 低頻度タスク (コスト試算の精度確認)"""
        with self.client.post(
            "/v1/chat/completions",
            json={
                "messages": [{"role": "user", "content": PROMPTS[-1]}],
                "max_tokens": 500,
            },
            catch_response=True,
        ) as response:
            if response.status_code == 200:
                response.success()
            else:
                response.failure(f"HTTP {response.status_code}")
