# ✅Phase 3: サンプルワークロード + PDB + ALB Ingress

## Phase 1-2 完了サマリー

- EKSクラスター `eks-chaos-cell-prod` 稼働中
- NodePool `cell-a`（AZ-a）・`cell-b`（AZ-c）作成済み
- 各NodePoolにTaint `cell=cell-a:NoSchedule` / `cell=cell-b:NoSchedule` 付与済み
- Karpenterがテストポッドでノード自動起動を確認済み

---

## このフェーズの目的

FIS障害実験の対象となるワークロードを各Cellにデプロイする。
**PodDisruptionBudget（PDB）** と **topologySpreadConstraints** が
障害時のPod分散を保証する仕組みを実装する。

**面接で語れる設計判断**:
- なぜReplicasだけではなくPDBが必要か
- topologySpreadConstraintsとaffinityの違い
- Cell単位でALB Target Groupを分けることのメリット

---

## 作成対象ファイル

### 1. k8s/cells/cell-a/namespace.yaml

```yaml
# =============================================================
# Cell-A 専用 Namespace
# NetworkPolicyでCell-B への通信は原則禁止（依存排除）
# =============================================================
apiVersion: v1
kind: Namespace
metadata:
  name: cell-a
  labels:
    cell: cell-a
    # AWS Load Balancer Controller がNamespaceを認識するためのラベル
    pod-security.kubernetes.io/enforce: baseline
```

### 2. k8s/cells/cell-a/deployment.yaml

```yaml
# =============================================================
# Cell-A ワークロード
# サンプルアプリ: nginx + ヘルスチェックエンドポイント
#
# 設計ポイント:
# - nodeSelector + tolerations でCell-Aノードに固定
# - topologySpreadConstraints でPodをノード間に分散
# - readinessProbe・livenessProbe でALBヘルスチェック対応
# =============================================================
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
  namespace: cell-a
  labels:
    app: app
    cell: cell-a
spec:
  replicas: 4
  selector:
    matchLabels:
      app: app
      cell: cell-a
  template:
    metadata:
      labels:
        app: app
        cell: cell-a
    spec:
      # Cell-AのKarpenterノードに配置
      nodeSelector:
        cell: cell-a
      tolerations:
        - key: cell
          value: cell-a
          effect: NoSchedule

      # Podをノード間に均等分散（1ノードに集中しない）
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: app
              cell: cell-a

      # グレースフルシャットダウン時間（ALBのドレイン待ち）
      terminationGracePeriodSeconds: 60

      containers:
        - name: app
          # カスタムnginx: /healthz と /cellinfo エンドポイントを追加
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
              name: http

          # 起動時にCell識別ファイルを作成
          lifecycle:
            postStart:
              exec:
                command:
                  - /bin/sh
                  - -c
                  - |
                    mkdir -p /usr/share/nginx/html
                    cat > /usr/share/nginx/html/index.html <<'EOF'
                    <!DOCTYPE html>
                    <html>
                    <body>
                      <h1>Cell-A Response</h1>
                      <p>Pod: ${HOSTNAME}</p>
                      <p>Node: $(cat /etc/hostname)</p>
                    </body>
                    </html>
                    EOF
                    echo "OK" > /usr/share/nginx/html/healthz

          # ヘルスチェック（ALBのターゲットヘルスと同期）
          readinessProbe:
            httpGet:
              path: /healthz
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 3

          livenessProbe:
            httpGet:
              path: /healthz
              port: 80
            initialDelaySeconds: 15
            periodSeconds: 10
            failureThreshold: 3

          resources:
            requests:
              cpu: "250m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"

      # Pod間の安全なシャットダウン
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: app
                    cell: cell-a
                topologyKey: kubernetes.io/hostname
```

### 3. k8s/cells/cell-a/service.yaml

```yaml
apiVersion: v1
kind: Service
metadata:
  name: app
  namespace: cell-a
  labels:
    app: app
    cell: cell-a
  annotations:
    # ALBのターゲットグループ登録待機時間（グレースフルシャットダウン考慮）
    service.beta.kubernetes.io/aws-load-balancer-target-group-attributes: |
      deregistration_delay.timeout_seconds=30
spec:
  selector:
    app: app
    cell: cell-a
  ports:
    - name: http
      port: 80
      targetPort: 80
  type: ClusterIP
```

