# スケーリング反応速度ベンチマーク

## 実験環境

| 項目 | 値 |
|---|---|
| クラスタ | Kind (ローカル) / EKS 1.30 (本番相当) |
| Operator バージョン | Phase 3 実装 |
| 測定日 | TBD |
| SQSキュー | TBD |

## 実験手順

```bash
# 1. 負荷注入 (SQSに50メッセージ投入)
./test/load/inject_load.sh https://sqs.ap-northeast-1.amazonaws.com/<account>/<queue> 50

# 2. 反応速度計測 (自作コントローラー, ポーリング5秒)
CONTROLLER_TYPE=custom-5s ./test/load/measure_scale_latency.sh llama-3-8b inference 3 ./docs/benchmarks/results.csv

# 3. KEDAと比較する場合は scalingMetric.pollingIntervalSeconds=15 に変更して再実行
CONTROLLER_TYPE=custom-15s ./test/load/measure_scale_latency.sh llama-3-8b inference 3 ./docs/benchmarks/results.csv
```

## 計測結果

### スケールアウト反応時間 (キュー空 → 3レプリカ)

| 試行 | 自作(5秒) | 自作(15秒) | KEDA(15秒) | CloudWatch(60秒) |
|---|---|---|---|---|
| 1 | - | - | - | - |
| 2 | - | - | - | - |
| 3 | - | - | - | - |
| 4 | - | - | - | - |
| 5 | - | - | - | - |
| **平均** | **-** | **-** | **-** | **-** |
| **σ** | **-** | **-** | **-** | **-** |

### スケールダウン / scale-to-zero 反応時間

| 試行 | 自作(5秒) | 自作(15秒) | KEDA(15秒) |
|---|---|---|---|
| 1 | - | - | - |
| 2 | - | - | - |
| 3 | - | - | - |
| **平均** | **-** | **-** | **-** |

### ヒステリシス有効時のflapping観測

ヒステリシス無し(単純閾値)でflappingが発生することを確認してから、
`scaleDownThresholdRatio=0.7`が有効なことを検証する。

| 条件 | flapping発生回数/10分 | 備考 |
|---|---|---|
| ヒステリシスなし (比較用) | - | - |
| scaleDownThresholdRatio=0.7 | - | 本実装 |
| scaleDownThresholdRatio=0.5 | - | 参考比較 |

## 考察

> (実験後に記入する)
>
> - ポーリング間隔の差(5s vs 15s)がスケールアウト反応時間に与えた実際の影響
> - Prometheusポーリング増加によるAPIサーバー・Prometheus自体の負荷変化
> - ヒステリシスによってflappingが具体的に何回減ったか
> - 予想と実測の乖離があった場合その原因

## API サーバー・Prometheus 負荷観測

ポーリング間隔を短くした場合の副作用を計測する。

```bash
# Prometheusのクエリレート確認
kubectl exec -n monitoring prometheus-0 -- \
  curl -s 'localhost:9090/api/v1/query?query=rate(prometheus_http_requests_total[1m])' \
  | jq '.data.result[] | select(.metric.handler=="/api/v1/query") | .value[1]'
```

| ポーリング間隔 | Prometheus QPS | APIサーバー req/s | 備考 |
|---|---|---|---|
| 5秒 | - | - | - |
| 15秒 | - | - | KEDA相当 |
| 30秒 | - | - | 参考 |
