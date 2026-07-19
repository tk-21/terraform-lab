# Phase 3: EKS Deep Dive — Karpenter・Pod Identity・KEDA

## このフェーズの目標

ECS と同一ワークロードを EKS にデプロイし、以下を実体験として語れるようにする:
1. Karpenter NodePool の disruption budget と consolidation policy
2. Pod Identity（OIDC IRSA より新しい方式）の設定と仕組み
3. KEDA による SQS キュー深度ベーススケーリングと `minReplicaCount=0`
4. TopologySpreadConstraints と PodDisruptionBudget の連携
5. Karpenter ノードプロビジョニングのライブ観察

---

## 前提

- Phase 1 の Foundation が apply 済み
- `kubectl`, `helm` が PATH 上にあること
- Phase 2 の ECS は並走させたまま（比較のため）

---

## Step 1: terraform/eks/ の作成

### terraform/eks/main.tf を作成すること

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1"
  default_tags {
    tags = {
      Project     = "ecs-eks-deepdive"
      Environment = "lab"
      Phase       = "eks"
    }
  }
}

data "terraform_remote_state" "foundation" {
  backend = "local"
  config = {
    path = "../foundation/terraform.tfstate"
  }
}

locals {
  vpc_id             = data.terraform_remote_state.foundation.outputs.vpc_id
  private_subnet_ids = data.terraform_remote_state.foundation.outputs.private_subnet_ids
  public_subnet_ids  = data.terraform_remote_state.foundation.outputs.public_subnet_ids
  sqs_queue_url      = data.terraform_remote_state.foundation.outputs.sqs_queue_url
  sqs_queue_arn      = data.terraform_remote_state.foundation.outputs.sqs_queue_arn
  eks_node_role_arn  = data.terraform_remote_state.foundation.outputs.eks_node_role_arn
  aws_account_id     = data.terraform_remote_state.foundation.outputs.aws_account_id
  cluster_name       = "deepdive-eks"
}

data "aws_caller_identity" "current" {}
```

### terraform/eks/cluster.tf を作成すること

**EKS クラスター IAM Role**（名前: `deepdive-eks-cluster-role`）:
- Trust: `eks.amazonaws.com`
- Managed: `AmazonEKSClusterPolicy`

**EKS クラスター**:
```hcl
resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  version  = "1.30"
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids = concat(local.private_subnet_ids, local.public_subnet_ids)
    # プライベートエンドポイント: Karpenter ノードが VPC 内から API サーバーへアクセス
    endpoint_private_access = true
    # パブリックエンドポイント: ローカルから kubectl を実行するため
    endpoint_public_access  = true
    security_group_ids      = [aws_security_group.eks_cluster.id]
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  access_config {
    # API モード: aws-auth ConfigMap を廃止し EKS Access Entries を使用
    # これにより Terraform で RBAC を管理できる
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster]
}

# EKS クラスター用 Security Group
resource "aws_security_group" "eks_cluster" {
  name   = "deepdive-eks-cluster-sg"
  vpc_id = local.vpc_id
  # EKS がノードと通信するための最小限の設定（EKS マネージドルールが追加される）
}
```

**System ノードグループ**（CoreDNS, Karpenter controller 配置用）:
```hcl
resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "system"
  node_role_arn   = local.eks_node_role_arn
  subnet_ids      = local.private_subnet_ids
  ami_type        = "AL2_ARM_64"  # Graviton2
  instance_types  = ["t4g.medium"]

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 4
  }

  taint {
    key    = "CriticalAddonsOnly"
    value  = "true"
    effect = "NO_SCHEDULE"
    # このノードはシステム Pod 専用。アプリ Pod はここにスケジュールされない
    # Karpenter がワークロード Pod 用に別ノードをプロビジョニングする
  }

  labels = { "role" = "system" }
}
```

**EKS マネージドアドオン**（for_each で作成）:
```
addons:
  "vpc-cni"                : vpc-cni（Pod ネットワーク）
  "coredns"                : CoreDNS（DNS 解決）
  "kube-proxy"             : kube-proxy（ネットワークルール）
  "eks-pod-identity-agent" : Pod Identity Agent（IAM 認証の新方式）
