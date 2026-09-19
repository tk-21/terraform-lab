# gpu-inference-operator-lab

AI推論ワークロード (vLLM on EKS) のライフサイクル管理・オートスケーリング・コスト最適化・自己修復を担う
**カスタム Kubernetes Operator** を Go (controller-runtime / kubebuilder) でゼロから実装するハンズオンプロジェクト。

---

## このハンズオンで得られること

**「既存ツールを使う」のではなく「ツールの中身を自分で書く」** 体験を通じて、以下の知識とスキルが身につく。

### Kubernetes Operator の実装パターン

| 実装するもの | 学べる概念 |
|---|---|
| カスタム CRD (`AIInferenceService`) | GVK・Spec/Status 分離・kubebuilder バリデーションマーカー |
| Reconcile ループ | 冪等性・OwnerReference・Finalizer・RequeueAfter |
| Status 管理 | Condition パターン・Phase ステートマシン・Status Subresource |
| Admission Webhook | Mutating (デフォルト値注入) / Validating (制約チェック) |
| カスタムスケーリング | ヒステリシス・scale-to-zero・Prometheus メトリクス連携 |
| 自己修復ロジック | OOMKilled 検知・memory limit 段階増加・CrashLoop 検知 |
| Bedrock フォールバック | アノテーションを使った経過時間追跡・純粋関数による判定 |

### 定量比較データの取得

- **スケーリング反応速度**: 自作コントローラー (5 秒ポーリング) vs KEDA (15 秒ポーリング)
- **フォールバック効果**: GPU コールドスタート中の Bedrock 利用によるレイテンシ改善
- **MTTR 短縮**: OOMKilled 自動復旧 vs 手動対応

### テスト・インフラ・CI/CD

- **envtest**: フェイクの Kubernetes API サーバーでコントローラーをユニットテスト
- **Kind E2E**: ローカルに k8s クラスターを立ててエンドツーエンド検証
- **Terraform**: EKS + Karpenter + VPC Endpoint (NAT Gateway なし) をコードで構築
- **GitHub Actions OIDC**: IAM アクセスキーなしで ECR へ arm64 イメージを push

---

## 目次

