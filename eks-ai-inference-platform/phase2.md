# Phase 2: vLLM デプロイ + モデルサービング + S3モデルキャッシュ

## 前提条件 (Phase 1 完了済み)

- EKS クラスター稼働中
- Karpenter GPU NodePool 設定済み (`nvidia.com/gpu` リソース有効)
- NVIDIA Device Plugin DaemonSet 稼働中
- ALB Controller インストール済み

---

## このフェーズの目標

- **vLLM** を EKS にデプロイし、OpenAI互換API (`/v1/completions`, `/v1/chat/completions`) を提供する
- モデル重みを **S3 → EBS (gp3)** にキャッシュし、コールドスタート時間を短縮する
- ALB Ingress 経由で外部からアクセス可能にする
- Phase 4 (AI Gateway) が参照できる ClusterIP Service を設定する

### 使用モデル

**デモ用 (推奨)**: `microsoft/Phi-3-mini-4k-instruct` (~2.2GB, GPU不要でも動作)

理由:
- HuggingFace ライセンス: MIT (商用利用可)
- 量子化モデルが存在し CPU でも推論可能 (GPUが取得できない場合のフォールバック)
- vLLM が公式サポート

---

## 実装手順

### Step 1: モデル重みキャッシュ用 S3 バケット

```hcl
# terraform/modules/eks/model_storage.tf として追加

resource "aws_s3_bucket" "model_cache" {
  # HuggingFaceからDLしたモデル重みをS3に保存
  # EBSより安価で、複数ノード間でモデルを共有できる
  bucket = "eks-ai-inference-model-cache-${data.aws_caller_identity.current.account_id}"

  tags = {
    Project = "eks-ai-inference-platform"
    Purpose = "vllm-model-weights"
  }
}

resource "aws_s3_bucket_versioning" "model_cache" {
  bucket = aws_s3_bucket.model_cache.id
  versioning_configuration {
    # モデルバージョン管理: 誤削除時のロールバックのため
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "model_cache" {
  bucket = aws_s3_bucket.model_cache.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

# モデルキャッシュへのアクセスIRSAポリシー
resource "aws_iam_policy" "vllm_s3_policy" {
  name = "vllm-model-cache-s3-policy"
  policy = jsonencode({
    Statement = [{
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:ListBucket"]
      # モデルキャッシュバケットのみに限定 (最小権限)
      Resource = [
        aws_s3_bucket.model_cache.arn,
        "${aws_s3_bucket.model_cache.arn}/*"
      ]
    }]
  })
}
```

### Step 2: Kubernetes マニフェスト群 (`k8s/vllm/`)

#### `k8s/vllm/namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ai-inference
  labels:
    # OTELの自動instrumentationスコープ設定
    instrumentation: enabled
```

#### `k8s/vllm/serviceaccount.yaml`

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vllm-sa
  namespace: ai-inference
  annotations:
    # IRSA: S3モデルキャッシュへのアクセスのみ許可
    eks.amazonaws.com/role-arn: "arn:aws:iam::ACCOUNT_ID:role/vllm-s3-irsa-role"
```

#### `k8s/vllm/pvc.yaml`

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: model-cache-pvc
  namespace: ai-inference
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: gp3-encrypted
  resources:
    requests:
      # Phi-3-mini ~2.2GB + 推論中の作業領域
      # 量子化版も含め余裕をもって30GBを確保
      storage: 30Gi
---
# gp3 StorageClass (暗号化必須)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-encrypted
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
  # gp3: gp2比でIOPS 3000→16000まで追加料金なし、スループット 125→1000MB/s
  throughput: "250"
volumeBindingMode: WaitForFirstConsumer  # ノードのAZにEBSを作成するため必須
```

#### `k8s/vllm/configmap.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: vllm-config
  namespace: ai-inference
data:
  # モデル設定: 環境変数でモデルを切り替え可能にする
  MODEL_NAME: "microsoft/Phi-3-mini-4k-instruct"
  MAX_MODEL_LEN: "4096"
  # GPU推論: tensor-parallelism=1 (g4dn.xlarge はGPU 1枚)
  TENSOR_PARALLEL_SIZE: "1"
  # PagedAttention KVキャッシュブロックサイズ
  # 大きいほどスループット向上、小さいほどレイテンシ改善
  GPU_MEMORY_UTILIZATION: "0.90"
  # 連続バッチ処理: 最大同時リクエスト数
  MAX_NUM_SEQS: "32"
  # ポート: AI Gatewayが参照
  PORT: "8000"
```

#### `k8s/vllm/deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-server
  namespace: ai-inference
  labels:
    app: vllm-server
    version: v1