```
各アドオンは `depends_on = [aws_eks_node_group.system]` を設定すること

vpc-cni には以下を configuration_values として設定:
```json
{"env": {"ENABLE_PREFIX_DELEGATION": "true", "WARM_PREFIX_TARGET": "1"}}
```
コメント: 「Prefix Delegation: /28 プレフィックスを割り当てることで 1 ノードあたりの Pod 数上限を大幅増加」

**Outputs**: `cluster_name`, `cluster_endpoint`, `cluster_ca`

### terraform/eks/karpenter.tf を作成すること

**Karpenter Controller IAM Role**（名前: `deepdive-karpenter-ctrl`、≤64 文字）:

Trust Policy（Pod Identity 方式）:
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "pods.eks.amazonaws.com"},
    "Action": ["sts:AssumeRole", "sts:TagSession"]
  }]
}
```
コメント: 「Pod Identity は OIDC IRSA と異なり OIDC Provider 設定が不要。
EKS Pod Identity Agent アドオンが認証を仲介する新方式（2023 年〜）」

Inline Policy（最小権限）:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2制御",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateFleet", "ec2:CreateLaunchTemplate", "ec2:DeleteLaunchTemplate",
        "ec2:DescribeAvailabilityZones", "ec2:DescribeImages", "ec2:DescribeInstances",
        "ec2:DescribeInstanceTypeOfferings", "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplates", "ec2:DescribeSecurityGroups",
        "ec2:DescribeSpotPriceHistory", "ec2:DescribeSubnets",
        "ec2:RunInstances", "ec2:TerminateInstances", "ec2:CreateTags"
      ],
      "Resource": "*"
    },
    {
      "Sid": "Spot割り込みキュー",
      "Effect": "Allow",
      "Action": ["sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ReceiveMessage"],
      "Resource": "<karpenter_interruption_queue_arn>"
    },
    {
      "Sid": "ノードInstanceProfile",
      "Effect": "Allow",
      "Action": ["iam:PassRole"],
      "Resource": "<eks_node_role_arn>"
    },
    {
      "Sid": "EKSクラスター情報",
      "Effect": "Allow",
      "Action": ["eks:DescribeCluster"],
      "Resource": "<cluster_arn>"
    }
  ]
}
```

**Karpenter Pod Identity Association**:
```hcl
resource "aws_eks_pod_identity_association" "karpenter" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "karpenter"
  service_account = "karpenter"
  role_arn        = aws_iam_role.karpenter_controller.arn
  # この設定により、karpenter namespace の karpenter ServiceAccount の Pod が
  # karpenter_controller IAM Role を自動的に取得できる
  # OIDC IRSA と違い ServiceAccount の annotation は不要
}
```

**Karpenter Spot 割り込み SQS キュー**:
- name: `deepdive-karpenter-interrupt`
- `message_retention_seconds = 300`
- コメント: 「Spot 割り込み通知を受け取り、Karpenter がノードを安全に退避させる」

**EventBridge Rule**: EC2 Spot Instance Interruption Warning → SQS に転送

**Outputs**: `karpenter_role_arn`, `interruption_queue_url`

### terraform/eks/addon_roles.tf を作成すること

以下のロールを Pod Identity 方式で作成すること（for_each で まとめて作成）:

**1. AWS Load Balancer Controller 用**（名前: `deepdive-lbc-role`）:
- Trust: `pods.eks.amazonaws.com`
- Policy: 公式 LBC IAM Policy（インライン）—  
  実際のポリシー内容は helm install 後に以下で確認:  
  `curl -s https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json`
- Pod Identity Association: namespace=`kube-system`, sa=`aws-load-balancer-controller`

**2. KEDA Operator 用**（名前: `deepdive-keda-role`）:
- Trust: `pods.eks.amazonaws.com`
- Inline: `sqs:GetQueueAttributes, GetQueueUrl` on SQS ARN のみ
- Pod Identity Association: namespace=`keda`, sa=`keda-operator`

**3. API Server 用**（名前: `deepdive-api-role`）:
- Trust: `pods.eks.amazonaws.com`
- Inline: SQS SendMessage on queue ARN のみ
- Pod Identity Association: namespace=`deepdive`, sa=`api-server`

**4. Job Worker 用**（名前: `deepdive-worker-role`）:
- Trust: `pods.eks.amazonaws.com`
- Inline: `sqs:ReceiveMessage, DeleteMessage, GetQueueAttributes` on queue ARN のみ
- Pod Identity Association: namespace=`deepdive`, sa=`job-worker`

---

## Step 2: Terraform 実行

```bash
cd terraform/eks
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# kubeconfig 更新
aws eks update-kubeconfig --name deepdive-eks --region ap-northeast-1

# クラスター確認
kubectl get nodes
kubectl get pods -A
```

---

## Step 3: Karpenter インストール

```bash
# Karpenter の最新安定バージョンを確認して使用すること
KARPENTER_VERSION="1.0.0"  # https://github.com/aws/karpenter/releases で確認
CLUSTER_NAME="deepdive-eks"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