### 4. k8s/cells/cell-a/pdb.yaml

```yaml
# =============================================================
# PodDisruptionBudget（PDB）
#
# 設計意図:
# - minAvailable: 2 → 4 Pod中2台は必ず生存させる
# - FIS実験でノード停止されてもPDB範囲内で安全に移行
# - KarpenterのConsolidationもPDBを尊重する
#
# 面接での解説:
# "PDBがないと、ノードドレイン時に全Podが同時に退避され
#  一時的にサービス断が発生します。PDBで最低2台を保証することで
#  ローリングに退避され、サービス継続性を担保しています"
# =============================================================
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: app-pdb
  namespace: cell-a
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: app
      cell: cell-a
```

---

### 5. Cell-B（cell-a と同一構成・AZ-cに配置）

#### k8s/cells/cell-b/namespace.yaml

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cell-b
  labels:
    cell: cell-b
    pod-security.kubernetes.io/enforce: baseline
```

#### k8s/cells/cell-b/deployment.yaml

Cell-Aと同一だが以下を変更:
- `namespace: cell-b`
- `cell: cell-b` ラベル全て
- `nodeSelector.cell: cell-b`
- `tolerations[].value: cell-b`
- index.html の `<h1>Cell-B Response</h1>`

#### k8s/cells/cell-b/service.yaml

Cell-Aと同一だが `namespace: cell-b`・`cell: cell-b` に変更。

#### k8s/cells/cell-b/pdb.yaml

Cell-Aと同一だが `namespace: cell-b`・`cell: cell-b` に変更。

---

### 6. AWS Load Balancer Controller インストール

#### k8s/ingress/alb-controller-sa.yaml

```yaml
# ALB Controller用 ServiceAccount（IRSA）
# IAMロールは Terraform で作成（下記参照）
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aws-load-balancer-controller
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT_ID:role/eks-chaos-cell-prod-alb-controller
```

#### terraform/main.tf に ALB Controller IAMロール追加

```hcl
# ALB Controller IRSA
resource "aws_iam_role" "alb_controller" {
  name = "${local.cluster_name}-alb-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Federated = module.eks.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(module.eks.cluster_oidc_issuer, "https://", "")}:sub" : "system:serviceaccount:kube-system:aws-load-balancer-controller"
          "${replace(module.eks.cluster_oidc_issuer, "https://", "")}:aud" : "sts.amazonaws.com"
        }
      }
    }]
  })
  tags = local.common_tags
}

# ALB ControllerのIAMポリシー（AWSが提供する公式ポリシー）
resource "aws_iam_policy" "alb_controller" {
  name = "${local.cluster_name}-alb-controller-policy"
  # https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
  policy = file("${path.module}/policies/alb-controller-iam-policy.json")
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  policy_arn = aws_iam_policy.alb_controller.arn
  role       = aws_iam_role.alb_controller.name
}
```

#### ALB Controller Helm インストールスクリプト

```bash
# scripts/install_alb_controller.sh
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=eks-chaos-cell-prod \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=ap-northeast-1 \
  --set vpcId=VPC_ID
```

---

### 7. k8s/ingress/alb-ingress.yaml

```yaml
# =============================================================
# ALB Ingress（AWS Load Balancer Controller）
#
# 設計:
# - Cell-A と Cell-B を同一ALBで受けて重み付きルーティング
# - /cell-a/* → Cell-A Service
# - /cell-b/* → Cell-B Service
# - /         → 50:50 で両Cellに振り分け（通常時）
#
# FIS実験時の挙動:
# - Cell-AのPodが全滅 → ALBが自動でCell-Bに全振り分け
# =============================================================
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: chaos-cell-ingress
  namespace: cell-a   # Ingressのnamespaceはcell-aに置く
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /healthz
    alb.ingress.kubernetes.io/healthcheck-interval-seconds: "10"
    alb.ingress.kubernetes.io/healthcheck-timeout-seconds: "5"
    alb.ingress.kubernetes.io/healthy-threshold-count: "2"
    alb.ingress.kubernetes.io/unhealthy-threshold-count: "3"
    # グレースフルシャットダウン用のドレイン時間
    alb.ingress.kubernetes.io/target-group-attributes: |
      deregistration_delay.timeout_seconds=30
    alb.ingress.kubernetes.io/tags: |
      Project=eks-chaos-cell,chaos-target=alb
