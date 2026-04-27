# ✅Phase 3: チューニング実施と効果測定

## Phase 1-2で作成したもの（サマリー）
- EKS + Karpenter + Prometheus/Grafana 可観測性基盤
- サンプルアプリ（FastAPI）with 3種のボトルネック
- k6負荷テスト基盤（Fargate）
- ベースライン計測結果（`load-tests/results/before-tuning/`）
- 特定されたボトルネック:
  1. CPU Throttling（limits: 200m → 実消費が超過）
  2. メモリOOMKill（limits: 128Mi → 不足）
  3. 非同期未対応DBアクセス（同期呼び出しによる遅延）

## このフェーズの目標
特定したボトルネックを順番に修正し、各改善の効果を数値で記録する。
「○○を変更したら p95レイテンシが○%改善した」を言えるようにする。

---

## チューニング1: Resource Request/Limit最適化

### 問題
- requests cpu=100m（実消費より低い → KubernetesのCPU制限発動）
- limits cpu=200m（Throttlingの原因）

### 対応
`k8s/sample-app/deployment.yaml` を修正:

```yaml
# チューニング前
resources:
  requests:
    cpu: "100m"
    memory: "64Mi"
  limits:
    cpu: "200m"
    memory: "128Mi"

# チューニング後（VPA推奨値を参考に設定）
resources:
  requests:
    cpu: "500m"   # 実消費の110%程度に設定
    memory: "256Mi"
  limits:
    cpu: "2"      # CPUはlimitsを高めに（Throttling防止）
    memory: "512Mi"
```

**VPA（VerticalPodAutoscaler）をAdvisoryモードで導入:**
```yaml
# k8s/vpa/sample-app-vpa.yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: sample-app-vpa
  namespace: perf-tuning
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: sample-app
  updatePolicy:
    updateMode: "Off"   # 推奨値を表示するだけ（自動適用しない）
```

実装後に `./scripts/run-benchmark.sh 02_ramp_up tuning-1-resources` を実行して効果を計測。

---

## チューニング2: HPA + KEDA導入

### 問題
- replicas=1の固定 → 負荷増加時にスケールアウトできない

### HPA設定
```yaml
# k8s/hpa/sample-app-hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: sample-app-hpa
  namespace: perf-tuning
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: sample-app
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 70
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 30   # 素早くスケールアップ
      policies:
        - type: Pods
          value: 2
          periodSeconds: 30
    scaleDown:
      stabilizationWindowSeconds: 300  # スケールダウンは慎重に
```

### KEDA設定（カスタムメトリクスでスケール）
```yaml
# k8s/keda/sample-app-scaledobject.yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: sample-app-keda
  namespace: perf-tuning
spec:
  scaleTargetRef:
    name: sample-app
  minReplicaCount: 2
  maxReplicaCount: 10
  triggers:
    - type: prometheus
      metadata:
        serverAddress: http://kube-prometheus-stack-prometheus.observability:9090
        metricName: http_requests_active
        threshold: "100"   # アクティブリクエスト100を超えたらスケール
        query: |
          sum(rate(http_requests_total{namespace="perf-tuning"}[1m]))
```

実装後に `./scripts/run-benchmark.sh 02_ramp_up tuning-2-hpa` を実行。

---

## チューニング3: アプリコード最適化

### 問題
- 非同期未対応のDynamoDB呼び出し（同期I/O がブロッキング）

### 対応
`k8s/sample-app/app.py` の修正:

```python
# チューニング前: 同期呼び出し
import boto3
dynamodb = boto3.resource('dynamodb')

@app.get("/db-latency")
def get_db_latency():
    table = dynamodb.Table('sample-table')
    response = table.get_item(Key={'id': 'test'})  # ブロッキング
    return response

# チューニング後: aioboto3で非同期化
import aioboto3
from contextlib import asynccontextmanager

session = aioboto3.Session()

@app.get("/db-latency")
async def get_db_latency():
    async with session.resource('dynamodb') as dynamodb:
        table = await dynamodb.Table('sample-table')
        response = await table.get_item(Key={'id': 'test'})  # ノンブロッキング
    return response
```

実装後に `./scripts/run-benchmark.sh 02_ramp_up tuning-3-async` を実行。

---

## チューニング4: PodDisruptionBudget + Pod Affinity

```yaml
# k8s/sample-app/pdb.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: sample-app-pdb
  namespace: perf-tuning
spec:
  minAvailable: 1   # ノードdrainでもサービス継続
  selector:
    matchLabels:
      app: sample-app
```

```yaml
# Deploymentに追加: Podを異なるノードに分散
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchExpressions:
              - key: app
                operator: In
                values: ["sample-app"]
          topologyKey: kubernetes.io/hostname
```

---

## 効果測定スクリプト

**scripts/compare-results.sh:**
```bash
#!/bin/bash
# 使用法: ./compare-results.sh before-tuning after-tuning
# before と after の結果JSONを比較してMarkdownレポートを生成
# 出力: docs/tuning-results.md の "改善効果" セクション

# 計算する改善率:
# - p95レイテンシ改善率
# - エラーレート改善率
# - スループット改善率
# - CPU throttling率の変化（Prometheusクエリで取得）
```

---

## 完了条件
- [ ] 4つのチューニングが適用されている
- [ ] 各チューニング後にベンチマークを実行して結果が保存されている
- [ ] `compare-results.sh` でbefore/after比較レポートが生成できる
- [ ] `docs/tuning-results.md` の改善効果セクションが埋まっている
- [ ] GrafanaでCPU throttlingが大幅に減少していることが確認できる

## 期待する改善値（目安）
| メトリクス | Before | After目標 |
|-----------|--------|----------|
| p95レイテンシ（/cpu-intensive） | ベースライン値 | 50%以上改善 |
| CPU Throttling率 | 高い | 10%以下 |
| 100VU時エラーレート | 発生 | 0% |
| スケールアウト | なし | 自動スケール確認 |

## 次フェーズへの引き継ぎ情報
Phase 4に以下を渡す:
- チューニング前後の全比較数値
- Grafanaスクリーンショット保存先
- Zenn記事に使えるインパクトのある数値（「○○%改善」）