helm upgrade --install karpenter \
  oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace karpenter \
  --create-namespace \
  --set settings.clusterName="${CLUSTER_NAME}" \
  --set settings.interruptionQueue="deepdive-karpenter-interrupt" \
  --set controller.resources.requests.cpu=100m \
  --set controller.resources.requests.memory=256Mi \
  --set controller.resources.limits.cpu=500m \
  --set controller.resources.limits.memory=512Mi \
  --set tolerations[0].key=CriticalAddonsOnly \
  --set tolerations[0].operator=Exists \
  --wait

# Karpenter の起動確認
kubectl get pods -n karpenter
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=20
```

---

## Step 4: Karpenter NodePool と EC2NodeClass の作成

### k8s/manifests/karpenter-nodepool.yaml を作成すること

```yaml
# EC2NodeClass: AWS リソースの設定（サブネット、AMI、ストレージ）
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: workload
spec:
  amiFamily: AL2

  # EKS ノードが使う IAM Role（Instance Profile 経由）
  role: deepdive-eks-node-role

  subnetSelectorTerms:
    - tags:
        kubernetes.io/role/internal-elb: "1"  # Private Subnet のみ選択

  securityGroupSelectorTerms:
    - tags:
        aws:eks:cluster-name: deepdive-eks  # EKS が管理する SG を自動選択

  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 20Gi
        volumeType: gp3
        encrypted: true  # 全ディスク暗号化

---
# NodePool: Kubernetes レベルのスケジューリング設定
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: workload
spec:
  template:
    metadata:
      labels:
        role: workload  # nodeSelector で参照する
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: workload

      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["arm64"]  # Graviton2 統一

        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]  # Spot インスタンス優先

        - key: node.kubernetes.io/instance-type
          operator: In
          values:
            - c6g.medium
            - c6g.large
            - m6g.medium
            - m6g.large
            - r6g.medium
          # 複数インスタンスタイプを指定する理由:
          # 単一タイプだと Spot 枯渇時に起動できない
          # 複数を許可することで Spot 可用性を最大化する

        - key: topology.kubernetes.io/zone
          operator: In
          values: ["ap-northeast-1a", "ap-northeast-1c"]

      # ノードの有効期限: 一定期間で強制的に新しいノードに入れ替え
      # セキュリティパッチ適用とドリフト検出のために重要
      expireAfter: 168h  # 7 日

  disruption:
    consolidationPolicy: WhenUnderutilized
    # WhenUnderutilized: 使用率が低い複数ノードを 1 台に統合してコスト削減
    # WhenEmpty: Pod がいないノードのみ削除（より保守的。EKS クリティカル環境向け）
    consolidateAfter: 30s

    budgets:
      - nodes: "20%"
        # 同時に disruption できるノードは最大 20%
        # PodDisruptionBudget と連携: PDB の minAvailable を守りながらノードを統合
        # 例: 10 ノードのうち同時に退避できるのは 2 台

  limits:
    cpu: 20
    memory: 40Gi
```

```bash
kubectl apply -f k8s/manifests/karpenter-nodepool.yaml
kubectl get nodepool
kubectl get ec2nodeclass
```

---

## Step 5: AWS Load Balancer Controller のインストール

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm upgrade --install aws-load-balancer-controller \
  eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName=deepdive-eks \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set tolerations[0].key=CriticalAddonsOnly \
  --set tolerations[0].operator=Exists \
  --wait

kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

---

## Step 6: KEDA のインストール

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update

helm upgrade --install keda kedacore/keda \
  --namespace keda \
  --create-namespace \
  --set tolerations[0].key=CriticalAddonsOnly \
  --set tolerations[0].operator=Exists \
  --wait

kubectl get pods -n keda
```

---

## Step 7: Kubernetes マニフェストの作成

### k8s/manifests/namespace.yaml を作成すること

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: deepdive
  labels:
    app: deepdive
```

### k8s/manifests/serviceaccounts.yaml を作成すること

```yaml
# API Server ServiceAccount
# Pod Identity Association は Terraform 側で設定済み
# OIDC IRSA と違い annotations は不要（Pod Identity Agent が自動的に処理）
apiVersion: v1
kind: ServiceAccount
metadata:
  name: api-server
  namespace: deepdive
---
# Job Worker ServiceAccount
apiVersion: v1
kind: ServiceAccount
metadata:
  name: job-worker
  namespace: deepdive
```

### k8s/manifests/api.yaml を作成すること

以下の YAML を生成すること（Foundation の terraform output から ECR URL と SQS URL を取得して埋め込む）:

```yaml
# API サーバー Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-server
  namespace: deepdive
  labels:
    app: api-server
