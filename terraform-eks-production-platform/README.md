# terraform-eks-production-platform

AWS 上に VPC を設計し、セキュアな EKS クラスターをゼロから構築するハンズオンプロジェクトです。  
ネットワーク設計、EKS、IRSA、Karpenter、ArgoCD、可観測性までを Terraform で一貫管理します。

この README は「読むだけの概要」ではなく、実際に手を動かして構築するための実行手順書として整理しています。

## このプロジェクトで作るもの

- 3 層 VPC: `Public / Private / Isolated`
- EKS 1.29 クラスター
- Managed Node Group + Karpenter
- AWS Load Balancer Controller
- ArgoCD による GitOps
- CloudWatch Container Insights
- Amazon Managed Prometheus
- Amazon Managed Grafana

アーキテクチャ全体の詳細は [`ARCHITECTURE.md`](/home/takuya/terraform-lab/terraform-eks-production-platform/ARCHITECTURE.md) を参照してください。

## 先に理解しておくこと

このプロジェクトは大きく 2 つのレイヤーに分かれます。

1. Terraform が AWS 基盤と EKS プラットフォームを作る
2. ArgoCD が `kubernetes/` 配下のマニフェストをクラスターへ同期する

つまり、最初の構築は Terraform が担当し、その後のアプリ変更は GitOps で流れる構成です。

## 前提条件

### 必要ツール

| ツール | 推奨バージョン |
|---|---|
| Terraform | `>= 1.7.0` |
| AWS CLI | `>= 2.0` |
| kubectl | `>= 1.29` |
| helm | `>= 3.14` |
| git | 最新安定版推奨 |
| python3 | venv 作成用 |

### インストール確認

```bash
terraform version
aws --version
kubectl version --client
helm version
python3 --version
```

### AWS 認証の前提

この README では、すでに次のどれかで AWS 認証済みである前提で進みます。

- `aws sso login`
- `aws configure`
- 既存の IAM ロール引き受け環境

認証確認:

```bash
aws sts get-caller-identity
```

アカウント ID が返ってくれば進めます。

## ハンズオン全体の流れ

この README の実行順は次の通りです。

1. リポジトリをクローンする
2. Python venv を作成する
3. ツールと AWS 認証を確認する
4. Terraform バックエンド用 S3 / DynamoDB を作成する
5. `terraform.tfvars` を作成する
6. `terraform init` を実行する
7. `terraform plan` で差分を確認する
8. `terraform apply` で環境を作成する
9. `kubectl` 接続とシステム Pod を確認する
10. ArgoCD / Karpenter / GitOps 動作を確認する
11. 必要なら `terraform destroy` で後片付けする

## 1. リポジトリを準備する

```bash
git clone <YOUR_REPOSITORY_URL>
cd terraform-eks-production-platform
```

プロジェクトルート確認:

```bash
pwd
ls
```

次のようなディレクトリが見えていれば OK です。

- `terraform/`
- `kubernetes/`
- `docs/`
- `README.md`

## 2. Python venv を作成する

このプロジェクトでは、作業前に必ず venv を使います。

```bash
python3 -m venv .venv
source .venv/bin/activate
which python
```

`which python` の結果が `.venv/bin/python` を指していることを確認してください。

`requirements.txt` は現時点では存在しないため、追加の `pip install -r requirements.txt` は不要です。

## 3. AWS リージョンと作業変数を決める

このプロジェクトのデフォルトリージョンは東京です。

```bash
export AWS_REGION=ap-northeast-1
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export PROJECT_NAME=terraform-eks-production-platform
export ENVIRONMENT=prod
```

確認:

```bash
echo $AWS_REGION
echo $AWS_ACCOUNT_ID
echo $PROJECT_NAME
echo $ENVIRONMENT
```

## 4. Terraform バックエンドを作成する

Terraform の state はこのプロジェクト自身では最初に作れないため、バックエンド用 S3 バケットと DynamoDB テーブルは最初だけ手動で作成します。

### 4.1 S3 バケットを作成する

```bash
aws s3api create-bucket \
  --bucket "${PROJECT_NAME}-${ENVIRONMENT}-tfstate-${AWS_ACCOUNT_ID}" \
  --region ${AWS_REGION} \
  --create-bucket-configuration LocationConstraint=${AWS_REGION}
```

### 4.2 バージョニングを有効化する

