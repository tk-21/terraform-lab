# Phase 1: VPC (Endpoint専用) + EKS + Karpenter + GPU NodePool

## このフェーズの目標

- NAT Gateway **なし**のVPCを構築し、必要なVPC Endpointをすべて設定する
- EKS クラスター (v1.30) をプロビジョニングする
- Karpenter をインストールし、**CPUノードプール** (arm64/Graviton) と **GPUノードプール** (g4dn.xlarge, Spot) を定義する
- NVIDIA Device Plugin をDaemonSetとしてデプロイし、`nvidia.com/gpu` リソースを有効化する
- KarpenterがGPU Spotノードを動的にプロビジョニングできることを検証する

---

## 実装手順

### Step 1: Terraform ディレクトリ構造を作成

以下のディレクトリ・ファイルをすべて作成すること。

```
terraform/
├── environments/dev/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars
└── modules/
    ├── vpc/
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    ├── eks/
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    └── karpenter/
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

---

### Step 2: VPC モジュール (`terraform/modules/vpc/`)

#### 設計仕様

- CIDR: `10.0.0.0/16`
- AZ: `ap-northeast-1a`, `ap-northeast-1c`, `ap-northeast-1d` の3AZ
- **パブリックサブネット**: ALB用 (各AZ /24)
- **プライベートサブネット**: EKS Node用 (各AZ /20) ← NAT GWなし
- **VPC Endpoint専用サブネット**: Interface Endpoint配置用 (各AZ /28)

#### VPC Endpoints (全必須)

**Gateway型**:
```
- aws_vpc_endpoint "s3" (type = "Gateway") → プライベート/Endpoint専用サブネットのルートテーブルに関連付け
```

**Interface型** (以下をすべて `aws_vpc_endpoint` で作成):
```
- ecr_api       : com.amazonaws.ap-northeast-1.ecr.api
- ecr_dkr       : com.amazonaws.ap-northeast-1.ecr.dkr
- sts           : com.amazonaws.ap-northeast-1.sts
- ec2           : com.amazonaws.ap-northeast-1.ec2
- logs          : com.amazonaws.ap-northeast-1.logs
- ssm           : com.amazonaws.ap-northeast-1.ssm
- ssmmessages   : com.amazonaws.ap-northeast-1.ssmmessages
- elb           : com.amazonaws.ap-northeast-1.elasticloadbalancing
- aps           : com.amazonaws.ap-northeast-1.aps
- bedrock       : com.amazonaws.ap-northeast-1.bedrock-runtime
- eks           : com.amazonaws.ap-northeast-1.eks
```

Interface型は `private_dns_enabled = true` を必ず設定すること。
Endpoint専用セキュリティグループ: VPC CIDR (`10.0.0.0/16`) からの443インバウンドのみ許可。

**実装上の注意**:
- `aws_vpc_endpoint` は `for_each` で一元管理すること
- 各エンドポイントには `Name` タグをつけること
- Endpointサブネットは `vpc_endpoint_subnet_ids` として出力すること

---

### Step 3: EKS モジュール (`terraform/modules/eks/`)

#### 設計仕様

- EKS バージョン: `1.30`
- Managed Node Group (システムワークロード用): `c7g.medium`, arm64, オンデマンド, 2台固定
  - Karpenter, CoreDNS, kube-proxy など基盤PodはこのMNGに配置
  - Taint: なし (tolerationなしでスケジュール可能にする)
- EKS Add-ons: `vpc-cni`, `coredns`, `kube-proxy`, `aws-ebs-csi-driver`
  - `aws-ebs-csi-driver` はモデルキャッシュ用EBSボリュームのため必須
- クラスターセキュリティグループ: VPC内通信 + VPC Endpointからの443許可

#### IRSA (IAM Roles for Service Accounts) 設定

以下のIRSAロールを作成すること:
1. `karpenter-controller` ロール (EKS IAMロール名64文字制限に注意)
   - `eks:DescribeCluster`, `ec2:*` (Karpenter必要権限に絞ること)
   - `pricing:GetProducts` (Spot価格取得)
   - `sqs:*` (中断通知キュー)
2. `aws-load-balancer-controller` ロール
3. `ebs-csi-controller` ロール

#### Karpenter 用 SQS キュー

Spot中断通知 (EC2 Instance Interruption Warning) を受け取るSQSキューを作成:
- キュー名: `eks-ai-inference-platform-karpenter`
- EventBridge ルール: `aws.ec2` ソースの `EC2 Spot Instance Interruption Warning` イベント → SQS

---

### Step 4: Karpenter モジュール (`terraform/modules/karpenter/`)

Karpenter の Helm インストール + NodePool/EC2NodeClass を管理する。

#### Helm インストール

```hcl
resource "helm_release" "karpenter" {
  # バージョン固定: 互換性問題を防ぐため
  chart   = "karpenter"
  version = "0.37.0"
  # (最新安定版に調整すること)
}
```

#### `k8s/karpenter/ec2-node-class.yaml`

```yaml
apiVersion: karpenter.k8s.aws/v1beta1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: Bottlerocket  # セキュリティ強化OS (不要なパッケージなし)
  role: "karpenter-node-role"  # Karpenterがノードに付与するIAMロール
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "eks-ai-inference-platform"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "eks-ai-inference-platform"
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 50Gi
        volumeType: gp3
        encrypted: true
        # コスト最適化: gp3はgp2比で20%安く、スループット設定可能
