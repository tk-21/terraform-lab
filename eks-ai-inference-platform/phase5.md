# Phase 5: KEDA + scale-to-zero + コストダッシュボード + Chatwork通知

## 前提条件 (Phase 1-4 完了済み)

- vLLM が稼働中 (AMP に `vllm_num_requests_waiting` メトリクスを送信中)
- AI Gateway が稼働中 (ルーティング・コストメトリクス収集中)
- AMP ワークスペース稼働中
- AMG ダッシュボード稼働中

---

## このフェーズの目標

1. **KEDA** をインストールし、`vllm_num_requests_waiting` メトリクスに連動して vLLM を **scale-to-zero** する
2. scale-to-zero 時に Karpenter が GPU Spot ノードを**自動返却**することを確認する
3. Grafana に**コスト最適化ダッシュボード**を追加する (GPU稼働時間 × 単価 vs Bedrock課金の比較)
4. スケールイベント発生時に **Chatwork** へ自動通知するLambdaを実装する

---

## 実装手順

### Step 1: KEDA インストール (`k8s/keda/`)

```bash
# KEDA を Helm でインストール
helm repo add kedacore https://kedacore.github.io/charts
helm repo update

helm install keda kedacore/keda \
  --namespace keda \
  --create-namespace \
  --version "2.14.0" \
  --set operator.replicaCount=1 \
  --set resources.operator.requests.cpu=100m \
  --set resources.operator.requests.memory=128Mi \
  --set nodeSelector."kubernetes\\.io/arch"=arm64
# arm64ノードに配置: KEDA自体は軽量なのでGravitonnで十分
```

#### `k8s/keda/trigger-authentication.yaml`

```yaml
# KEDAがAMPにアクセスするためのIRSA設定
apiVersion: v1
kind: ServiceAccount
metadata:
  name: keda-amp-sa
  namespace: keda
  annotations:
    # AMPクエリ権限のIRSAロールを付与
    eks.amazonaws.com/role-arn: "arn:aws:iam::ACCOUNT_ID:role/keda-amp-irsa-role"
---
apiVersion: keda.sh/v1alpha1
kind: ClusterTriggerAuthentication
metadata:
  name: amp-trigger-auth
spec:
  podIdentity:
    # EKSのIRSAを使用してSigV4署名 (AMPへのアクセスに必須)
    provider: aws-eks
```

#### `k8s/keda/scaled-object.yaml`

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: vllm-scaler
  namespace: ai-inference
spec:
  scaleTargetRef:
    name: vllm-server
  # scale-to-zero: トラフィックゼロ時はGPUノードを完全開放
  minReplicaCount: 0
  maxReplicaCount: 3
  # スケールアウト: 待機リクエストが発生したら30秒以内にPod起動
  # スケールイン: 5分間トラフィックゼロなら0 replicaに戻す
  pollingInterval: 15   # 15秒ごとにメトリクスを確認
  cooldownPeriod: 300   # スケールインクールダウン: 5分

  triggers:
    - type: prometheus
      metadata:
        serverAddress: "https://aps-workspaces.ap-northeast-1.amazonaws.com/workspaces/WORKSPACE_ID"
        # 待機リクエスト数が1以上になったらスケールアウト
        # vLLMの内部キューサイズを直接スケールトリガーにする
        # HPAではCPU/Memory起点になり推論ワークロードの特性に合わない
        query: "sum(vllm_num_requests_waiting{namespace='ai-inference'})"
        threshold: "1"
        activationThreshold: "0"
        authModes: "pod"
      authenticationRef:
        name: amp-trigger-auth
        kind: ClusterTriggerAuthentication

  # スケールアウト/インの挙動設定
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleUp:
          # 待機リクエスト発生から迅速にスケールアウト
          stabilizationWindowSeconds: 0
          policies:
            - type: Pods
              value: 1
              periodSeconds: 30
        scaleDown:
          # スケールイン前に5分間安定していることを確認
          # 誤ってスケールインしてコールドスタートが頻発するのを防ぐ
          stabilizationWindowSeconds: 300
          policies:
            - type: Pods
              value: 1
              periodSeconds: 60
```

---

### Step 2: scale-to-zero 連鎖動作の解説

KEDA scale-to-zero → Karpenter GPU Node返却の流れ:

```
1. トラフィックゼロ (5分経過)
   ↓
2. KEDA が vllm-server replicas = 0 に設定
   ↓
3. vLLM Pod が Terminating (terminationGracePeriodSeconds: 60 で安全停止)
   ↓