```bash
aws s3api put-bucket-versioning \
  --bucket "${PROJECT_NAME}-${ENVIRONMENT}-tfstate-${AWS_ACCOUNT_ID}" \
  --versioning-configuration Status=Enabled
```

### 4.3 暗号化を有効化する

```bash
aws s3api put-bucket-encryption \
  --bucket "${PROJECT_NAME}-${ENVIRONMENT}-tfstate-${AWS_ACCOUNT_ID}" \
  --server-side-encryption-configuration '{
    "Rules": [
      {
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "AES256"
        }
      }
    ]
  }'
```

### 4.4 パブリックアクセスをブロックする

```bash
aws s3api put-public-access-block \
  --bucket "${PROJECT_NAME}-${ENVIRONMENT}-tfstate-${AWS_ACCOUNT_ID}" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

### 4.5 DynamoDB テーブルを作成する

```bash
aws dynamodb create-table \
  --table-name "${PROJECT_NAME}-${ENVIRONMENT}-tfstate-lock" \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ${AWS_REGION}
```

### 4.6 作成確認

```bash
aws s3api head-bucket \
  --bucket "${PROJECT_NAME}-${ENVIRONMENT}-tfstate-${AWS_ACCOUNT_ID}"

aws dynamodb describe-table \
  --table-name "${PROJECT_NAME}-${ENVIRONMENT}-tfstate-lock" \
  --region ${AWS_REGION} \
  --query "Table.TableStatus"
```

## 5. GitHub Actions 用 IAM ロールを準備する

このリポジトリには GitHub Actions の `terraform plan` / `terraform apply` ワークフローが含まれています。  
そのため、将来的に CI/CD を使う場合は GitHub OIDC 用 IAM ロールが必要です。

ただし、最初のハンズオンでローカルから Terraform を実行するだけなら、ここは後回しでも構いません。

関連ファイル:

- [terraform-plan.yml](/home/takuya/terraform-lab/terraform-eks-production-platform/.github/workflows/terraform-plan.yml)
- [terraform-apply.yml](/home/takuya/terraform-lab/terraform-eks-production-platform/.github/workflows/terraform-apply.yml)

## 6. `terraform.tfvars` を作成する

まず環境ディレクトリへ移動します。

```bash
cd terraform/environments/prod
cp terraform.tfvars.example terraform.tfvars
```

### 6.1 現在のグローバル IP を確認する

EKS API サーバーの public endpoint は CIDR 制限する設計です。  
そのため、まず自分の現在 IP を確認します。

```bash
curl ifconfig.me
```

たとえば `203.0.113.10` が返った場合、`eks_public_access_cidrs` には `203.0.113.10/32` を設定します。

### 6.2 `terraform.tfvars` の記入例

```hcl
project_name = "terraform-eks-production-platform"
environment  = "prod"
aws_region   = "ap-northeast-1"

eks_public_access_cidrs = ["203.0.113.10/32"]

eks_cluster_version       = "1.29"
node_group_instance_types = ["t3.medium", "t3.large"]

karpenter_version = "0.35.0"
argocd_version    = "6.7.3"

grafana_admin_user = "your-sso-user@example.com"
```

### 6.3 この変数で特に重要な項目

- `eks_public_access_cidrs`
  - 自分の接続元 IP にする
  - `0.0.0.0/0` は使わない
- `grafana_admin_user`
  - AMG に入る管理者想定のメールアドレス
- `node_group_instance_types`
  - 最初の固定ノード群

### 6.4 よくあるミス

- 家や会社の回線で IP が変わり、後から `kubectl` がつながらなくなる
- `YOUR_IP_ADDRESS/32` のまま apply してしまう
- `grafana_admin_user` を未設定のまま plan する

## 7. backend のバケット名を確認する

このプロジェクトの [`backend.tf`](/home/takuya/terraform-lab/terraform-eks-production-platform/terraform/environments/prod/backend.tf) にはプレースホルダがあります。

```hcl
bucket = "terraform-eks-production-platform-prod-tfstate-REPLACE_WITH_ACCOUNT_ID"
```

ただし、実際の `terraform init` では `-backend-config` で正しいバケット名を渡すため、ファイルを直接書き換えなくても進められます。

## 8. Terraform を初期化する

作業ディレクトリが `terraform/environments/prod` であることを確認してから実行します。

```bash
pwd
```

初期化:

```bash
terraform init \
  -backend-config="bucket=${PROJECT_NAME}-${ENVIRONMENT}-tfstate-${AWS_ACCOUNT_ID}"
