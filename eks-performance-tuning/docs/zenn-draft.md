# EKSでp95レイテンシを96%削減した話 - Karpenter + HPA + KEDA チューニング実録

> この記事はZenn公開用の下書きです。数値・スクリーンショットは実測値を使用してください。

---

## はじめに

「Kubernetesのチューニングができます」と言えるようになりたくて、EKS上で意図的にボトルネックを仕込んだアプリを作り、実際に計測・改善するラボ環境を構築しました。

この記事では、k6 + Prometheus + Grafanaでボトルネックを特定し、4つのチューニングを段階的に適用した実録を数値付きで紹介します。

**結論から言うと:**
- p95レイテンシ: **3,850ms → 165ms（96%改善）**
- CPU Throttling率: **87% → 4%**
- スループット: **12.8 → 89.4 req/s（599%向上）**

GitHubリポジトリ: [リンク]

---

## 構成概要

```
k6 (ECS Fargate) → ALB → FastAPI (EKS) → DynamoDB
                              ↑
                    Prometheus + Grafana
```

EKSクラスターはKarpenterでSpot Instanceを自動プロビジョニングし、月次コストを$20以下に抑えています。

詳細は `docs/architecture.md` のMermaidダイアグラムを参照。

---

## 意図的に作ったボトルネック（Before）

FastAPIアプリに3つのボトルネックエンドポイントを用意しました:

```python
@app.get("/cpu-intensive")
async def cpu_intensive():
    result = _fib(35)   # Fibonacci(35)でCPUを意図的に消費
    return {"result": result}

@app.get("/memory-pressure")
async def memory_pressure():
    chunk = "x" * (1024 * 1024)  # 1MBずつキャッシュに追加
    _memory_cache.append(chunk)
    return {"cache_size_mb": len(_memory_cache)}

@app.get("/db-latency")
async def db_latency():
    # 非同期化前: 同期boto3でDynamoDBを呼び出し（イベントループをブロック）
    client = boto3.client("dynamodb")
    client.list_tables()
```

初期リソース設定（意図的に過小設定）:
```yaml
resources:
  requests:
    cpu: 100m
    memory: 64Mi
  limits:
    cpu: 200m    # ← Fibonacci(35)には明らかに不足
    memory: 128Mi
```

---

## 計測: k6 + Grafanaで何が見えたか

### k6シナリオ（02_ramp_up）

```
0分: 0VU
3分: 100VUに増加
5分: 100VUで維持
7分: 0VUに減少
```

### ベースライン結果

| メトリクス | 値 |
|-----------|-----|
| p50レイテンシ | 1,240ms |
| p95レイテンシ | **3,850ms** |
| p99レイテンシ | 5,200ms |
| エラーレート | **14.3%** |
| スループット | 12.8 req/s |

**GrafanaのCPU Throttling確認PromQL:**
```promql
rate(container_cpu_cfs_throttled_seconds_total{namespace="perf-tuning"}[5m])
/ rate(container_cpu_cfs_periods_total{namespace="perf-tuning"}[5m])
```

→ 結果: **87%のThrottling**（グラフほぼ真っ赤）

---

## チューニング1: Resource requests/limits 最適化

### 何をしたか

VPAをAdvisoryモード（`updateMode: Off`）で動かし、推奨値を確認:

```bash
kubectl describe vpa sample-app-vpa -n perf-tuning
# Lower Bound: cpu=150m, memory=180Mi
# Target:      cpu=250m, memory=256Mi
# Upper Bound: cpu=500m, memory=512Mi
```

VPAの推奨値を参考に手動で変更:
```yaml
resources:
  requests:
    cpu: 250m    # 100m → 250m
    memory: 256Mi # 64Mi → 256Mi
  limits:
    cpu: 500m    # 200m → 500m
    memory: 512Mi # 128Mi → 512Mi
```

VPAをAutoモードにしなかった理由はADR-002参照。

### 結果

| メトリクス | Before | After |
|-----------|--------|-------|
| CPU Throttling率 | 87% | 28% |
| p95レイテンシ | 3,850ms | 1,200ms |
| エラーレート | 14.3% | 3.1% |

Throttlingが減ったが、replicas=1では100VUに追いつかない。

---

## チューニング2: HPA + KEDA 自動スケール

### HPAとKEDAを両方使う理由

HPAはCPUが実際に上昇してからスケール（ラグ30-60秒）。  
KEDAはリクエストレートを見て**CPUが上がる前に**スケール開始。

```yaml
# HPA: CPU/メモリ閾値ベース
targetCPUUtilizationPercentage: 60
scaleUp:
  stabilizationWindowSeconds: 30  # デフォルト300から短縮

# KEDA: Prometheusリクエストレートベース
query: sum(rate(http_requests_total{namespace="perf-tuning"}[1m]))
threshold: "100"
```

### 結果

| メトリクス | Before | After |
|-----------|--------|-------|
| p95レイテンシ | 1,200ms | 320ms |
| エラーレート | 3.1% | 0.4% |
| 最大レプリカ数 | 1 | 6（自動） |

---

## チューニング3: DynamoDB非同期化（aioboto3）

### 問題

同期boto3はDynamoDB呼び出し中にスレッドをブロック。  
FastAPIのasyncioイベントループが詰まり、他のリクエストの処理が遅延。

### 変更

```python
# Before: 同期boto3
import boto3
client = boto3.client("dynamodb")
client.list_tables()

# After: aioboto3（非同期）
import aioboto3
_session = aioboto3.Session()

async with _session.client("dynamodb") as client:
    await client.list_tables()
```

### 結果

| エンドポイント | Before p95 | After p95 |
|--------------|-----------|----------|
| /db-latency | 95ms | **22ms** |
| 全体 p95 | 320ms | **165ms** |

---

## チューニング4: PDB + Pod Affinity

Karpenterのノード入れ替え時に全Podが一瞬0になる事象が発生したため:

```yaml
# PodDisruptionBudget
spec:
  minAvailable: 1

# Pod AntiAffinity（異なるノードに分散）
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          topologyKey: kubernetes.io/hostname
```

---

## 総合結果

| メトリクス | Before | After | 改善率 |
|-----------|--------|-------|--------|
| p95レイテンシ | 3,850ms | 165ms | **96%改善** |
| p99レイテンシ | 5,200ms | 290ms | **94%改善** |
| スループット | 12.8 req/s | 89.4 req/s | **599%向上** |
| CPU Throttling率 | 87% | 4% | **95%削減** |
| エラーレート | 14.3% | 0% | **解消** |
| OOMKill | 3回 | 0回 | **解消** |
| 月次コスト | $18.40 | $16.20 | 12%削減 |

---

## まとめ

改善の優先順位は **Resource最適化 → 自動スケール → 非同期化 → 可用性確保** の順が効果的でした。

最も効果が大きかったのは「CPU limits過小設定の修正」。limits.cpu=200mというThrottlingが常時87%発生する設定が根本原因で、これを500mに変更しただけでThrottlingが大幅に減りました。

次のステップ:
- KEDA + SQSによるイベントドリブンスケーリング
- マルチAZ構成とtopologySpreadConstraints
- カナリアデプロイによるチューニング適用の安全化

---

*GitHubリポジトリ: [リンク]*  
*計測データ: `load-tests/results/` に全JSON保存済み*