spec:
  # KEDAがreplica 0→1 にスケールするためreplicasは1から開始
  replicas: 1
  selector:
    matchLabels:
      app: vllm-server
  template:
    metadata:
      labels:
        app: vllm-server
      annotations:
        # OTELがカスタムメトリクスを収集するためのアノテーション
        prometheus.io/scrape: "true"
        prometheus.io/port: "8000"
        prometheus.io/path: "/metrics"
    spec:
      serviceAccountName: vllm-sa
      # GPUノードにのみスケジュールするtoleration
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      nodeSelector:
        karpenter.k8s.aws/instance-gpu-manufacturer: "nvidia"
      # モデル初期化には数分かかるため、起動猶予を十分に設定
      terminationGracePeriodSeconds: 60
      initContainers:
        - name: model-downloader
          # S3からモデル重みをEBSボリュームにダウンロードするinitコンテナ
          # キャッシュが存在すればスキップするロジックを含む
          image: amazon/aws-cli:2.17.0
          command:
            - /bin/sh
            - -c
            - |
              MODEL_DIR="/model-cache/$(MODEL_NAME)"
              if [ -d "$MODEL_DIR" ] && [ "$(ls -A $MODEL_DIR)" ]; then
                echo "モデルキャッシュが存在するためダウンロードをスキップ"
                exit 0
              fi
              echo "S3からモデル重みをダウンロード中..."
              aws s3 sync s3://${MODEL_BUCKET}/${MODEL_NAME}/ ${MODEL_DIR}/
          env:
            - name: MODEL_NAME
              valueFrom:
                configMapKeyRef:
                  name: vllm-config
                  key: MODEL_NAME
            - name: MODEL_BUCKET
              value: "eks-ai-inference-model-cache-ACCOUNT_ID"
          volumeMounts:
            - name: model-cache
              mountPath: /model-cache
      containers:
        - name: vllm
          # vLLM公式イメージ: CUDA 12.x 対応
          image: vllm/vllm-openai:v0.5.4
          imagePullPolicy: IfNotPresent
          command:
            - python3
            - -m
            - vllm.entrypoints.openai.api_server
          args:
            - --model=/model-cache/$(MODEL_NAME)
            - --host=0.0.0.0
            - --port=8000
            - --max-model-len=$(MAX_MODEL_LEN)
            - --tensor-parallel-size=$(TENSOR_PARALLEL_SIZE)
            - --gpu-memory-utilization=$(GPU_MEMORY_UTILIZATION)
            - --max-num-seqs=$(MAX_NUM_SEQS)
            # 推論リクエストのメトリクスを /metrics エンドポイントに公開
            - --enable-metrics
            # モデルダウンロード完了前に起動しないためオフライン指定
            - --no-download
          envFrom:
            - configMapRef:
                name: vllm-config
          resources:
            requests:
              # T4 GPUは16GB VRAMを持つ: Phi-3-miniは4GBで動作
              nvidia.com/gpu: "1"
              memory: "8Gi"
              cpu: "2"
            limits:
              nvidia.com/gpu: "1"
              memory: "14Gi"
              cpu: "4"
          ports:
            - containerPort: 8000
          readinessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 120
            periodSeconds: 10
            failureThreshold: 30
          livenessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 180
            periodSeconds: 30
          volumeMounts:
            - name: model-cache
              mountPath: /model-cache
            - name: shm
              mountPath: /dev/shm
      volumes:
        - name: model-cache
          persistentVolumeClaim:
            claimName: model-cache-pvc
        # vLLMのPagedAttentionはshared memoryを使用: サイズを拡大
        - name: shm
          emptyDir:
            medium: Memory
            sizeLimit: 4Gi
```

#### `k8s/vllm/service.yaml`

```yaml
# ClusterIP: AI Gatewayからのクラスター内アクセス用
apiVersion: v1
kind: Service
metadata:
  name: vllm-service
  namespace: ai-inference
  labels:
    app: vllm-server
spec:
  selector:
    app: vllm-server
  ports:
    - name: http
      port: 8000
      targetPort: 8000
  type: ClusterIP
---
# ALB Ingress: 動作確認・デバッグ用 (本番はGateway経由のみ)
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: vllm-ingress
  namespace: ai-inference
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    # HTTPS必須: モデルの入出力は機密情報を含む可能性あり
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/healthcheck-path: /health
    alb.ingress.kubernetes.io/healthcheck-interval-seconds: "30"
spec:
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: vllm-service
                port:
                  number: 8000
```

---

### Step 3: HuggingFace モデルを S3 にアップロードするスクリプト

`scripts/upload_model_to_s3.sh` を作成すること:

```bash
#!/bin/bash
# HuggingFaceからモデルをダウンロードしてS3にアップロードするスクリプト
# 初回セットアップ時のみ実行する (その後はEBSキャッシュを使用)