spec:
  replicas: 2
  selector:
    matchLabels:
      app: api-server
  template:
    metadata:
      labels:
        app: api-server
    spec:
      serviceAccountName: api-server

      # Topology Spread: AZ に均等分散（ECS の spread(AZ) と同等だが明示的）
      topologySpreadConstraints:
        - maxSkew: 1  # AZ 間の Pod 数の偏り許容値
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          # DoNotSchedule: AZ が偏るならスケジュールを保留（厳格）
          # ScheduleAnyway: 偏っても強行スケジュール（緩い）
          labelSelector:
            matchLabels:
              app: api-server

      # Karpenter の workload ノードに配置
      nodeSelector:
        role: workload

      containers:
        - name: api
          image: <ECR_API_URL>:latest
          ports:
            - containerPort: 8080
              name: http
          env:
            - name: AWS_REGION
              value: ap-northeast-1
            - name: SQS_QUEUE_URL
              value: <SQS_QUEUE_URL>

          # resources は Karpenter のノードサイジングに直接影響する
          # requests に基づいてノードのインスタンスタイプを決定する
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi

          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 30
            failureThreshold: 3

          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
---
# PodDisruptionBudget: Karpenter の node consolidation 中も最低 1 Pod を維持
# Karpenter は PDB を確認してから disruption を実行する
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: api-server-pdb
  namespace: deepdive
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: api-server
---
# Service
apiVersion: v1
kind: Service
metadata:
  name: api-server
  namespace: deepdive
spec:
  selector:
    app: api-server
  ports:
    - port: 80
      targetPort: 8080
      protocol: TCP
---
# Ingress: AWS LBC が ALB を自動作成する
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api-server
  namespace: deepdive
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    # public_subnet_ids を Terraform output から取得して設定すること
    alb.ingress.kubernetes.io/subnets: <PUBLIC_SUBNET_IDS>
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
                name: api-server
                port:
                  number: 80
```

### k8s/manifests/worker.yaml を作成すること

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: job-worker
  namespace: deepdive
  labels:
    app: job-worker
spec:
  replicas: 1
  selector:
    matchLabels:
      app: job-worker
  template:
    metadata:
      labels:
        app: job-worker
    spec:
      serviceAccountName: job-worker
      nodeSelector:
        role: workload

      # グレースフルシャットダウン（ECS の stopTimeout=30 相当だが長め）
      # KEDA が 0 スケールする際や Karpenter がノードを退避させる際にも有効
      terminationGracePeriodSeconds: 60

      containers:
        - name: worker
          image: <ECR_WORKER_URL>:latest
          env:
            - name: AWS_REGION
              value: ap-northeast-1
            - name: SQS_QUEUE_URL
              value: <SQS_QUEUE_URL>
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 250m
              memory: 256Mi
---
# KEDA ScaledObject: SQS キュー深度でワーカーをスケール
# ECS の CloudWatch Alarm + Step Scaling との最大の違い:
#   1. minReplicaCount=0 でゼロスケール可能（ECS は min=1 が実質的な制約）
#   2. KEDA が 15 秒おきにポーリング（CloudWatch Alarm の 60 秒より応答が早い）
#   3. queueLength ベース: 1 レプリカあたりのメッセージ数で比例スケール
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: job-worker
  namespace: deepdive
spec:
  scaleTargetRef:
    name: job-worker

  minReplicaCount: 0
  # 0 の意味: キューが空なら Pod をゼロにしてリソースを解放する
  # Karpenter はその後ノードも削除（consolidation）→ EC2 コスト ゼロ
  maxReplicaCount: 10
  pollingInterval: 15  # 秒ごとに SQS の深度を確認

  triggers:
    - type: aws-sqs-queue
      authenticationRef:
        name: keda-pod-identity
      metadata:
        queueURL: <SQS_QUEUE_URL>
        queueLength: "5"
        # 1 レプリカが担当するメッセージ数: 10 メッセージ → 2 レプリカ起動
        awsRegion: ap-northeast-1
        activationQueueLength: "1"
        # 最初の 1 レプリカを起動する最小メッセージ数（0 から 1 への起動閾値）
---
# KEDA TriggerAuthentication: Pod Identity を KEDA に紐付け
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: keda-pod-identity
  namespace: deepdive
spec:
  podIdentity:
    provider: aws
    # KEDA が Pod Identity（deepdive-keda-role）を使って SQS にアクセス
```

---

## Step 8: マニフェストのデプロイ