---
apiVersion: karpenter.k8s.aws/v1beta1
kind: EC2NodeClass
metadata:
  name: gpu
spec:
  amiFamily: AL2  # GPU DriverはAL2との互換性が最も安定
  role: "karpenter-node-role"
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "eks-ai-inference-platform"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "eks-ai-inference-platform"
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 100Gi
        volumeType: gp3
        encrypted: true
        # モデル重みキャッシュ用: Phi-3-mini ~2GB、余裕をもって100GB
  userData: |
    #!/bin/bash
    # NVIDIA Driverは AL2 EKS最適化AMIに含まれるため追加不要
    # CUDA バージョン確認用ログ出力
    nvidia-smi > /var/log/nvidia-smi-startup.log 2>&1 || true
```

#### `k8s/karpenter/node-pool-cpu.yaml`

```yaml
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: cpu-general
spec:
  template:
    metadata:
      labels:
        node-role: cpu-general
    spec:
      nodeClassRef:
        name: default
      requirements:
        # arm64/Graviton2 を強制: x86比でコスト20%削減
        - key: kubernetes.io/arch
          operator: In
          values: ["arm64"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: karpenter.k8s.aws/instance-family
          operator: In
          values: ["c7g", "m7g", "r7g"]
        - key: karpenter.k8s.aws/instance-size
          operator: NotIn
          values: ["nano", "micro"]
      taints: []
  limits:
    cpu: "100"
    memory: 400Gi
  disruption:
    consolidationPolicy: WhenUnderutilized
    consolidateAfter: 30s
```

#### `k8s/karpenter/node-pool-gpu.yaml`

```yaml
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: gpu-inference
spec:
  template:
    metadata:
      labels:
        node-role: gpu-inference
    spec:
      nodeClassRef:
        name: gpu
      requirements:
        # GPU推論専用NodePool: amd64のみ (NVIDIA GPU Driverの制約)
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        # Spotを最優先: 推論ワークロードはステートレスなので中断耐性あり
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
        # g4dn: T4 GPU (推論最適化)、g5: A10G GPU (より高性能)
        - key: karpenter.k8s.aws/instance-family
          operator: In
          values: ["g4dn", "g5"]
        - key: karpenter.k8s.aws/instance-size
          operator: In
          values: ["xlarge", "2xlarge"]
        # GPU有無を明示: このNodePoolはGPUノードのみ
        - key: karpenter.k8s.aws/instance-gpu-manufacturer
          operator: In
          values: ["nvidia"]
      # GPU Spotが枯渇した場合のみon-demandにフォールバック
      taints:
        - key: "nvidia.com/gpu"
          value: "true"
          effect: NoSchedule
  limits:
    # コスト上限: g4dn.xlarge 1台 = T4 1枚
    # 推論同時実行数を制限しコスト暴走を防ぐ
    "nvidia.com/gpu": "4"
  disruption:
    # 推論中はノードを削除しない: 処理中断によるエラー防止
    consolidationPolicy: WhenEmpty
    consolidateAfter: 5m
```

---

### Step 5: NVIDIA Device Plugin (`k8s/nvidia/device-plugin.yaml`)

```yaml
# NVIDIA Device PluginはGPUノードのみにDaemonSetとして配置
# CPUノードへの誤配置を防ぐためNodeSelectorを必ず設定
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-device-plugin-daemonset
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: nvidia-device-plugin-ds
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        name: nvidia-device-plugin-ds
    spec:
      # GPUノードにのみ配置 (Karpenter GPUノードはこのtolerationが必要)
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      priorityClassName: system-node-critical
      containers:
        - name: nvidia-device-plugin-ctr
          image: nvcr.io/nvidia/k8s-device-plugin:v0.14.5
          env:
            - name: FAIL_ON_INIT_ERROR
              value: "false"
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: device-plugin
              mountPath: /var/lib/kubelet/device-plugins
      volumes:
        - name: device-plugin
          hostPath:
            path: /var/lib/kubelet/device-plugins
      nodeSelector:
        # KarpenterがGPUノードに付与するラベルでフィルタリング
        karpenter.k8s.aws/instance-gpu-manufacturer: "nvidia"
```

---

### Step 6: environments/dev/main.tf

上記モジュールを呼び出す root module を作成すること:

```hcl
# 東京リージョン固定
terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
    helm = { source = "hashicorp/helm", version = "~> 2.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.0" }
  }
  backend "s3" {
    # バックエンド: デプロイ前に手動でS3バケットを作成すること
    bucket = "tfstate-eks-ai-inference-platform"
    key    = "dev/terraform.tfstate"
    region = "ap-northeast-1"
  }
}

