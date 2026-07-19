# Phase 3: DCGM + OTEL + AMP + AMG 可観測性スタック

## 前提条件 (Phase 1-2 完了済み)

- vLLM が GPU ノードで稼働中 (`/metrics` エンドポイント公開済み)
- NVIDIA Device Plugin DaemonSet 稼働中
- AMP 用 VPC Endpoint (`com.amazonaws.ap-northeast-1.aps`) 設定済み

---

## このフェーズの目標

以下の可観測性スタックを構築し、GPU推論インフラを**数値で語れる**状態にする:

| 収集対象 | ツール | 可視化 |
|---------|--------|--------|
| GPU使用率 / VRAMメモリ / 温度 / 電力 | DCGM Exporter | AMG |
| 推論レイテンシ (P50/P95/P99) | OTEL Collector | AMG |
| スループット (tokens/sec) | OTEL Collector | AMG |
| リクエストコスト ($/req) | OTEL Collector | AMG |
| vLLM内部メトリクス (キューサイズ等) | vLLM /metrics | AMG |

---

## 実装手順

### Step 1: Amazon Managed Prometheus (AMP) ワークスペース

```hcl
# terraform/modules/observability/main.tf

resource "aws_prometheus_workspace" "main" {
  alias = "eks-ai-inference-platform"

  # AMP はサーバーレスのためインフラ管理不要
  # Prometheus本体の運用コスト(冗長化/バックアップ/アップグレード)を削除
  tags = {
    Project = "eks-ai-inference-platform"
  }
}

# AMPへの書き込み権限 IRSA (OTEL CollectorのService Account用)
resource "aws_iam_policy" "amp_write_policy" {
  name = "amp-write-eks-ai-inference"
  policy = jsonencode({
    Statement = [{
      Effect = "Allow"
      Action = [
        "aps:RemoteWrite",
        "aps:GetSeries",
        "aps:GetLabels",
        "aps:GetMetricMetadata"
      ]
      # このワークスペースのみに書き込み権限を限定
      Resource = aws_prometheus_workspace.main.arn
    }]
  })
}

output "amp_workspace_id" {
  value = aws_prometheus_workspace.main.id
}

output "amp_remote_write_url" {
  value = "${aws_prometheus_workspace.main.prometheus_endpoint}api/v1/remote_write"
}
```

### Step 2: Amazon Managed Grafana (AMG) ワークスペース

```hcl
resource "aws_grafana_workspace" "main" {
  name                  = "eks-ai-inference-platform"
  account_access_type   = "CURRENT_ACCOUNT"
  authentication_providers = ["AWS_SSO"]
  permission_type       = "SERVICE_MANAGED"

  # AMP をデータソースとして自動設定
  data_sources = ["PROMETHEUS"]

  # CloudWatch も追加: コスト/課金情報を同一ダッシュボードで参照
  additional_data_sources = ["CLOUDWATCH"]
}

resource "aws_iam_role" "grafana" {
  name = "amg-eks-ai-inference-role"
  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "grafana.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "grafana_amp" {
  role       = aws_iam_role.grafana.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonPrometheusQueryAccess"
}
```

### Step 3: NVIDIA DCGM Exporter (`k8s/dcgm/daemonset.yaml`)

```yaml
# DCGM (Data Center GPU Manager) Exporter
# GPUの物理メトリクスをPrometheus形式で公開する
# sidecar不要: DaemonSetとしてGPUノードのみに配置

apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-dcgm-exporter
  namespace: monitoring
  labels:
    app: nvidia-dcgm-exporter
spec:
  selector:
    matchLabels:
      app: nvidia-dcgm-exporter
  template:
    metadata:
      labels:
        app: nvidia-dcgm-exporter
      annotations:
        # OTELがこのPodをスクレイピングするためのアノテーション
        prometheus.io/scrape: "true"
        prometheus.io/port: "9400"
    spec:
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      nodeSelector:
        karpenter.k8s.aws/instance-gpu-manufacturer: "nvidia"
      containers:
        - name: dcgm-exporter
          image: nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5-3.4.0-ubuntu22.04
          securityContext:
            # GPUデバイスへのアクセスに必要
            privileged: true
          ports:
            - containerPort: 9400
              name: metrics
          env:
            - name: DCGM_EXPORTER_LISTEN
              value: ":9400"
            - name: DCGM_EXPORTER_KUBERNETES
              value: "true"
            # 収集するメトリクスの設定ファイル
            - name: DCGM_EXPORTER_COLLECTORS
              value: "/etc/dcgm-exporter/dcp-metrics-included.csv"
          volumeMounts:
            - name: pod-gpu-resources
              readOnly: true
              mountPath: /var/lib/kubelet/pod-resources
      volumes:
        - name: pod-gpu-resources
          hostPath:
            path: /var/lib/kubelet/pod-resources
---
apiVersion: v1
kind: Service
metadata:
  name: nvidia-dcgm-exporter
  namespace: monitoring
  labels:
    app: nvidia-dcgm-exporter
spec:
  selector:
    app: nvidia-dcgm-exporter
  ports:
    - name: metrics
      port: 9400
      targetPort: 9400
```