```

成功すると、AWS プロバイダーなどの初期化メッセージが表示されます。

### 8.1 初期化で失敗したときの確認ポイント

- `AWS_ACCOUNT_ID` が空でないか
- バケット名が作成したものと一致しているか
- S3 バケットと DynamoDB テーブルが同じリージョンにあるか
- AWS 認証が切れていないか

## 9. Terraform フォーマットと検証を行う

apply の前に、最低限これを通します。

```bash
terraform fmt -recursive
terraform validate
```

## 10. Terraform plan を実行する

最初の plan は時間がかかることがあります。

```bash
terraform plan
```

### 10.1 plan で見るべきポイント

- VPC が `10.0.0.0/16` で作られること
- Public / Private / Isolated の 6 サブネットが作られること
- EKS クラスターが `prod` 環境名つきで作られること
- Karpenter / LBC / ArgoCD / AMP / AMG が含まれていること
- destroy 差分が意図せず出ていないこと

### 10.2 IP を変えたあとに再 plan するケース

もし別のネットワークに移動した場合は `terraform.tfvars` の `eks_public_access_cidrs` を更新してから再度 `terraform plan` してください。

## 11. Terraform apply を実行する

ここから先は実際に AWS リソースが作成されます。  
EKS, NAT Gateway, AMG などを含むため、完了まである程度時間がかかります。

```bash
terraform apply
```

`yes` の入力を求められたら、内容を確認して実行してください。

### 11.1 apply 後に控えておく出力

apply が成功したら、次の値は後で使います。

- `cluster_name`
- `cluster_endpoint`
- `kubeconfig_command`
- `argocd_admin_secret_arn`
- `argocd_password_command`
- `grafana_workspace_endpoint`

必要なら再表示:

```bash
terraform output
```

## 12. kubeconfig を更新する

apply 完了後、まずローカルの `kubectl` をクラスターへ向けます。

```bash
aws eks update-kubeconfig \
  --region ${AWS_REGION} \
  --name ${PROJECT_NAME}-${ENVIRONMENT}-cluster
```

確認:

```bash
kubectl config current-context
kubectl get nodes -o wide
```

### 12.1 期待する状態

最初は Managed Node Group のノードが表示されます。  
Karpenter ノードは、追加ワークロードが入るまでまだ存在しないことがあります。

## 13. システムコンポーネントを確認する

### 13.1 kube-system

```bash
kubectl get pods -n kube-system
```

特に確認したいもの:

- `aws-load-balancer-controller`
- `coredns`
- `kube-proxy`

### 13.2 Karpenter

```bash
kubectl get pods -n karpenter
kubectl get nodepool
kubectl get ec2nodeclass
```

### 13.3 ArgoCD

```bash
kubectl get pods -n argocd
kubectl get applications -n argocd
```

### 13.4 Monitoring

```bash
kubectl get pods -n monitoring
kubectl get pods -n amazon-cloudwatch
```

## 14. ArgoCD にログインする

### 14.1 admin パスワードを取得する

Terraform output にコマンドが出ていますが、直接実行するなら次です。

```bash
aws secretsmanager get-secret-value \
  --secret-id "${PROJECT_NAME}/${ENVIRONMENT}/argocd-admin-password" \
  --query SecretString \
  --output text