module "vpc"       { source = "../../modules/vpc"       ... }
module "eks"       { source = "../../modules/eks"       ... }
module "karpenter" { source = "../../modules/karpenter" ... }
```

---

### Step 7: AWS Load Balancer Controller インストール

Helm でインストールし、ALB Ingress が機能することを確認する。

```bash
helm repo add eks https://aws.github.io/eks-charts
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=eks-ai-inference-platform \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
```

---

## 検証手順

Phase1完了後、以下をすべて確認すること:

```bash
# 1. システムノード (MNG) が Running
kubectl get nodes -l role=system

# 2. Karpenter Pod が Running
kubectl get pods -n karpenter

# 3. NodePool が作成済み
kubectl get nodepools

# 4. EC2NodeClass が作成済み
kubectl get ec2nodeclasses

# 5. GPU NodePoolのテスト用Pod をデプロイしKarpenterがg4dnを起動することを確認
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test
spec:
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  containers:
    - name: cuda-test
      image: nvidia/cuda:12.3.0-base-ubuntu22.04
      command: ["nvidia-smi"]
      resources:
        limits:
          nvidia.com/gpu: "1"
  restartPolicy: Never
EOF

# 5分待ってKarpenterがg4dnを起動しPodが完了することを確認
kubectl wait --for=condition=Succeeded pod/gpu-test --timeout=600s
kubectl logs gpu-test  # NVIDIA-SMI の出力が表示されること

# 6. テスト後クリーンアップ (コスト節約)
kubectl delete pod gpu-test

# 7. VPC Endpoint経由のアクセス確認 (NATを使っていないこと)
# ECR からイメージPull、S3 へのアクセスがすべてEndpoint経由であることをVPC Flow Logsで確認
```

---

## コスト注意事項

- **GPU テストPodは必ず削除**すること (g4dn.xlarge は ~$0.526/h)
- Karpenter の `consolidateAfter: 5m` により、テストPod削除後5分以内にGPUノードは自動返却される
- MNG の c7g.medium は ~$0.034/h × 2台 = $0.068/h (EKSクラスター稼働中は常時課金)

---

## Phase 1 完了チェックリスト

- [ ] VPC作成完了 (NAT GW なし確認)
- [ ] 全VPC Endpoint作成完了 (13エンドポイント)
- [ ] EKS クラスター作成完了
- [ ] Karpenter インストール完了
- [ ] CPU NodePool / GPU NodePool 定義済み
- [ ] NVIDIA Device Plugin DaemonSet 稼働中
- [ ] GPU テスト Pod でnvidia-smi 確認済み
- [ ] ALB Controller インストール完了
- [ ] テスト Pod 削除 (コスト節約) 済み

---

## 口頭説明チェックポイント (15分ノートなし)

- KarpenterとManaged Node Groupの使い分けを説明できるか?
- GPU NodePoolでSpotを選んだ理由とリスク対策を説明できるか?
- NAT GWなし構成でECR/S3にアクセスできる仕組みを説明できるか?
- BottlerocketとAL2を使い分けた理由を説明できるか?