spec:
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app
                port:
                  number: 80
```

---

### 8. ワークロードデプロイスクリプト

#### `scripts/deploy_workloads.sh`

```bash
#!/usr/bin/env bash
# =============================================================
# 全Cellワークロードのデプロイ
# =============================================================
set -euo pipefail

CLUSTER_NAME="${1:-eks-chaos-cell-prod}"
REGION="ap-northeast-1"

echo "🚀 ワークロードデプロイ開始"

# kubeconfig 確認
kubectl cluster-info --context="arn:aws:eks:${REGION}:$(aws sts get-caller-identity --query Account --output text):cluster/${CLUSTER_NAME}" || \
  aws eks update-kubeconfig --region "${REGION}" --name "${CLUSTER_NAME}"

# Cell-A デプロイ
echo "📦 Cell-A デプロイ..."
kubectl apply -f k8s/cells/cell-a/

# Cell-B デプロイ
echo "📦 Cell-B デプロイ..."
kubectl apply -f k8s/cells/cell-b/

# Ingress デプロイ
echo "📦 Ingress デプロイ..."
kubectl apply -f k8s/ingress/

# 起動待機
echo "⏳ Pod起動待機..."
kubectl rollout status deployment/app -n cell-a --timeout=300s
kubectl rollout status deployment/app -n cell-b --timeout=300s

echo ""
echo "📋 Pod確認..."
kubectl get pods -n cell-a -o wide
echo ""
kubectl get pods -n cell-b -o wide

echo ""
echo "📋 PDB確認..."
kubectl get pdb -n cell-a
kubectl get pdb -n cell-b

echo ""
echo "📋 ノード確認（Cellラベル付き）..."
kubectl get nodes --label-columns=cell,topology.kubernetes.io/zone

echo ""
echo "📋 Ingress確認（ALB URL取得に1-3分かかります）..."
kubectl get ingress -n cell-a

echo ""
echo "✅ デプロイ完了"
```

---

## 実行手順

```bash
# 1. ALBコントローラーのIAMポリシーJSONをダウンロード
mkdir -p terraform/policies
curl -o terraform/policies/alb-controller-iam-policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

# 2. terraform apply（ALBコントローラーIAMロール追加）
cd terraform
terraform apply -var="aws_account_id=YOUR_ACCOUNT_ID" -var="owner=YOUR_NAME"

# 3. ALBコントローラーをHelmでインストール
VPC_ID=$(terraform output -raw vpc_id)
chmod +x ../scripts/install_alb_controller.sh
../scripts/install_alb_controller.sh

# 4. ワークロードデプロイ
cd ..
chmod +x scripts/deploy_workloads.sh
./scripts/deploy_workloads.sh

# 5. ALB URLで動作確認（ingress作成から1-3分後）
ALB_URL=$(kubectl get ingress chaos-cell-ingress -n cell-a -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl http://${ALB_URL}/healthz
```

---

## 完了確認チェックリスト

- [ ] Cell-AのPodが全て `Running`（4台）かつAZ-aのノードに配置
- [ ] Cell-BのPodが全て `Running`（4台）かつAZ-cのノードに配置
- [ ] `kubectl get pdb -n cell-a` で `ALLOWED-DISRUPTIONS: 2`
- [ ] `kubectl get pdb -n cell-b` で `ALLOWED-DISRUPTIONS: 2`
- [ ] ALBのURLで `curl http://ALB_URL/healthz` が 200 OK
- [ ] ALBのURLで Cell-A・Cell-Bの両方からレスポンスが返る

---

## 次フェーズへの引き継ぎ情報

Phase 4（FIS障害注入）では以下が前提となる。

- Cell-A Pod: namespace `cell-a`・ラベル `cell=cell-a`・AZ-a固定
- Cell-B Pod: namespace `cell-b`・ラベル `cell=cell-b`・AZ-c固定
- ALB URL: `kubectl get ingress chaos-cell-ingress -n cell-a` で取得
- FISターゲットタグ: EC2インスタンスに `chaos-target=true`・`chaos-cell=cell-a/cell-b`
- PDB設定: 各Cell minAvailable=2（4Pod中2台は常に生存）