- [前提条件](#前提条件)
- [ハンズオンのトラック選択](#ハンズオンのトラック選択)
- [Track A: Kind でローカル実行](#track-a-kind-でローカル実行) ← まずここから
- [Track B: EKS 本番環境への構築](#track-b-eks-本番環境への構築)
- [動作確認シナリオ](#動作確認シナリオ)
- [スケーリング反応速度の計測](#スケーリング反応速度の計測)
- [クリーンアップ](#クリーンアップ)
- [トラブルシューティング](#トラブルシューティング)

---

## 前提条件

### 必須ツール

以下をインストールして PATH に通しておくこと。

```bash
# バージョン確認コマンド一覧
go version          # Go 1.22 以上
docker version      # Docker 24 以上 (または compatible)
kind version        # Kind 0.23 以上
kubectl version     # 1.29 以上
```

| ツール | 最低バージョン | インストール先 |
|---|---|---|
| Go | 1.22 | https://go.dev/dl/ |
| Docker | 24.x | https://docs.docker.com/get-docker/ |
| Kind | 0.23 | `go install sigs.k8s.io/kind@latest` |
| kubectl | 1.29 | https://kubernetes.io/docs/tasks/tools/ |

### Track B (EKS) 追加要件

```bash
aws --version       # AWS CLI v2
terraform version   # Terraform 1.5 以上
helm version        # Helm 3.16 以上
```

### リポジトリのクローン

```bash
git clone https://github.com/takuya/gpu-inference-operator-lab.git
cd gpu-inference-operator-lab
```

---

## ハンズオンのトラック選択

```
┌──────────────────────────────────────────────────────────────┐
│  Track A: Kind (ローカル)           Track B: EKS (AWS)       │
│                                                              │
│  所要時間: 約 30 分                 所要時間: 約 2 時間       │
│  費用: 無料                         費用: EKS + EC2 費用      │
│                                                              │
│  確認できること:                    確認できること:            │
│  ✅ CRD の適用                     ✅ Track A の全内容        │
│  ✅ Reconcile ループの動作          ✅ Karpenter GPU ノード    │
│  ✅ Deployment/Service 生成         ✅ Bedrock フォールバック  │
│  ✅ Phase ステートマシン             ✅ スケーリング反応速度     │
│  ✅ ユニットテスト / E2E テスト      ✅ Chatwork 通知           │
│                                                              │
│  ❌ 実 GPU ノード                   ❌ 費用ゼロ               │
│  ❌ Bedrock 連携                                             │
└──────────────────────────────────────────────────────────────┘
```

---

## Track A: Kind でローカル実行

### Step 1: 開発ツールのインストール

プロジェクトに必要なツールを `bin/` 以下にインストールする。
グローバルの Go 環境を汚染しないためプロジェクトローカルに管理する。

```bash
make controller-gen   # CRD/RBAC/Webhook マニフェスト生成ツール
make kustomize        # kustomize (config/ のビルドに使用)
make envtest          # envtest (ユニットテスト用)
```

完了確認:

```bash
ls bin/
# controller-gen  kustomize  setup-envtest
```

### Step 2: CRD マニフェストの生成

Go のソースコードに書かれた kubebuilder マーカーから CRD YAML を自動生成する。

```bash
make manifests
```

何が起きるか:

```
api/v1alpha1/aiinferenceservice_types.go の
  // +kubebuilder:validation:Enum=queueDepth;gpuUtilization
  // +kubebuilder:validation:Required
  のようなマーカーを読んで↓を生成する

config/crd/bases/inference.takuya.dev_aiinferenceservices.yaml
config/rbac/role.yaml
```

完了確認:

```bash
ls config/crd/bases/
# inference.takuya.dev_aiinferenceservices.yaml
```

### Step 3: DeepCopy コードの生成

CRD の型定義から `DeepCopyObject()` などの実装を自動生成する。
controller-runtime がオブジェクトのコピーに使うため必須。

```bash
make generate
```

何が起きるか:

```
api/v1alpha1/zz_generated.deepcopy.go が更新される
(このファイルは手動で編集しない)
```

### Step 4: コードのビルド確認

```bash
make fmt   # gofmt でフォーマット
make vet   # go vet で静的解析
make build # バイナリをビルド (bin/manager)
```

エラーが出た場合は Step 1〜3 を再実行してから試すこと。

### Step 5: ユニットテストの実行

envtest が kube-apiserver + etcd をインプロセスで起動して、
Reconcile ループのユニットテストを実行する。

```bash
make test
```

実行されるテスト:

| テストファイル | 内容 |
|---|---|
| `controllers/aiinferenceservice_controller_test.go` | Reconcile による Deployment/Service 生成 |
| `internal/scaling/calculator_test.go` | スケーリング計算のロジック (pure function) |
| `internal/fallback/detector_test.go` | フォールバック判定のロジック (pure function) |
| `internal/selfheal/detector_test.go` | 自己修復判定のロジック (pure function) |
| `webhooks/aiinferenceservice_webhook_test.go` | Webhook のバリデーション・デフォルト値注入 |

正常終了の例:

```
ok  github.com/takuya/gpu-inference-operator-lab/controllers  3.214s
ok  github.com/takuya/gpu-inference-operator-lab/internal/scaling  0.003s
ok  github.com/takuya/gpu-inference-operator-lab/internal/fallback  0.002s
ok  github.com/takuya/gpu-inference-operator-lab/internal/selfheal  0.001s
ok  github.com/takuya/gpu-inference-operator-lab/webhooks  0.189s
```

カバレッジを確認する:

```bash
go tool cover -html=cover.out -o cover.html
open cover.html   # ブラウザで開く
```

### Step 6: Kind クラスターの作成

```bash
make kind-create
```

何が作られるか (`kind-config.yaml`):

```
gpu-inference-operator クラスター
├── control-plane  (port 9443 → ホスト 9443 にマッピング: Webhook 用)
├── worker
└── worker
```

完了確認:

```bash
kubectl cluster-info --context kind-gpu-inference-operator
# Kubernetes control plane is running at https://127.0.0.1:XXXXX

kubectl get nodes
# NAME                                   STATUS   ROLES
# gpu-inference-operator-control-plane   Ready    control-plane
# gpu-inference-operator-worker          Ready    <none>
# gpu-inference-operator-worker2         Ready    <none>
```

### Step 7: CRD をクラスターに適用

```bash
kubectl apply -f config/crd/bases/
```

確認:

```bash
kubectl get crd aiinferenceservices.inference.takuya.dev
# NAME                                           CREATED AT
# aiinferenceservices.inference.takuya.dev       2026-09-20T...

# CRD のスキーマを確認する
kubectl explain aiinferenceservice.spec
kubectl explain aiinferenceservice.spec.scalingMetric
kubectl explain aiinferenceservice.status
```

### Step 8: Operator をローカルで起動する

Webhook は cert-manager が必要なため `--enable-webhooks=false` で無効化して起動する。

**ターミナル 1** (Operator を起動したままにする):

```bash
go run ./main.go \
  --leader-elect=false \
  --enable-webhooks=false \
  --metrics-bind-address=:8080 \
  --health-probe-bind-address=:8081
```

正常起動のログ例:

```json
{"level":"info","ts":"2026-09-20T10:00:00.000+0900","msg":"starting manager"}
{"level":"info","ts":"2026-09-20T10:00:00.100+0900","msg":"Starting EventSource","controller":"AIInferenceService","source":"kind source: *v1alpha1.AIInferenceService"}
{"level":"info","ts":"2026-09-20T10:00:00.200+0900","msg":"Starting workers","controller":"AIInferenceService","worker count":1}
```

**ターミナル 2** で以降の手順を実行する。

### Step 9: サンプル CR を作成する

以下の CR を作成してコントローラーの動作を確認する。
`PrometheusURL` を空にするとスケーリングが無効化され (minReplicas を維持)、
GPU なしの Kind 環境でも動作確認できる。

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: inference.takuya.dev/v1alpha1
kind: AIInferenceService
metadata:
  name: llama-3-8b
  namespace: default
spec:
  modelImage: "nginx:latest"          # Kind ではダミーイメージで動作確認する
  gpuNodePoolRef: "karpenter-gpu-g5g"
  minReplicas: 1
  maxReplicas: 3
  scalingMetric:
    type: queueDepth
    targetValue: 10
    # PrometheusURL を空にするとスケーリング無効 (Kind では Prometheus なし)
  bedrockFallback:
    enabled: false                    # Kind では Bedrock 連携なし
  selfHealing:
    restartOnOOM: true
    maxRestartAttempts: 3
  resources:
    requests:
      cpu: "100m"
      memory: "128Mi"
    limits:
      cpu: "500m"
      memory: "512Mi"
EOF
```

### Step 10: 動作確認

#### Reconcile ログを見る (ターミナル 1)

```
{"level":"info","msg":"Reconciling AIInferenceService","phase":"","desiredReplicas":1}
{"level":"info","msg":"Creating Deployment","name":"llama-3-8b","replicas":1}
{"level":"info","msg":"Creating Service","name":"llama-3-8b"}
{"level":"info","msg":"Fallback evaluation","decision":"bedrockFallback is disabled or not configured"}
```

#### CR のステータスを確認する

```bash
kubectl get ais
# NAME         PHASE         BACKEND   READY   AGE
# llama-3-8b   Provisioning  gpu       0       5s

# しばらく待つと Pod が起動して Running に変わる
kubectl get ais -w   # -w でリアルタイム監視

# 詳細なステータスを確認する
kubectl describe ais llama-3-8b
```

`describe` 出力例:

```
Status:
  Phase:           Running
  Active Backend:  gpu
  Ready Replicas:  1
  Conditions:
    Type:   Ready
    Status: True
    Reason: Running
    Message: vLLM inference is running on GPU
    
    Type:   Provisioning
    Status: False
    Reason: Running
    Message: GPU node provisioning complete
```

#### 生成された Deployment と Service を確認する

```bash
# Deployment が自動生成されている
kubectl get deployment llama-3-8b
# NAME         READY   UP-TO-DATE   AVAILABLE   AGE
# llama-3-8b   1/1     1            1           30s

# Service が自動生成されている
kubectl get service llama-3-8b
# NAME         TYPE        CLUSTER-IP      PORT(S)    AGE
# llama-3-8b   ClusterIP   10.96.xxx.xxx   8000/TCP   30s

# OwnerReference: CR が Deployment を所有している
kubectl get deployment llama-3-8b -o jsonpath='{.metadata.ownerReferences}' | jq .
# [{"apiVersion":"inference.takuya.dev/v1alpha1","kind":"AIInferenceService","name":"llama-3-8b",...}]
```

#### Finalizer が設定されていることを確認する

```bash
kubectl get ais llama-3-8b -o jsonpath='{.metadata.finalizers}'
# ["inference.takuya.dev/cleanup"]
```

#### CR を削除するとリソースが連動して削除される

```bash
kubectl delete ais llama-3-8b

# Deployment と Service も自動削除される (OwnerReference による GC)
kubectl get deployment,service llama-3-8b
# Error from server (NotFound): ...
```

### Step 11: E2E テストを実行する (Kind クラスター上)

Operator を起動したまま (ターミナル 1)、別のターミナルで実行する。

```bash
SKIP_GPU_TESTS=true go test ./test/e2e/... -v -timeout=10m
```

実行されるテスト:

| テスト名 | 内容 |
|---|---|
| `TestAIInferenceServiceBasicReconcile` | CR 作成 → Deployment 生成 → Status.Phase 設定を確認 |
| `TestAIInferenceServiceScaleToZero` | minReplicas=0 で Deployment の replicas が 0 になることを確認 |

正常終了例:

```
--- PASS: TestAIInferenceServiceBasicReconcile (8.31s)
    e2e_test.go: AIInferenceService "e2e-test-llm" を作成しました
    e2e_test.go: Deployment "e2e-test-llm" が生成されました (replicas=1)
    e2e_test.go: Deployment仕様の検証が完了しました: image="fake-ecr...", replicas=1
    e2e_test.go: Status.Phase="Provisioning" が設定されています
--- PASS: TestAIInferenceServiceScaleToZero (6.14s)
    e2e_test.go: スケールトゼロのDeploymentが正常に生成されました
PASS
```

### Step 12: Prometheus メトリクスを確認する

Operator の `:8080/metrics` エンドポイントからカスタムメトリクスを確認できる。

```bash
# カスタムメトリクスだけを抽出する
curl -s http://localhost:8080/metrics | grep gpu_inference_operator

# 出力例:
# gpu_inference_operator_reconcile_duration_seconds_bucket{...}
# gpu_inference_operator_reconcile_errors_total{...}
# gpu_inference_operator_selfheal_actions_total{...}
# gpu_inference_operator_bedrock_fallback_total{...}
```

---

## Track B: EKS 本番環境への構築

> **注意**: EKS + g5g GPU ノードの費用が発生します。ハンズオン後は必ずクリーンアップを実行してください。

### Step B-1: AWS 環境の準備

```bash
# 認証確認
aws sts get-caller-identity
# {
#   "UserId": "...",
#   "Account": "123456789012",
#   "Arn": "arn:aws:iam::123456789012:user/..."
# }

# リージョン設定 (東京リージョン固定)
export AWS_DEFAULT_REGION=ap-northeast-1
```

### Step B-2: Terraform バックエンドの準備

tfstate を保管する S3 バケットと DynamoDB テーブルを先に作成する。

```bash
# S3 バケット作成 (バケット名はグローバルで一意にする)
aws s3 mb s3://YOUR_ACCOUNT_ID-gpu-inference-operator-tfstate \
  --region ap-northeast-1

# バージョニング有効化 (tfstate の誤削除対策)
aws s3api put-bucket-versioning \
  --bucket YOUR_ACCOUNT_ID-gpu-inference-operator-tfstate \
  --versioning-configuration Status=Enabled

# State ロック用 DynamoDB テーブル
aws dynamodb create-table \
  --table-name gpu-inference-operator-tflock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-northeast-1
```

`terraform/environments/dev/` に `backend.tf` を作成する:

```bash
cat > terraform/environments/dev/backend.tf <<EOF
terraform {
  backend "s3" {
    bucket         = "YOUR_ACCOUNT_ID-gpu-inference-operator-tfstate"
    key            = "dev/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "gpu-inference-operator-tflock"
    encrypt        = true
  }
}
EOF
```

### Step B-3: Terraform で EKS クラスターを構築する

```bash
cd terraform/environments/dev

terraform init
terraform plan    # 変更内容を確認する (apply の前に必ず確認)
```

`plan` で確認すべきポイント:

```
+ aws_eks_cluster.main              (EKS クラスター本体)
+ aws_eks_node_group.system         (Graviton2 システムノード t4g.medium × 2)
+ aws_vpc.main                      (NAT Gateway なし)
+ aws_vpc_endpoint.*                (ECR / S3 / STS / CloudWatch / Bedrock)
+ aws_iam_role.operator_irsa        (Operator 用 IRSA ロール)
+ aws_iam_openid_connect_provider.github  (GitHub Actions OIDC)
```

問題なければ自分で apply を実行する:

```bash
# ⚠️ このコマンドは自分で実行する (Claude Code は apply を実行しない)
terraform apply
```

所要時間: 約 15〜20 分 (EKS クラスター起動待ち)

### Step B-4: kubeconfig の設定

```bash
aws eks update-kubeconfig \
  --region ap-northeast-1 \
  --name giop-dev-eks  # Terraform の locals.prefix + env

# 接続確認
kubectl get nodes
# NAME                                               STATUS   ROLES    AGE
# ip-10-0-1-xxx.ap-northeast-1.compute.internal     Ready    <none>   5m
# ip-10-0-2-xxx.ap-northeast-1.compute.internal     Ready    <none>   5m
```

### Step B-5: Karpenter のインストール

Terraform で Karpenter 用 IRSA ロールと Helm values が出力されているので、
Helm でインストールする。

```bash
# Karpenter の Helm リポジトリ追加
helm repo add karpenter https://charts.karpenter.sh
helm repo update

# terraform output から値を取得
KARPENTER_ROLE_ARN=$(cd terraform/environments/dev && terraform output -raw karpenter_irsa_arn)
CLUSTER_NAME=$(cd terraform/environments/dev && terraform output -raw cluster_name)
CLUSTER_ENDPOINT=$(cd terraform/environments/dev && terraform output -raw cluster_endpoint)

# Karpenter インストール
helm upgrade --install karpenter karpenter/karpenter \
  --namespace karpenter \
  --create-namespace \
  --version 0.37.0 \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="${KARPENTER_ROLE_ARN}" \
  --set settings.clusterName="${CLUSTER_NAME}" \
  --set settings.clusterEndpoint="${CLUSTER_ENDPOINT}" \
  --wait

# GPU NodePool が適用されていることを確認
kubectl get nodepool
# NAME                  NODECLASS         NODES   READY   ...
# karpenter-gpu-g5g     default           0       True
```

### Step B-6: cert-manager のインストール (Webhook 用)

```bash
kubectl apply -f \
  https://github.com/cert-manager/cert-manager/releases/download/v1.15.0/cert-manager.yaml

# cert-manager が起動するまで待つ
kubectl wait --for=condition=ready pod \
  -l app=cert-manager \
  -n cert-manager \
  --timeout=120s
```

### Step B-7: Chatwork の設定 (オプション)

Operator からの通知を受け取る場合のみ設定する。

```bash
# Chatwork API トークンを SSM Parameter Store に登録する
aws ssm put-parameter \
  --name "/gpu-inference-operator-lab/chatwork-token" \
  --value "YOUR_CHATWORK_API_TOKEN" \
  --type "SecureString" \
  --overwrite \
  --region ap-northeast-1

# 通知先ルーム ID を登録する
aws ssm put-parameter \
  --name "/gpu-inference-operator-lab/chatwork-room-id" \
  --value "YOUR_CHATWORK_ROOM_ID" \
  --type "String" \
  --overwrite \
  --region ap-northeast-1
```

### Step B-8: ECR リポジトリの作成とイメージの push

```bash
# ECR リポジトリ作成
aws ecr create-repository \
  --repository-name gpu-inference-operator \
  --region ap-northeast-1 \
  --image-scanning-configuration scanOnPush=true

# ログイン
aws ecr get-login-password --region ap-northeast-1 | \
  docker login --username AWS \
  --password-stdin \
  123456789012.dkr.ecr.ap-northeast-1.amazonaws.com

# arm64 イメージのビルドと push
IMG=123456789012.dkr.ecr.ap-northeast-1.amazonaws.com/gpu-inference-operator:v0.1.0
make docker-build IMG=$IMG
docker push $IMG
```

### Step B-9: CRD の適用と Operator のデプロイ

```bash
# CRD マニフェストの生成
make manifests

# CRD を EKS に適用
kubectl apply -f config/crd/bases/

# Helm で Operator をデプロイ
OPERATOR_ROLE_ARN=$(cd terraform/environments/dev && terraform output -raw operator_irsa_arn)

helm upgrade --install gpu-inference-operator helm/gpu-inference-operator/ \
  --namespace gpu-inference-operator \
  --create-namespace \
  --set image.repository=123456789012.dkr.ecr.ap-northeast-1.amazonaws.com/gpu-inference-operator \
  --set image.tag=v0.1.0 \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="${OPERATOR_ROLE_ARN}" \
  --set webhook.enabled=true \
  --wait

# Operator Pod の起動確認
kubectl get pods -n gpu-inference-operator
# NAME                                    READY   STATUS    RESTARTS   AGE
# gpu-inference-operator-xxxxxxxx-xxxxx   1/1     Running   0          30s
```

---

## 動作確認シナリオ

Track A (Kind) と Track B (EKS) の両方で実行できる確認手順。
Track A では GPU ノードが存在しないため Phase が `Provisioning` で止まるが、
それ以外の挙動 (Reconcile ループ・Status 更新) は同様に確認できる。

### シナリオ 1: 基本的な Reconcile ループ

```bash
# CR を作成する
kubectl apply -f - <<'EOF'
apiVersion: inference.takuya.dev/v1alpha1
kind: AIInferenceService
metadata:
  name: llama-3-8b
  namespace: default
spec:
  modelImage: "nginx:latest"
  gpuNodePoolRef: "karpenter-gpu-g5g"
  minReplicas: 1
  maxReplicas: 4
  scalingMetric:
    type: queueDepth
    targetValue: 10
  bedrockFallback:
    enabled: false
  selfHealing:
    restartOnOOM: true
    maxRestartAttempts: 3
  resources:
    requests:
      cpu: "100m"
      memory: "128Mi"
    limits:
      cpu: "500m"
      memory: "512Mi"
EOF

# Phase の変化をリアルタイム監視
kubectl get ais -w

# 詳細確認
kubectl describe ais llama-3-8b
```

### シナリオ 2: Webhook のデフォルト値注入を確認する (Track B のみ)

Webhook が有効な EKS 環境では、未設定フィールドに自動でデフォルト値が入る。

```bash
# pollingIntervalSeconds を指定せずに CR を作成する
kubectl apply -f - <<'EOF'
apiVersion: inference.takuya.dev/v1alpha1
kind: AIInferenceService
metadata:
  name: webhook-test
  namespace: default
spec:
  modelImage: "nginx:latest"
  gpuNodePoolRef: "karpenter-gpu-g5g"
  minReplicas: 1
  maxReplicas: 2
  scalingMetric:
    type: queueDepth
    targetValue: 10
  bedrockFallback:
    enabled: true
    # gpuProvisionTimeoutSeconds を省略 → Webhook が 90 を注入する
EOF

# Webhook がデフォルト値を注入したことを確認
kubectl get ais webhook-test -o jsonpath='{.spec.scalingMetric.pollingIntervalSeconds}'
# 5    ← Webhook が注入したデフォルト値

kubectl get ais webhook-test -o jsonpath='{.spec.bedrockFallback.gpuProvisionTimeoutSeconds}'
# 90   ← Webhook が注入したデフォルト値

kubectl delete ais webhook-test
```

### シナリオ 3: Bedrock フォールバックのシミュレーション (Track B のみ)

Bedrock フォールバックを有効化して、GPU プロビジョニングタイムアウトを意図的に短く設定する。

```bash
kubectl apply -f - <<'EOF'
apiVersion: inference.takuya.dev/v1alpha1
kind: AIInferenceService
metadata:
  name: fallback-test
  namespace: default
spec:
  modelImage: "123456789012.dkr.ecr.ap-northeast-1.amazonaws.com/vllm:latest"
  gpuNodePoolRef: "karpenter-gpu-g5g"
  minReplicas: 1
  maxReplicas: 2
  scalingMetric:
    type: gpuUtilization
    targetValue: 60
    prometheusURL: "http://prometheus-kube-prometheus-prometheus:9090"
  bedrockFallback:
    enabled: true
    modelId: "anthropic.claude-3-haiku-20240307-v1:0"
    gpuProvisionTimeoutSeconds: 30    # 30秒でタイムアウト (実験用)
  selfHealing:
    restartOnOOM: true
    maxRestartAttempts: 3
EOF

# Phase の変化を監視する
# Provisioning → (30秒後) → Fallback → (GPU起動後) → Running の順で変化する
kubectl get ais fallback-test -w

# アノテーションでプロビジョニング開始時刻が記録されていることを確認する
kubectl get ais fallback-test \
  -o jsonpath='{.metadata.annotations.inference\.takuya\.dev/provisioning-start-time}'
# 2026-09-20T10:00:00Z  ← Operator が設定した開始時刻

# フォールバック後の ActiveBackend を確認する
kubectl get ais fallback-test \
  -o jsonpath='{.status.activeBackend}'
# bedrock  ← フォールバック中

# Chatwork に通知が来ていることを確認 (設定済みの場合)
```

### シナリオ 4: 自己修復 (OOMKilled) のシミュレーション

非常に小さい memory limit を設定して OOMKilled を発生させる。

```bash
kubectl apply -f - <<'EOF'
apiVersion: inference.takuya.dev/v1alpha1
kind: AIInferenceService
metadata:
  name: oom-test
  namespace: default
spec:
  modelImage: "nginx:latest"
  gpuNodePoolRef: "karpenter-gpu-g5g"
  minReplicas: 1
  maxReplicas: 1
  scalingMetric:
    type: queueDepth
    targetValue: 10
  selfHealing:
    restartOnOOM: true
    maxRestartAttempts: 3
  resources:
    requests:
      cpu: "10m"
      memory: "4Mi"    # 意図的に小さく設定して OOM を誘発する
    limits:
      cpu: "50m"
      memory: "4Mi"
EOF

# Deployment の memory limit が 25% ずつ増えることを確認する
# Pod が OOMKilled → Operator が bumpMemoryLimit を実行 → Deployment 更新
kubectl get deployment oom-test -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'
# 初期: 4Mi → OOM後: 5Mi (≒4Mi × 1.25) → 再OOM後: 6Mi ...

# RestartCount が増加することを確認する
kubectl get ais oom-test -o jsonpath='{.status.restartCount}'

# maxRestartAttempts(3) 超過後は Degraded に遷移する
kubectl get ais oom-test -o jsonpath='{.status.phase}'
# Degraded

kubectl delete ais oom-test
```

---

## スケーリング反応速度の計測

自作コントローラーと KEDA の反応速度を定量比較するためのシナリオ。
Track B (EKS) 環境が必要。

### Step 1: 負荷を注入する

```bash
# SQS キューにメッセージを投入する
./test/load/inject_load.sh \
  inference-queue \        # キュー名
  50                       # メッセージ数 (targetValue=10 なので 5 レプリカ必要になる)
```

### Step 2: スケールアウトの反応時間を計測する

```bash
# 計測開始 (inject_load.sh と同時実行)
./test/load/measure_scale_latency.sh \
  llama-3-8b \    # AIS 名
  default \       # Namespace
  5 \             # 期待するレプリカ数
  /tmp/latency.csv

# 出力例:
# [2026-09-20T10:00:05] Scale-out detected!
#   From: 1 replicas
#   To:   5 replicas
#   Latency: 7.235s (7235ms)
# [2026-09-20T10:00:05] Result saved to /tmp/latency.csv
```

### Step 3: KEDA と比較する

```bash
# CONTROLLER_TYPE 環境変数で計測データにラベルを付ける
# 自作コントローラーの計測
CONTROLLER_TYPE=custom-operator ./test/load/measure_scale_latency.sh ...

# KEDA に切り替えて同条件で計測
CONTROLLER_TYPE=keda ./test/load/measure_scale_latency.sh ...

# CSV で比較 (GNU awk)
awk -F, 'NR>1 {sum[$6]+=$3; count[$6]++}
         END {for (k in sum) printf "%s: avg=%.3fs\n", k, sum[k]/count[k]}' \
  /tmp/latency.csv

# 期待する結果例:
# custom-operator: avg=7.235s   ← ポーリング 5 秒 + 処理時間
# keda:            avg=18.412s  ← ポーリング 15 秒 + HPA 更新時間
```

---

## クリーンアップ

### Track A (Kind)

```bash
# Operator を停止する (ターミナル 1 で Ctrl+C)

# CR を削除する (Deployment/Service も自動削除される)
kubectl delete ais --all

# Kind クラスターを削除する
make kind-delete

# 生成ファイルを削除する (オプション)
rm -rf bin/ config/ cover.out
```

### Track B (EKS)

```bash
# Operator のアンデプロイ
helm uninstall gpu-inference-operator -n gpu-inference-operator

# Karpenter のアンデプロイ (GPU ノードが削除されることを確認)
helm uninstall karpenter -n karpenter
kubectl wait --for=delete node -l karpenter.sh/nodepool=karpenter-gpu-g5g --timeout=5m

# CRD の削除
kubectl delete -f config/crd/bases/

# EKS クラスターの削除 (⚠️ 自分で実行する)
cd terraform/environments/dev
terraform destroy

# ECR リポジトリの削除
aws ecr delete-repository \
  --repository-name gpu-inference-operator \
  --force \
  --region ap-northeast-1

# SSM パラメーターの削除
aws ssm delete-parameter --name "/gpu-inference-operator-lab/chatwork-token"
aws ssm delete-parameter --name "/gpu-inference-operator-lab/chatwork-room-id"

# S3 / DynamoDB (tfstate 管理) は必要に応じて削除
```

---

## トラブルシューティング

### `make manifests` が失敗する

```
Error: controller-gen not found
```

→ `make controller-gen` を先に実行して `bin/controller-gen` をインストールする。

---

### `make test` で `no such file or directory: config/crd/bases` が出る

```
Error: CRD directory not found: config/crd/bases
```

→ `make manifests` を先に実行して `config/crd/bases/` を生成する。

---

### Kind で E2E テストが `connection refused` で失敗する

→ Operator が起動しているか確認する。ターミナル 1 で `go run ./main.go ...` が動いているか確認。

---

### `kubectl get ais` で Phase が `Provisioning` から動かない (Kind)

Kind 環境には GPU ノードが存在しないため `readyReplicas` が 0 のまま。
`bedrockFallback.enabled: false` かつ Pod が nginx 等で起動できている場合は
しばらく待つと `Running` に変わる。GPU を要求している場合はノードが存在しないため `Provisioning` で止まる。これは正常な動作。

---

### EKS で Operator Pod が `CrashLoopBackOff` になる

ログを確認する:

```bash
kubectl logs -n gpu-inference-operator -l app.kubernetes.io/name=gpu-inference-operator --previous
```

よくある原因:

| エラーメッセージ | 原因と対処 |
|---|---|
| `IRSA: failed to assume role` | IRSA アノテーションが未設定。Helm の `--set serviceAccount.annotations...` を確認 |
| `unable to get certs from /tmp/k8s-webhook-server/serving-certs` | cert-manager が起動していない。`--set webhook.enabled=false` で回避可 |
| `failed to get SSM parameter` | SSM パラメーターが未設定。Step B-7 を実行 |

---

### `terraform apply` が VPC Endpoint で失敗する

```
Error: creating VPC Endpoint: ... Service not available in region
```

→ Bedrock の VPC Endpoint が `ap-northeast-1` で利用可能かを確認する。
利用できない場合は `terraform/modules/vpc/main.tf` の Bedrock Endpoint の行をコメントアウトする。

---

## 参考資料

| ドキュメント | 内容 |
|---|---|
| [`ARCHITECTURE.md`](./ARCHITECTURE.md) | システム全体の設計・コンポーネント詳細・Mermaid 図 |
| [`docs/adr/`](./docs/adr/) | 設計判断の記録 (ADR 0001〜0007) |
| [`docs/runbook.md`](./docs/runbook.md) | 本番運用手順・障害対応 |
| [`docs/star-interview-qa.md`](./docs/star-interview-qa.md) | STAR 形式の面接想定問答 |
| [`docs/benchmarks/`](./docs/benchmarks/) | スケーリング反応速度・コスト比較の計測結果 |

| フェーズドキュメント | 実装内容 |
|---|---|
| [`phase1.md`](./phase1.md) | 環境構築・CRD 設計・kubebuilder スキャフォールド |
| [`phase2.md`](./phase2.md) | Reconcile ループ基本実装 |
| [`phase3.md`](./phase3.md) | カスタムオートスケーリング |
| [`phase4.md`](./phase4.md) | Bedrock フォールバック |
| [`phase5.md`](./phase5.md) | 自己修復・Admission Webhook |
| [`phase6.md`](./phase6.md) | Operator オブザーバビリティ |
| [`phase7.md`](./phase7.md) | CI/CD パイプライン |
| [`phase8.md`](./phase8.md) | ドキュメント化・STAR 面接想定問答 |