```

### 14.2 port-forward する

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

ブラウザで次にアクセスします。

```text
https://localhost:8080
```

ログイン情報:

- Username: `admin`
- Password: 先ほど取得した値

## 15. GitOps が動いていることを確認する

ArgoCD は [`kubernetes/argocd/applications/sample-app.yaml`](/home/takuya/terraform-lab/terraform-eks-production-platform/kubernetes/argocd/applications/sample-app.yaml) を使って `sample-app` を同期する想定です。

確認:

```bash
kubectl get app -n argocd
kubectl get all -n sample-app
```

### 15.1 注意

このリポジトリの sample app マニフェストには、次のようなプレースホルダがあります。

- ECR の `REPLACE_ACCOUNT_ID`
- Ingress のドメイン
- ACM 証明書 ARN
- ArgoCD Application の GitHub リポジトリ URL

そのため、完全に動かすにはこれらを実環境の値へ置き換える必要があります。

関連ファイル:

- [deployment.yaml](/home/takuya/terraform-lab/terraform-eks-production-platform/kubernetes/sample-app/deployment.yaml)
- [service.yaml](/home/takuya/terraform-lab/terraform-eks-production-platform/kubernetes/sample-app/service.yaml)
- [sample-app.yaml](/home/takuya/terraform-lab/terraform-eks-production-platform/kubernetes/argocd/applications/sample-app.yaml)

## 16. Karpenter の挙動を確認する

Karpenter は追加の Pod がスケジュールできないときにノードを増やします。  
そのため、`sample-app` の HPA や追加ワークロードで Pending Pod を作ると挙動を確認しやすいです。

まず NodePool を確認:

```bash
kubectl get nodepool
kubectl describe nodepool default
```

ノードの増減確認:

```bash
kubectl get nodes -L node.kubernetes.io/instance-type,kubernetes.io/arch
```

## 17. Grafana と監視系を確認する

Terraform output に Grafana エンドポイントが出ます。

```bash
terraform output grafana_workspace_endpoint
terraform output amp_workspace_endpoint
```

Grafana は AWS SSO 前提のため、ワークスペース作成後に組織側ユーザー関連付けも確認してください。

## 18. よくある詰まりどころ

### `kubectl` が急につながらない

原因の多くは `eks_public_access_cidrs` と現在のグローバル IP の不一致です。  
`curl ifconfig.me` で確認し、`terraform.tfvars` を更新して再 apply してください。

### ArgoCD にログインできない

- `argocd-server` Pod が Ready か
- `argocd` Namespace が存在するか
- Secrets Manager から正しいパスワードを取得できているか

### sample-app が起動しない

プレースホルダ値のままの可能性があります。  
特に ECR イメージ URI、ドメイン、証明書 ARN を確認してください。

### Karpenter ノードが出てこない

- Pending Pod があるか
- `nodepool` / `ec2nodeclass` が存在するか
- Karpenter controller Pod が正常か
- Subnet / Security Group の discovery tag が一致しているか

## 19. コストについて

この構成は学習用最小構成ではなく、本番寄りです。  
NAT Gateway x2、EKS、AMG、AMP を含むため、月額コストは軽くありません。

詳細は [`docs/cost-estimate.md`](/home/takuya/terraform-lab/terraform-eks-production-platform/docs/cost-estimate.md) を参照してください。

特に次はコストに効きます。

- NAT Gateway x2
- EKS コントロールプレーン
- Managed Node Group
- Karpenter で起動する追加 EC2
- AMG / AMP

## 20. 後片付け

使い終わったら、課金を避けるために削除を検討してください。

まず Kubernetes 側で残りやすいものを確認します。

```bash
kubectl get app -n argocd
kubectl get nodepool
```

その後、Terraform 側の差分確認:

```bash
terraform plan -destroy
```

問題なければ削除:

```bash
terraform destroy
```

削除時の詳細な注意点は [`docs/cost-estimate.md`](/home/takuya/terraform-lab/terraform-eks-production-platform/docs/cost-estimate.md) の destroy 手順を参照してください。

## 21. 参考ドキュメント

- [ARCHITECTURE.md](/home/takuya/terraform-lab/terraform-eks-production-platform/ARCHITECTURE.md)
- [docs/architecture.md](/home/takuya/terraform-lab/terraform-eks-production-platform/docs/architecture.md)
- [docs/network-design.md](/home/takuya/terraform-lab/terraform-eks-production-platform/docs/network-design.md)
- [docs/cost-estimate.md](/home/takuya/terraform-lab/terraform-eks-production-platform/docs/cost-estimate.md)

## 22. 実行コマンドの最短まとめ

最短で流すなら次の順です。

```bash
git clone <YOUR_REPOSITORY_URL>
cd terraform-eks-production-platform

python3 -m venv .venv
source .venv/bin/activate

export AWS_REGION=ap-northeast-1
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export PROJECT_NAME=terraform-eks-production-platform
export ENVIRONMENT=prod

cd terraform/environments/prod
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars を編集

terraform init \
  -backend-config="bucket=${PROJECT_NAME}-${ENVIRONMENT}-tfstate-${AWS_ACCOUNT_ID}"

terraform fmt -recursive
terraform validate
terraform plan
terraform apply

aws eks update-kubeconfig \
  --region ${AWS_REGION} \
  --name ${PROJECT_NAME}-${ENVIRONMENT}-cluster

kubectl get nodes -o wide
kubectl get pods -n argocd
kubectl get pods -n karpenter
```