4. GPU Spot ノード上のPodがすべて消える
   ↓
5. Karpenter が "WhenEmpty" consolidation を検知
   ↓ (consolidateAfter: 5m 後)
6. Karpenter が g4dn.xlarge インスタンスを terminate
   ↓
7. AWS に Spot インスタンス返却 → 課金停止

待機中の次のリクエスト到着時:
1. AI Gateway が vLLM ヘルスチェック失敗を検知 → Bedrock にルーティング
2. KEDA が vllm_num_requests_waiting メトリクスを検知 → replicas = 1
3. Karpenter が g4dn.xlarge を新規プロビジョニング (~3分)
4. vLLM Pod 起動 + モデルロード (~2分、EBSキャッシュあり)
5. ヘルスチェック通過後、AI Gateway が vLLM に切り替え
```

コールドスタート合計: **約5分** (これが最大の課題 → ADRで言及)

---

### Step 3: スケールイベント通知 Lambda (`src/scale_notify_lambda/`)

```python
"""
Karpenter/KEDA スケールイベントを Chatwork に通知する Lambda
EventBridge → Lambda → Chatwork

トリガーイベント:
- EC2 インスタンス起動 (GPU Spotプロビジョニング)
- EC2 インスタンス終了 (GPU Spot返却)
"""
import json
import urllib.parse
import urllib.request

import boto3
from aws_lambda_powertools import Logger
from aws_lambda_powertools.utilities.typing import LambdaContext

logger = Logger(service="scale-notify-lambda")
ssm = boto3.client("ssm", region_name="ap-northeast-1")


def _get_chatwork_credentials() -> tuple[str, str]:
    token = ssm.get_parameter(Name="/chatwork/token", WithDecryption=True)
    room = ssm.get_parameter(Name="/chatwork/room-id")
    return token["Parameter"]["Value"], room["Parameter"]["Value"]


def _notify(message: str) -> None:
    token, room_id = _get_chatwork_credentials()
    data = urllib.parse.urlencode({"body": message}).encode()
    req = urllib.request.Request(
        f"https://api.chatwork.com/v2/rooms/{room_id}/messages",
        data=data,
        headers={
            "X-ChatWorkToken": token,
            "Content-Type": "application/x-www-form-urlencoded",
        },
        method="POST",
    )
    with urllib.request.urlopen(req) as resp:
        logger.info(f"Chatwork通知完了: HTTP {resp.status}")


@logger.inject_lambda_context
def handler(event: dict, context: LambdaContext) -> dict:
    detail_type = event.get("detail-type", "")
    detail = event.get("detail", {})

    instance_type = detail.get("instance-type", "unknown")
    instance_id = detail.get("instance-id", "unknown")

    if detail_type == "EC2 Instance State-change Notification":
        state = detail.get("state", "")
        if state == "running" and "g4dn" in instance_type:
            # GPU Spotノードが起動 → コールドスタート開始
            msg = f"""[info][title]🚀 GPU Spot ノード起動[/title]
インスタンス: {instance_type} ({instance_id})
vLLMの初期化中... 約5分でリクエスト受付可能になります
Bedrockが自動的にカバーしています
[/info]"""
            _notify(msg)

        elif state == "terminated" and "g4dn" in instance_type:
            # GPU Spotノードが返却 → コスト削減
            msg = f"""[info][title]💤 GPU Spot ノード返却[/title]
インスタンス: {instance_type} ({instance_id})
Karpenterがアイドルノードを返却しました (コスト最適化)
次のリクエスト時に自動で再プロビジョニングされます
[/info]"""
            _notify(msg)

    logger.info(f"通知処理完了: {detail_type}")
    return {"statusCode": 200}
```

### Step 4: EventBridge ルール (Terraform)

```hcl
# terraform/modules/observability/eventbridge.tf

# GPU Spotノードの起動/終了イベントをLambdaに転送
resource "aws_cloudwatch_event_rule" "gpu_node_events" {
  name        = "eks-ai-inference-gpu-node-events"
  description = "GPU Spotノードの起動/終了を監視"

  event_pattern = jsonencode({
    "source"      : ["aws.ec2"],
    "detail-type" : ["EC2 Instance State-change Notification"],
    "detail" : {
      "state" : ["running", "terminated"]
      # g4dnのみフィルタリング: 他のノードは通知不要
    }
  })
}