**主要DCGMメトリクス** (面接で語る):
```
DCGM_FI_DEV_GPU_UTIL       # GPU計算使用率 (%)
DCGM_FI_DEV_FB_USED        # VRAM使用量 (MiB)
DCGM_FI_DEV_GPU_TEMP       # GPU温度 (℃)
DCGM_FI_DEV_POWER_USAGE    # 電力消費 (W)
DCGM_FI_DEV_SM_CLOCK       # SM(Streaming Multiprocessor)クロック
```

### Step 4: OpenTelemetry Collector (`k8s/otel/collector.yaml`)

```yaml
# OTEL Collector: 以下3つのソースからメトリクスを収集してAMPに転送
# 1. vLLM /metrics (推論メトリクス)
# 2. DCGM Exporter (GPUメトリクス)
# 3. AI Gateway (カスタムビジネスメトリクス)

apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
  namespace: monitoring
data:
  config.yaml: |
    receivers:
      prometheus:
        config:
          scrape_configs:
            # vLLM 推論メトリクス収集
            - job_name: 'vllm'
              scrape_interval: 15s
              kubernetes_sd_configs:
                - role: pod
                  namespaces:
                    names: ['ai-inference']
              relabel_configs:
                - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
                  action: keep
                  regex: 'true'
                - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_port]
                  action: replace
                  target_label: __address__
                  regex: (.+)
                  replacement: ${1}:8000

            # DCGM GPU メトリクス収集
            - job_name: 'dcgm'
              scrape_interval: 15s
              kubernetes_sd_configs:
                - role: service
                  namespaces:
                    names: ['monitoring']
              relabel_configs:
                - source_labels: [__meta_kubernetes_service_label_app]
                  action: keep
                  regex: nvidia-dcgm-exporter

      # AI Gatewayからプッシュ型でOTELメトリクス受信
      otlp:
        protocols:
          grpc:
            endpoint: "0.0.0.0:4317"
          http:
            endpoint: "0.0.0.0:4318"

    processors:
      # メモリ使用量を制限: OOMによるCollector再起動を防ぐ
      memory_limiter:
        check_interval: 1s
        limit_mib: 512
        spike_limit_mib: 128

      # メトリクスにクラスター情報を付与
      resource:
        attributes:
          - key: cluster_name
            value: "eks-ai-inference-platform"
            action: insert
          - key: environment
            value: "dev"
            action: insert

      batch:
        timeout: 10s
        send_batch_size: 1000

    exporters:
      # AMP への remote_write
      prometheusremotewrite:
        endpoint: "https://aps-workspaces.ap-northeast-1.amazonaws.com/workspaces/WORKSPACE_ID/api/v1/remote_write"
        auth:
          authenticator: sigv4auth

    extensions:
      sigv4auth:
        region: ap-northeast-1
        service: aps
      health_check: {}

    service:
      extensions: [sigv4auth, health_check]
      pipelines:
        metrics:
          receivers: [prometheus, otlp]
          processors: [memory_limiter, resource, batch]
          exporters: [prometheusremotewrite]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: otel-collector
  template:
    metadata:
      labels:
        app: otel-collector
    spec:
      serviceAccountName: otel-collector-sa
      # arm64ノードに配置 (Graviton, コスト最適化)
      nodeSelector:
        kubernetes.io/arch: arm64
      containers:
        - name: otel-collector
          image: otel/opentelemetry-collector-contrib:0.104.0
          args: ["--config=/conf/config.yaml"]
          resources:
            requests:
              cpu: "100m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
          ports:
            - containerPort: 4317  # gRPC
            - containerPort: 4318  # HTTP
            - containerPort: 13133 # health_check
          volumeMounts:
            - name: config
              mountPath: /conf
      volumes:
        - name: config
          configMap:
            name: otel-collector-config
```

### Step 5: AI推論専用カスタムメトリクス定義

AI Gatewayで収集するカスタムメトリクスの仕様 (Phase 4で実装):

```python
# src/gateway/metrics.py
# OTELカスタムメトリクス定義 (Phase 4のFastAPIで使用)
from opentelemetry import metrics

meter = metrics.get_meter("ai-gateway")

# 推論レイテンシ (P50/P95/P99 の算出に使用)
inference_latency = meter.create_histogram(
    name="inference_latency_seconds",
    description="推論リクエストのエンドツーエンドレイテンシ",
    unit="s",
)

# スループット
tokens_per_second = meter.create_histogram(
    name="inference_tokens_per_second",
    description="推論スループット (生成トークン数/秒)",
    unit="tokens/s",
)

# コスト ($/リクエスト)
cost_per_request = meter.create_histogram(
    name="inference_cost_usd",
    description="リクエストあたりの推論コスト",
    unit="USD",
    # attribute: model (vllm/bedrock), model_name
)

# ルーティング先カウンター
routing_counter = meter.create_counter(
    name="inference_routing_total",
    description="ルーティング先ごとのリクエスト数",
    # attribute: backend (vllm/bedrock), reason (cost/availability/budget)
)
```