set -euo pipefail

MODEL_NAME="${1:-microsoft/Phi-3-mini-4k-instruct}"
BUCKET_NAME="${2:-eks-ai-inference-model-cache-ACCOUNT_ID}"
LOCAL_DIR="/tmp/model-weights"

echo "=== モデル: ${MODEL_NAME} ==="
echo "=== 保存先: s3://${BUCKET_NAME}/${MODEL_NAME} ==="

# huggingface-hub のインストール
pip install huggingface-hub --quiet

# モデルダウンロード (量子化版を優先してサイズ削減)
python3 -c "
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id='${MODEL_NAME}',
    local_dir='${LOCAL_DIR}/${MODEL_NAME}',
    ignore_patterns=['*.msgpack', '*.h5', 'flax_model*']  # PyTorch重みのみ
)
"

# S3にアップロード (VPC S3 Endpoint経由)
aws s3 sync "${LOCAL_DIR}/${MODEL_NAME}/" \
  "s3://${BUCKET_NAME}/${MODEL_NAME}/" \
  --region ap-northeast-1 \
  --no-progress

echo "=== アップロード完了 ==="
aws s3 ls "s3://${BUCKET_NAME}/${MODEL_NAME}/" --human-readable --summarize
```

---

## 検証手順

```bash
# 1. vLLM Pod が GPU ノードで起動していることを確認
kubectl get pods -n ai-inference -o wide
kubectl describe pod -n ai-inference -l app=vllm-server | grep -A5 "Node:"

# 2. Karpenter が g4dn ノードを起動したことを確認
kubectl get nodes -l karpenter.k8s.aws/instance-family=g4dn

# 3. GPU が認識されていることを確認
kubectl exec -n ai-inference -l app=vllm-server -- nvidia-smi

# 4. vLLM APIへの疎通確認 (ClusterIP経由)
kubectl run -n ai-inference test-client --image=curlimages/curl --rm -it --restart=Never -- \
  curl -s http://vllm-service:8000/health

# 5. モデル一覧確認
kubectl run -n ai-inference test-client --image=curlimages/curl --rm -it --restart=Never -- \
  curl -s http://vllm-service:8000/v1/models | python3 -m json.tool

# 6. 推論テスト (OpenAI互換API)
kubectl run -n ai-inference inference-test --image=curlimages/curl --rm -it --restart=Never -- \
  curl -s -X POST http://vllm-service:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "microsoft/Phi-3-mini-4k-instruct",
    "messages": [{"role": "user", "content": "AWSのEKSについて50文字で説明してください"}],
    "max_tokens": 100
  }' | python3 -m json.tool

# 7. メトリクスエンドポイント確認 (Phase 3のOTELが収集するメトリクス)
kubectl run -n ai-inference metrics-test --image=curlimages/curl --rm -it --restart=Never -- \
  curl -s http://vllm-service:8000/metrics | grep -E "^vllm_"
```

---

## 重要: vLLM の PagedAttention 理解

vLLM の最大の特徴は **PagedAttention** によるKVキャッシュ管理。

```
従来のアテンション:
  各リクエストに固定長のGPUメモリを事前確保
  → メモリ断片化発生 → GPU使用率 20-40%

PagedAttention:
  KVキャッシュをページ(ブロック)単位で仮想管理
  → 物理メモリを動的に割り当て → GPU使用率 70-90%
  → 同一GPUでの並列リクエスト数が大幅増加
```

`GPU_MEMORY_UTILIZATION: "0.90"` はこのブロックプールのサイズを制御している。
面接でこの仕組みを説明できると技術的深さが伝わる。

---

## Phase 2 完了チェックリスト

- [ ] S3 モデルキャッシュバケット作成済み
- [ ] モデル重み S3 アップロード済み
- [ ] EBS gp3 PVC 作成済み (30Gi)
- [ ] vLLM Pod が GPU ノードで Running
- [ ] nvidia-smi でGPU認識確認済み
- [ ] `/v1/models` エンドポイント応答確認済み
- [ ] 推論テスト成功確認済み
- [ ] `/metrics` エンドポイントで vLLM メトリクス確認済み

---

## 口頭説明チェックポイント (15分ノートなし)

- PagedAttentionがGPUメモリ効率を改善する仕組みを説明できるか?
- initContainerでモデルをキャッシュする設計の意図を説明できるか?
- `MAX_NUM_SEQS` と `GPU_MEMORY_UTILIZATION` のトレードオフを説明できるか?
- S3 Gateway Endpointを使ってモデルをDLできる理由を説明できるか?