```bash
# Foundation outputs から値を取得してマニフェストを更新すること
ECR_API=$(cd terraform/foundation && terraform output -raw ecr_api_url)
ECR_WORKER=$(cd terraform/foundation && terraform output -raw ecr_worker_url)
SQS_URL=$(cd terraform/foundation && terraform output -raw sqs_queue_url)
PUBLIC_SUBNETS=$(cd terraform/foundation && terraform output -json public_subnet_ids | jq -r 'join(",")')

# マニフェスト内のプレースホルダーを実際の値に置換すること
# sed を使って k8s/manifests/*.yaml 内の <ECR_API_URL> 等を置換する

# デプロイ
kubectl apply -f k8s/manifests/namespace.yaml
kubectl apply -f k8s/manifests/serviceaccounts.yaml
kubectl apply -f k8s/manifests/karpenter-nodepool.yaml
kubectl apply -f k8s/manifests/api.yaml
kubectl apply -f k8s/manifests/worker.yaml
```

---

## Step 9: 動作確認と深掘り観察

### Karpenter ノードプロビジョニングの観察
```bash
# Pod が Pending になったら Karpenter がノードを作成する
kubectl get pods -n deepdive --watch &

# Karpenter のプロビジョニングログをリアルタイムで確認
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --follow &

# ノードの出現を監視
kubectl get nodes -l role=workload --watch

# NodeClaim（Karpenter がノードを申請した記録）
kubectl get nodeclaim -o wide
```

**記録すること**:
- Pod が Pending になってからノードが Ready になるまで: _____ 秒
- Karpenter がどのインスタンスタイプを選んだか: _____

### ALB の作成確認
```bash
# AWS LBC が Ingress リソースを検知して ALB を作成する（2-3 分かかる）
kubectl get ingress -n deepdive --watch

# ALB の DNS 名が付与されたら確認
EKS_ALB=$(kubectl get ingress api-server -n deepdive \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "EKS ALB: $EKS_ALB"
curl -s http://$EKS_ALB/health
```

### KEDA スケーリング確認
```bash
SQS_URL=$(cd terraform/foundation && terraform output -raw sqs_queue_url)

# 30 メッセージを送信（Worker が 6 レプリカ = 30/5 になるはず）
for i in $(seq 1 30); do
  aws sqs send-message \
    --queue-url $SQS_URL \
    --message-body "eks-load-test-${i}"
done

# KEDA の ScaledObject と HPA を確認（KEDA は内部で HPA を作成する）
kubectl get scaledobject -n deepdive
kubectl get hpa -n deepdive
kubectl get pods -n deepdive -l app=job-worker --watch
```

**記録すること**:
- KEDA がスケールアウトを開始するまで: _____ 秒（ポーリング間隔 15 秒以内のはず）
- 新しい Pod が Running になるまで（ノード追加含む）: _____ 秒

### ゼロスケールの確認（ECS との決定的な違い）
```bash
# キューが空になった後、Worker が 0 になることを確認
watch kubectl get pods -n deepdive

# その後 Karpenter がノードを削除することを確認（consolidateAfter=30s）
watch kubectl get nodes -l role=workload
```

### Node Consolidation の観察
```bash
# 全 Pod を削除してノード統合を確認
kubectl scale deployment api-server job-worker -n deepdive --replicas=0

# Karpenter が 30 秒後にノードを削除することをログで確認
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --follow

# ノードが削除されていく様子
kubectl get nodes -l role=workload --watch
```

---

## Phase 3 完了チェック

- [ ] EKS クラスターが起動し `kubectl get nodes` に system ノードが見える
- [ ] Karpenter が workload ノードをプロビジョニングした（NodeClaim が作成された）
- [ ] EKS ALB から `/health` が返る
- [ ] KEDA が SQS メッセージ数に応じて Worker レプリカを増やした
- [ ] キューが空になった後 Worker が 0 スケールになった
- [ ] Karpenter がノードを削除した

## 口頭説明チェック（5 分で答えられること）

1. 「Karpenter と Cluster Autoscaler の違いを 3 つ挙げよ」
   - Provisioner: Karpenter は EC2 を直接作成 / CA は ASG を操作
   - Consolidation: Karpenter は使用率低下で統合 / CA は空ノードのみ削除
   - 柔軟性: Karpenter は NodePool で詳細なインスタンスタイプ制御 / CA は ASG 設定依存

2. 「Pod Identity と OIDC IRSA の違いと、どちらを新規プロジェクトで選ぶか」

3. 「KEDA の minReplicaCount=0 が実際のビジネス価値として何をもたらすか」

4. 「PodDisruptionBudget が Karpenter の consolidation とどう連携するか」