resource "aws_cloudwatch_event_target" "scale_notify_lambda" {
  rule      = aws_cloudwatch_event_rule.gpu_node_events.name
  target_id = "ScaleNotifyLambda"
  arn       = aws_lambda_function.scale_notify.arn
}
```

---

### Step 5: コスト最適化ダッシュボード追加 (`docs/grafana/`)

`docs/grafana/dashboard-cost-optimization.json` として追加するGrafanaダッシュボード:

**Panel 1: GPU稼働時間と節約額**
```promql
# GPU Spot ノードの稼働時間 (時間)
sum(increase(kube_node_created{node=~".*g4dn.*"}[1h])) * 0.16
# (稼働時間 × $0.16/h = GPU コスト)

# Bedrockにオフロードしたことで節約したGPU費用
sum(increase(inference_routing_total{backend="bedrock"}[1h])) 
  * (avg(inference_cost_usd{backend="vllm"}) - avg(inference_cost_usd{backend="bedrock"}))
```

**Panel 2: バックエンド別コスト比較 (時系列)**
```promql
# vLLM累積コスト
sum(increase(inference_cost_usd{backend="vllm"}[5m]))

# Bedrock累積コスト
sum(increase(inference_cost_usd{backend="bedrock"}[5m]))
```

**Panel 3: 1M tokens あたりの実効コスト**
```promql
# vLLM: 1M tokens あたりのGPU費用
(sum(rate(inference_cost_usd{backend="vllm"}[1h])) * 3600 * 1e6) 
  / sum(rate(vllm_prompt_tokens_total[1h]) + rate(vllm_generation_tokens_total[1h]))
```

**Panel 4: Scale-to-zero 節約効果**
```promql
# scale-to-zero していた時間 (vLLM replicas=0 だった時間)
# Karpenter が GPU node を持っていなかった時間 × GPU単価
```

---

## 検証手順

```bash
# 1. KEDA インストール確認
kubectl get pods -n keda
kubectl get scaledobjects -n ai-inference

# 2. vLLMへのトラフィックをゼロにして scale-to-zero を確認
# (AI Gatewayへのリクエストを止め、5分間待つ)
kubectl get pods -n ai-inference -w  # vllm-server が 0/1 になることを確認

# 3. Karpenter が GPU ノードを返却したことを確認
kubectl get nodes  # g4dn ノードが消えていること

# 4. 新規リクエストで自動スケールアウトを確認
curl -s -X POST "https://${ALB_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"こんにちは"}],"max_tokens":50}'
# この時点では Bedrock が応答することを確認

# 5. Karpenter がg4dn をプロビジョニングし始めることを確認
kubectl get nodes -w  # g4dn ノードが再び表示されること

# 6. vLLM 起動後に再度リクエストして vLLM が応答することを確認
# (約5分後)

# 7. Chatwork に通知が届いていることを確認
# 「GPU Spot ノード起動」「GPU Spot ノード返却」の2通

# 8. コスト最適化ダッシュボードを確認
# Grafana で Panel 1-4 が正しく表示されていること
```

---

## scale-to-zero の設計上のトレードオフ

### メリット
- GPU Spot ($0.16/h) の課金時間を最小化
- Karpenter のconsolidationと組み合わせることでゼロ・ウェイストを実現
- 夜間・週末のアイドル課金が完全に消える

### デメリット / 面接で語るべきトレードオフ
- **コールドスタート約5分**: Karpenter provisioning (~3分) + vLLM起動 (~2分)
- 対策: AI Gateway が Bedrock を自動フォールバックとして提供
- 対策: ウォームアップリクエストを定期実行して常に1 replica維持する設定も可能 (minReplicaCount: 1)
- **Spot中断リスク**: モデル読み込み中にSpot中断が発生するとリクエスト失敗
- 対策: `terminationGracePeriodSeconds: 60` で進行中リクエストを完了してから終了

---

## Phase 5 完了チェックリスト

- [ ] KEDA インストール完了
- [ ] ScaledObject 作成済み (vllm-scaler)
- [ ] scale-to-zero 動作確認済み (5分後に replicas=0)
- [ ] Karpenter GPU ノード自動返却確認済み
- [ ] スケールアウト動作確認済み (リクエスト到着後)
- [ ] スケールイベント Chatwork 通知確認済み
- [ ] コスト最適化ダッシュボード Grafana 追加済み

---

## 口頭説明チェックポイント (15分ノートなし)

- KEDA vs HPA の違いを「推論ワークロードの文脈で」説明できるか?
- `vllm_num_requests_waiting` をスケールトリガーにした設計判断を説明できるか?
- scale-to-zero のコールドスタート問題とその対策を説明できるか?
- Karpenter の `WhenEmpty` と `WhenUnderutilized` の違いを説明できるか?