# デプロイ手順 — Phase 1: AWS基盤構築

## 前提条件

- AWS CLI が設定済み（`aws sts get-caller-identity` が通ること）
- Terraform >= 1.7.0 がインストール済み
- `AWS_PROFILE` または `AWS_DEFAULT_REGION` が設定済み

## Step 1: バックエンドリソース作成

```bash
# Terraformリモートステート用S3バケット・DynamoDBテーブルを作成
bash scripts/bootstrap.sh
```

bootstrap.sh 実行後に表示される `sed` コマンドを実行して `backend.tf` のバケット名を置換する：

```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
sed -i "s/REPLACE_WITH_ACCOUNT_ID/${AWS_ACCOUNT_ID}/g" terraform/backend.tf
```

## Step 2: tfvars ファイル作成

```bash
cat > terraform/dev.tfvars << 'EOF'
project_name        = "istio-eks-service-mesh"
env                 = "dev"
aws_region          = "ap-northeast-1"
eks_cluster_version = "1.29"
node_instance_type  = "t3.medium"
node_desired_size   = 2
node_min_size       = 1
node_max_size       = 3
# 自分のIPアドレスに変更すること（curl ifconfig.me で確認）
allowed_cidr_blocks = ["YOUR_IP/32"]
report_bucket_lifecycle_days = 30
github_org          = "YOUR_GITHUB_ORG"
EOF
```

## Step 3: Terraform 初期化

```bash
cd terraform && terraform init
```

## Step 4: 差分確認

```bash
terraform plan -var-file=dev.tfvars
```

## Step 5: 適用（ユーザー自身が実行）

```bash
terraform apply -var-file=dev.tfvars
```

> **注意**: `terraform apply` は必ずユーザー自身が実行すること。

## Step 6: kubectl 設定

```bash
aws eks update-kubeconfig \
  --region ap-northeast-1 \
  --name $(terraform output -raw eks_cluster_name)
```

## Step 7: ノード確認

```bash
kubectl get nodes -o wide
```

2ノードが `Ready` 状態であることを確認する。

## Step 8: 全 outputs 確認

```bash
terraform output
```

## Phase 2 への引き継ぎ

```bash
export EKS_CLUSTER_NAME=$(cd terraform && terraform output -raw eks_cluster_name)
export REPORT_BUCKET=$(cd terraform && terraform output -raw report_bucket_name)
export AWS_REGION="ap-northeast-1"
```

## トラブルシューティング

### ノードが Ready にならない場合

```bash
# ノードのイベント確認
kubectl describe nodes

# aws-node DaemonSet の状態確認
kubectl get pods -n kube-system
```

### terraform init が失敗する場合

`backend.tf` のバケット名が正しいか確認する：

```bash
grep bucket terraform/backend.tf
aws s3 ls | grep istio-eks-tfstate
```