### Step 6: Grafana ダッシュボード定義 (`docs/grafana/`)

以下のダッシュボードJSONを `docs/grafana/dashboard-gpu-inference.json` として作成すること。
ダッシュボードには以下のパネルを含めること:

**Row 1: GPU Health**
- `DCGM_FI_DEV_GPU_UTIL` — GPU使用率 (%) — Gauge
- `DCGM_FI_DEV_FB_USED` — VRAM使用量 (GiB) — Gauge
- `DCGM_FI_DEV_GPU_TEMP` — GPU温度 (℃) — Stat (60℃超で警告色)
- `DCGM_FI_DEV_POWER_USAGE` — 電力消費 (W) — Time Series

**Row 2: Inference Performance**
- `inference_latency_seconds` — P50/P95/P99 — Time Series (histogram_quantile使用)
- `inference_tokens_per_second` — スループット — Time Series
- `vllm_num_requests_running` — 同時実行リクエスト数 — Stat
- `vllm_gpu_cache_usage_perc` — KVキャッシュ使用率 — Gauge

**Row 3: Cost & Routing**
- `inference_cost_usd` — 累積コスト — Stat
- `inference_routing_total` by `backend` — ルーティング内訳 (vLLM vs Bedrock) — Pie Chart
- `rate(inference_cost_usd[5m])` — コスト/分 — Time Series
- 1M tokens あたりコスト比較 — Bar Chart (vLLM vs Bedrock)

---

## 検証手順

```bash
# 1. DCGM Exporter がGPUノードで稼働していること
kubectl get pods -n monitoring -l app=nvidia-dcgm-exporter

# 2. DCGMメトリクスが公開されていること
kubectl port-forward -n monitoring svc/nvidia-dcgm-exporter 9400:9400 &
curl -s http://localhost:9400/metrics | grep DCGM_FI_DEV_GPU_UTIL

# 3. OTEL Collectorが稼働していること
kubectl get pods -n monitoring -l app=otel-collector

# 4. AMPへの書き込みを確認 (CloudWatch Logsでエラーがないこと)
kubectl logs -n monitoring -l app=otel-collector | grep -i "error\|warn"

# 5. AMPクエリテスト
AMP_ENDPOINT=$(terraform -chdir=terraform/environments/dev output -raw amp_remote_write_url | sed 's|api/v1/remote_write|api/v1/query|')
awscurl --service aps --region ap-northeast-1 \
  "${AMP_ENDPOINT}?query=DCGM_FI_DEV_GPU_UTIL" | python3 -m json.tool

# 6. 推論リクエストを送信してレイテンシメトリクスを生成
for i in {1..10}; do
  kubectl run -n ai-inference test-req-${i} --image=curlimages/curl --rm -it --restart=Never -- \
    curl -s -X POST http://vllm-service:8000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model":"microsoft/Phi-3-mini-4k-instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}'
done

# 7. AMG でダッシュボードが表示されることを確認
echo "AMG Workspace URL: $(terraform -chdir=terraform/environments/dev output -raw amg_workspace_url)"
```

---

## 重要: メトリクス設計の深さ

### vLLM 固有メトリクスで語れること

```
vllm_gpu_cache_usage_perc:
  KVキャッシュの使用率。
  これが100%に近いとリクエストがキューで待機し始める。
  MAX_NUM_SEQS のチューニング指標になる。

vllm_num_requests_waiting:
  処理待ちリクエスト数。
  Phase 5でKEDAがこの値を見てスケールアウトをトリガーする。

vllm_e2e_request_latency_seconds:
  vLLM内部で計測されるエンドツーエンドレイテンシ。
  AI Gatewayで計測する外部レイテンシとの差分がネットワークオーバーヘッド。
```

---

## Phase 3 完了チェックリスト

- [ ] AMP ワークスペース作成済み
- [ ] AMG ワークスペース作成済み (AMPをデータソースに設定)
- [ ] DCGM Exporter DaemonSet 稼働中
- [ ] OTEL Collector Deployment 稼働中
- [ ] DCGM メトリクスが AMP に届いていること確認済み
- [ ] vLLM メトリクスが AMP に届いていること確認済み
- [ ] Grafana ダッシュボード 3 Row 作成済み
- [ ] GPU使用率が Grafana で可視化されていること確認済み

---

## 口頭説明チェックポイント (15分ノートなし)

- DCGMとはなにか、なぜsidecarなしで実現できるかを説明できるか?
- OTEL CollectorをDaemonSetではなくDeploymentにした理由を説明できるか?
- `histogram_quantile(0.99, ...)` がなにを意味するか説明できるか?
- AMPのremote_writeでSigV4認証が必要な理由を説明できるか?