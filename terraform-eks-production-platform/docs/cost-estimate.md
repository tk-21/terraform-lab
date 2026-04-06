# コスト試算ドキュメント

## 月次コスト試算（東京リージョン ap-northeast-1）

> ⚠️ 以下は概算です。実際のコストは使用量・リージョン・データ転送量によって変わります。
> 最新の料金は [AWS Pricing Calculator](https://calculator.aws/pricing/2/home) で確認してください。

### インフラコスト内訳

| リソース | 構成 | 単価 | 月額概算 |
|---|---|---|---|
| **EKS クラスター** | コントロールプレーン × 1 | $0.10/時間 | **$73** |
| **EC2 (Managed Node Group)** | t3.medium × 2台（常駐） | $0.068/時間/台 | **$98** |
| **EC2 (Karpenter Spot)** | m5.large スポット想定 × 3台平均 | $0.03/時間/台（約70%割引） | **$65** |
| **NAT Gateway** | 2AZ × 1個 | $0.062/時間 + $0.062/GB | **$90** |
| **ALB** | × 1台 | $0.025/時間 + $0.008/LCU | **$20** |
| **EBS (gp3)** | 50GB × 5台 | $0.096/GB/月 | **$24** |
| **VPC Endpoint (Interface)** | 5エンドポイント × 2AZ | $0.014/時間/AZ | **$40** |
| **Amazon Managed Prometheus** | 1億サンプル/月想定 | $0.90/億サンプル | **$15** |
| **Amazon Managed Grafana** | エディター × 1名 | $9/ユーザー/月 | **$9** |
| **CloudWatch Logs** | 10GB/月想定 | $0.76/GB | **$8** |
| **Secrets Manager** | 10シークレット | $0.40/シークレット/月 | **$4** |
| **ECR** | 10GB ストレージ | $0.10/GB/月 | **$1** |
| **KMS** | 1キー | $1/月/キー + API呼び出し | **$2** |

**合計概算: 約 $449 / 月（約67,350円/月）**

---

### コスト削減 Tips

#### 1. スポットインスタンスの活用（最大効果）

Karpenterの設定でスポットインスタンスを優先させることで、アプリノードのEC2コストを最大70%削減できる。

```yaml
# kubernetes/karpenter/node-pool.yaml
requirements:
  - key: karpenter.sh/capacity-type
    operator: In
    values: ["spot", "on-demand"]  # spot を先に記載して優先
```

**削減効果**: EC2コスト $65 → $20（月間 $45 削減）

#### 2. NAT Gatewayの削減（検証時）

本番以外の環境では、NAT Gatewayを1つに削減できる。

```hcl
# terraform/environments/prod/main.tf
module "vpc" {
  enable_nat_gateway_per_az = false  # true → false に変更
}
```

**削減効果**: $90 → $45（月間 $45 削減）

#### 3. EKSコントロールプレーンの課金
EKSコントロールプレーンは $0.10/時間（$73/月）が常時発生する。
使用しない時間帯はクラスターを削除（terraform destroy）することで節約できる。

#### 4. Managed Node Groupのスケールダウン

夜間・週末は Managed Node Groupの desired_size を 0 に変更する。
```bash
aws eks update-nodegroup-config \
  --cluster-name terraform-eks-production-platform-prod-cluster \
  --nodegroup-name terraform-eks-production-platform-prod-ng-system \
  --scaling-config desiredSize=0
```

---

### `terraform destroy` の安全な実行手順

> ⚠️ `terraform destroy` を実行すると、すべてのリソースが削除されます。
> 以下の手順を必ず実施してから実行してください。

#### 1. 実行前の確認チェックリスト

```bash
# 1. 現在のリソース状態を確認
terraform state list

# 2. 重要なデータのバックアップ確認
# - ArgoCDの設定（Gitリポジトリに保存されていることを確認）
# - Secrets Managerの内容（必要であれば手動でメモ）
# - Prometheusメトリクス（AMPは削除すると過去データも消える）

# 3. 実行中のワークロードがないことを確認
kubectl get pods --all-namespaces | grep -v Completed | grep -v kube-system

# 4. plan でどのリソースが削除されるか確認
terraform plan -destroy
```

#### 2. Kubernetesリソースの事前削除

ArgoCDが管理するリソースは先に削除しないと、destroyが途中で止まる可能性がある。

```bash
# ArgoCD ApplicationのfinalizeをスキップしてApplicationを削除
kubectl patch app sample-app -n argocd \
  -p '{"metadata": {"finalizers": []}}' \
  --type merge
kubectl delete app sample-app -n argocd

# KarpenterのNodePoolを削除
kubectl delete nodepool default
kubectl delete ec2nodeclass default
```

#### 3. terraform destroy の実行

```bash
cd terraform/environments/prod

terraform destroy \
  -var="eks_public_access_cidrs=[\"$(curl -s ifconfig.me)/32\"]" \
  -var="grafana_admin_user=admin@example.com"
```

#### 4. 実行後の確認

```bash
# AWSコンソールで以下が削除されたことを確認
# - EKSクラスター
# - VPC（サブネット・IGW・NAT GW含む）
# - EC2インスタンス（Karpenterが起動したノードも含む）
# - ECR（イメージも削除される）

# 残留リソースの確認（Terraformで管理されていないリソースが残る可能性）
aws ec2 describe-vpcs --filters "Name=tag:Project,Values=terraform-eks-production-platform"
aws eks list-clusters
```

#### 5. S3ステートバケットとDynamoDBは手動削除

Terraformのバックエンド自体は `terraform destroy` で削除されない。
不要であれば手動で削除する。

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# DynamoDBテーブルの削除
aws dynamodb delete-table \
  --table-name terraform-eks-production-platform-prod-tfstate-lock

# S3バケットの削除（バージョニングされたオブジェクトも含めて削除）
aws s3 rm \
  s3://terraform-eks-production-platform-prod-tfstate-${AWS_ACCOUNT_ID} \
  --recursive
aws s3api delete-bucket \
  --bucket terraform-eks-production-platform-prod-tfstate-${AWS_ACCOUNT_ID}
```

---

### 学習用の最小構成（コスト最小化）

フルスタック構成から以下を省いた場合の概算コスト:

| 変更 | 月額削減 |
|---|---|
| NAT GW を 1つに削減 | -$45 |
| AMG を無効化 | -$9 |
| AMP を無効化（CWのみ使用） | -$15 |
| Karpenter をスポットオンリーに | -$20 |
| Node Group の desired を 1 に | -$49 |

**最小構成の概算: 約 $311/月（約46,650円/月）**

さらに費用を抑えたい場合は、使用しない時間帯に `terraform destroy` を実施することを強く推奨する。
