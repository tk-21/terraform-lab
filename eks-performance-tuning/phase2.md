# ✅Phase 2: 負荷テスト実行とボトルネック特定

## Phase 1で作成したもの（サマリー）
- EKS 1.30クラスター（Karpenter付き、ap-northeast-1）
- kube-prometheus-stack（Prometheus + Grafana）
- 意図的にボトルネックを仕込んだサンプルアプリ（FastAPI）
  - CPUボトルネック（requests: 100m, limits: 200m → Throttling多発）
  - メモリリーク（リクエストごとにキャッシュ蓄積）
  - 非同期未対応のDB呼び出し
- Grafanaダッシュボード3種

## このフェーズの目標
k6で段階的負荷テストを実行し、ボトルネックを数値で特定する。
「なんとなく遅い」ではなく「p95レイテンシが○ms、原因はCPU throttling率○%」と言えるようにする。

---

## 実装手順

### Step 1: k6負荷テストスクリプト

`load-tests/scenarios/` に以下を作成:

**01_baseline.js** - ベースライン計測（低負荷）
```javascript
// 目的: 現状の素の性能を記録
// 負荷: 10 VU × 2分
// 計測: p50/p95/p99レイテンシ、エラーレート
// エンドポイント: /cpu-intensive, /memory-pressure, /db-latency
```

**02_ramp_up.js** - 段階的負荷増加
```javascript
// 目的: どの負荷レベルでパフォーマンスが劣化するか特定
// 負荷プロファイル:
//   0→10 VU: 1分
//   10→50 VU: 2分
//   50→100 VU: 2分
//   100→0 VU: 1分
// 閾値: p95 < 500ms, エラーレート < 1%
```

**03_stress.js** - ストレステスト
```javascript
// 目的: 限界点とリカバリ挙動を確認
// 負荷: 200 VU × 3分（意図的に限界を超える）
// 観察: OOMKill発生タイミング、Pod再起動、Karpenterのスケールアウト
```

k6スクリプトには以下のカスタムメトリクスを必ず含める:
```javascript
import { Trend, Rate, Counter } from 'k6/metrics';

const cpuEndpointDuration = new Trend('cpu_endpoint_duration', true);
const memEndpointDuration = new Trend('mem_endpoint_duration', true);
const dbEndpointDuration  = new Trend('db_endpoint_duration', true);
const errorRate = new Rate('error_rate');
```

### Step 2: k6実行基盤（Fargate）

`terraform/modules/load-test/` に作成:

```hcl
# ECS Fargate タスク定義
# k6の公式コンテナイメージを使用
# スクリプトはS3からマウント
# 実行結果JSONをS3に保存
# 実行後タスク自動終了（コスト最小化）
```

**scripts/run-benchmark.sh:**
```bash
#!/bin/bash
# 使用法: ./run-benchmark.sh <scenario> <tag>
# 例: ./run-benchmark.sh 01_baseline before-tuning
#
# 処理:
# 1. k6スクリプトをS3にアップロード
# 2. ECS Fargateタスクを起動
# 3. タスク完了を待機
# 4. 結果JSONをload-tests/results/{tag}/にダウンロード
# 5. サマリーをターミナルに表示
```

### Step 3: 結果の記録フォーマット

`load-tests/results/` の構造:
```
results/
├── before-tuning/
│   ├── 01_baseline_summary.json
│   ├── 02_ramp_up_summary.json
│   └── 03_stress_summary.json
└── after-tuning/
    └── （Phase 3で追加）
```

**summary.json フォーマット:**
```json
{
  "timestamp": "2024-01-15T10:00:00Z",
  "scenario": "01_baseline",
  "tag": "before-tuning",
  "metrics": {
    "http_req_duration": {
      "p50": 0,
      "p95": 0,
      "p99": 0,
      "avg": 0
    },
    "http_req_failed": { "rate": 0 },
    "iterations": 0,
    "vus_max": 0
  },
  "endpoint_breakdown": {
    "cpu_endpoint": { "p95": 0 },
    "mem_endpoint": { "p95": 0 },
    "db_endpoint": { "p95": 0 }
  }
}
```

### Step 4: ボトルネック特定クエリ集

`docs/prometheus-queries.md` に以下のPromQLを記録:

```promql
# CPU Throttling率（最重要）
rate(container_cpu_cfs_throttled_seconds_total{namespace="perf-tuning"}[5m])
/ rate(container_cpu_cfs_periods_total{namespace="perf-tuning"}[5m])

# メモリ使用率
container_memory_working_set_bytes{namespace="perf-tuning"}
/ container_spec_memory_limit_bytes{namespace="perf-tuning"}

# p95レイテンシ（アプリ側メトリクス）
histogram_quantile(0.95,
  rate(http_request_duration_seconds_bucket{namespace="perf-tuning"}[5m])
)

# Karpenterのノード数推移
karpenter_nodes_total

# Pod再起動回数
kube_pod_container_status_restarts_total{namespace="perf-tuning"}
```

### Step 5: ボトルネック特定レポート

`docs/tuning-results.md` に以下の形式で記録（Zenn記事の素材）:

```markdown
## ベースライン計測結果（チューニング前）

### 環境
- EKS 1.30, ap-northeast-1
- サンプルアプリ: FastAPI, replicas=1
- Resources: requests cpu=100m/mem=64Mi, limits cpu=200m/mem=128Mi

### 負荷テスト結果（02_ramp_up, 100VU時）
| メトリクス | 値 |
|-----------|-----|
| p50レイテンシ | XXXms |
| p95レイテンシ | XXXms |
| p99レイテンシ | XXXms |
| エラーレート | XX% |
| スループット | XX req/s |

### 特定されたボトルネック
1. **CPU Throttling: XX%**（/cpu-intensiveエンドポイント）
   - 原因: limits cpu=200mに対して実消費が常に上回っている
2. **メモリOOMKill: XX回**（高負荷時）
   - 原因: limits memory=128Miが不足
3. **DBレイテンシ: p95 XXXms**
   - 原因: 非同期化されていない同期DBアクセス
```

---

## 完了条件
- [ ] 3つのk6シナリオが正常に実行できる
- [ ] 結果JSONが `load-tests/results/before-tuning/` に保存される
- [ ] GrafanaでCPU throttling率が確認できる（数値として記録）
- [ ] p95レイテンシがエンドポイント別に記録される
- [ ] `docs/tuning-results.md` のベースラインセクションが埋まっている

## 次フェーズへの引き継ぎ情報
Phase 3に以下を渡す:
- ベースラインのp95レイテンシ（3エンドポイント別）
- CPU throttling率（数値）
- 特定されたボトルネック優先順位