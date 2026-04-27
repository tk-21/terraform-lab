# Prometheus クエリ集 — ボトルネック特定

## CPU Throttling率（最重要指標）

### コンテナ別 CPU Throttling率
```promql
rate(container_cpu_cfs_throttled_seconds_total{namespace="perf-tuning"}[5m])
/ rate(container_cpu_cfs_periods_total{namespace="perf-tuning"}[5m])
```
> 0.5以上（50%）でCPU limitが性能ボトルネックになっている。

### CPU使用率（request比）
```promql
rate(container_cpu_usage_seconds_total{namespace="perf-tuning"}[5m])
/ on(pod, container) kube_pod_container_resource_requests{resource="cpu", namespace="perf-tuning"}
```

---

## メモリ

### メモリ使用率（limit比）
```promql
container_memory_working_set_bytes{namespace="perf-tuning"}
/ container_spec_memory_limit_bytes{namespace="perf-tuning"}
```
> 0.9以上でOOMKillのリスク。

### OOMKill発生回数
```promql
kube_pod_container_status_last_terminated_reason{namespace="perf-tuning", reason="OOMKilled"}
```

---

## アプリケーションレイテンシ

### p95レイテンシ（アプリ側メトリクス）
```promql
histogram_quantile(0.95,
  rate(http_request_duration_seconds_bucket{namespace="perf-tuning"}[5m])
)
```

### エンドポイント別p95（k6カスタムメトリクス）
```promql
# cpu-intensive エンドポイント
histogram_quantile(0.95, rate(k6_cpu_endpoint_duration_bucket[5m]))

# memory-pressure エンドポイント
histogram_quantile(0.95, rate(k6_mem_endpoint_duration_bucket[5m]))

# db-latency エンドポイント
histogram_quantile(0.95, rate(k6_db_endpoint_duration_bucket[5m]))
```

---

## オートスケーリング

### Karpenterのノード数推移
```promql
karpenter_nodes_total
```

### HPAのレプリカ数
```promql
kube_horizontalpodautoscaler_status_current_replicas{namespace="perf-tuning"}
```

### Pod再起動回数
```promql
kube_pod_container_status_restarts_total{namespace="perf-tuning"}
```

---

## スループット

### リクエストレート（5分平均）
```promql
sum(rate(http_requests_total{namespace="perf-tuning"}[5m]))
```

### エラーレート
```promql
sum(rate(http_requests_total{namespace="perf-tuning", status=~"5.."}[5m]))
/ sum(rate(http_requests_total{namespace="perf-tuning"}[5m]))
```

---

## Grafanaアラート閾値（参考）

| 指標 | 警告 | 危険 |
|------|------|------|
| CPU Throttling率 | > 30% | > 50% |
| メモリ使用率 | > 80% | > 90% |
| p95レイテンシ | > 300ms | > 500ms |
| エラーレート | > 0.5% | > 1% |
| Pod再起動 | > 1回/10分 | > 3回/10分 |
