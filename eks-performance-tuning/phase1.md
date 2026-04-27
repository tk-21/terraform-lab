# ✅Phase 1: 可観測性基盤の構築

## このフェーズの目標
「どのPodが何のせいで遅いか」を即答できる計測基盤を作る。
チューニングは計測なしには始まらない。まず見える化を徹底する。

## 成果物
- Terraform: EKS + Karpenter + Prometheus/Grafana スタック
- Grafanaダッシュボード: Node/Pod/アプリの3層メトリクス
- サンプルアプリ: チューニング対象（意図的にボトルネックを仕込んだPythonアプリ）

---

## 実装手順

### Step 1: Terraform基盤（EKS）

`terraform/modules/eks/` に以下を作成:

```
main.tf        # EKSクラスター本体
karpenter.tf   # Karpenter Helm + IAM IRSA
variables.tf
outputs.tf
```

**EKSクラスター要件:**
- バージョン: 1.30
- マネージドノードグループ: Karpenter用システムノード t3.medium × 2（固定）
- アドオン: vpc-cni, coredns, kube-proxy, aws-ebs-csi-driver
- IRSA有効化（OIDC provider作成）
- CloudWatch Container Insights 有効

**Karpenter設定:**
```yaml
# k8s/karpenter/nodepool.yaml
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["t3.medium", "t3.large", "t3a.medium", "t3a.large"]
      nodeClassRef:
        apiVersion: karpenter.k8s.aws/v1beta1
        kind: EC2NodeClass
        name: default
  limits:
    cpu: "20"       # コスト上限のためCPU上限設定
    memory: 40Gi
  disruption:
    consolidationPolicy: WhenUnderutilized
    consolidateAfter: 30s  # コスト最適化のため積極的に統合
```

### Step 2: 可観測性スタック

`terraform/modules/observability/` に以下を作成:

**Prometheus + Grafana (kube-prometheus-stack):**
```hcl
resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "observability"
  create_namespace = true

  values = [file("${path.module}/values/prometheus-stack.yaml")]
}
```

`values/prometheus-stack.yaml` の主要設定:
- retention: 7d（コスト最小化）
- Grafana adminPassword: SSM Parameter Store参照
- ServiceMonitor: 全namespace対象
- alertmanager: 無効（このプロジェクトでは不要）

**収集対象メトリクス（必須）:**
```yaml
# カスタムServiceMonitor例
additionalServiceMonitors:
  - name: sample-app
    selector:
      matchLabels:
        app: sample-app
    endpoints:
      - port: metrics
        path: /metrics
        interval: 15s
```

**KEDA:**
```hcl
resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  namespace        = "keda"
  create_namespace = true
}
```

### Step 3: サンプルアプリ（チューニング対象）

`k8s/sample-app/` に意図的にボトルネックを仕込んだアプリを作成。

**app.py（FastAPI）:**
```python
# 意図的なボトルネック:
# 1. CPUボトルネック: フィボナッチ計算（非効率実装）
# 2. メモリリーク: リクエストごとにキャッシュ増加
# 3. 外部依存遅延: DynamoDBへの同期アクセス（非async）
# エンドポイント:
# GET /health           - ヘルスチェック
# GET /cpu-intensive    - CPUボトルネック
# GET /memory-pressure  - メモリボトルネック
# GET /db-latency       - DB遅延ボトルネック
# GET /metrics          - Prometheusメトリクス（prometheus_client）
```

**Deployment設定（チューニング前の意図的に悪い設定）:**
```yaml
resources:
  requests:
    cpu: "100m"   # 実際の消費より低い → Throttling発生
    memory: "64Mi"
  limits:
    cpu: "200m"   # 低すぎてCPU throttlingが頻発する
    memory: "128Mi"
replicas: 1       # HPA未設定
```

### Step 4: Grafanaダッシュボード

`dashboards/grafana/` に以下の3つのダッシュボードJSONを作成:

**1. EPT - Node Overview**
- CPU/Memory使用率（Karpenterノード別）
- ノード数推移
- Spot vs On-demand比率

**2. EPT - Pod Overview**
- CPU throttling率（重要: チューニング効果が一番見える）
- メモリ使用量 vs Limit
- OOMKill履歴
- Pod再起動回数

**3. EPT - Application Overview**
- HTTPリクエスト数（by endpoint）
- p50/p95/p99レイテンシ
- エラーレート
- アクティブコネクション数

---

## 完了条件
- [ ] `terraform apply` でEKS + 可観測性スタックが起動する
- [ ] Grafanaにログインして3つのダッシュボードが表示される
- [ ] サンプルアプリのメトリクスがPrometheusに収集されている
- [ ] `kubectl top pods` でリソース使用量が確認できる
- [ ] CPU throttlingが意図的に発生していることをGrafanaで確認できる

## コスト見積もり（Phase 1終了時）
- EKS: ~$0.10/hour
- EC2 (t3.medium × 2 system nodes): ~$0.08/hour
- 合計: ~$130/month → **負荷テスト時以外はノード数を0に近づける**
- 推奨: 検証後は `terraform destroy` または夜間停止スクリプト導入

## 次フェーズへの引き継ぎ情報
Phase 2に以下を渡す:
- GrafanaエンドポイントURL
- サンプルアプリのServiceエンドポイント
- Prometheusのクエリ例（CPU throttling, p95レイテンシ）