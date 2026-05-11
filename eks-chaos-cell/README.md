# eks-chaos-cell

> **Cell-Based EKS × AWS FIS カオスエンジニアリング基盤**
> AWSが大規模サービスで採用するCell Architectureを実装し、
> FISで意図的に障害を注入して自己回復を実測する

[![Terraform](https://img.shields.io/badge/Terraform-1.9+-623CE4?logo=terraform)](https://terraform.io)
[![EKS](https://img.shields.io/badge/EKS-1.31-FF9900?logo=amazon-aws)](https://aws.amazon.com/eks/)
[![Karpenter](https://img.shields.io/badge/Karpenter-v1.0-blue)](https://karpenter.sh)

---

## このハンズオンで得られること

### 技術スキル

| スキル | 具体的な内容 |
|--------|------------|
| **Cell Architecture** | AZ単位でNamespace・NodePool・Target Groupを独立させる設計を自分の手で実装する |
| **Karpenter実践** | EC2NodeClassとNodePoolをCell単位で構成し、AZ固定・Spot混在・Graviton優先を設定する |
| **FIS安全設計** | Stop Condition・タグ絞り込み・時間制限の3層安全機構を自分で考えて実装する |
| **IRSA** | Karpenter・ALB Controller・ADOTそれぞれにPod単位のIAMロールを割り当てる |
| **GitOps基盤** | GitHub ActionsのOIDC認証でアクセスキーなしのCI/CDを構築する |
| **マネージド観測基盤** | AMP・AMGをEKSと独立したサービスとして構成し、障害中でも観測できる仕組みを作る |

### 実測できる数値（面接で「設計しました」ではなく「測定しました」と言える）

```
AZ障害注入 → Karpenterが別ノードを起動するまでの時間   → 実測: TBD秒
新規ノード起動 → Podが全台Ready になるまでの時間       → 実測: TBD秒
Cell-AのAZ全断中のCell-Bエラー率                      → 実測: TBD%
ALBヘルスチェック切り替え時間                          → 実測: TBD秒
```

### 設計判断の言語化（ADRとして残る）

- なぜAZ分散ではなくCell Architectureを選んだのか
- なぜCluster AutoscalerではなくKarpenterを選んだのか
- カオス実験で本番影響を出さないために何を設計したのか

---

## 何を実証するか

```
仮説: Cell-AのAZが丸ごと落ちても、Cell-Bへの影響はゼロである

実験:
  AWS FISでCell-AのEC2インスタンスを全停止
  → Karpenterが新規ノードを自動起動
  → Grafanaで回復時間をリアルタイム計測

結果:
  Cell-B エラー率: TBD%（実測値）
  Karpenter ノード起動: TBD秒（実測値）
  Pod完全回復: TBD秒（実測値）
```

---

## アーキテクチャ

```
┌─────────────────────────────────────────┐
│           Route 53 / ALB                │
└──────────┬──────────────────┬───────────┘
           │                  │
    ┌──────▼──────┐    ┌──────▼──────┐
    │   Cell-A    │    │   Cell-B    │
    │  (AZ: 1a)   │    │  (AZ: 1c)   │
    │             │    │             │
    │ NodePool-A  │    │ NodePool-B  │
    │ 4 Pods      │    │ 4 Pods      │
    │ PDB: min 2  │    │ PDB: min 2  │
    └──────────────┘    └─────────────┘
           │
    ┌──────▼──────────────────────────┐
    │  AWS Fault Injection Service     │
    │  ├─ AZ障害（EC2停止）           │
    │  ├─ CPUストレス                 │
    │  └─ ネットワーク遅延注入        │
    └─────────────────────────────────┘
           │
    ┌──────▼──────────────────────────┐
    │  観測スタック                    │
    │  Amazon Managed Prometheus       │
    │  Amazon Managed Grafana          │
    │  CloudWatch Container Insights   │
    └─────────────────────────────────┘
```

詳細は [ARCHITECTURE.md](ARCHITECTURE.md) を参照。

---

## 実測結果

| 指標 | 目標 | 実測値 |
|------|------|--------|
| Cell-B エラー率（AZ障害中） | 0% | **TBD%** |
| Karpenter 新規ノード起動 | < 180秒 | **TBDsec** |
| Pod 完全回復 | < 90秒 | **TBDsec** |
| ALB 切り替え | < 60秒 | **TBDsec** |

---

## 技術スタック

| カテゴリ | 技術 | ポイント |
|----------|------|----------|
| コンテナ基盤 | Amazon EKS 1.31 | Managed Control Plane |
| ノード管理 | Karpenter v1.0 | AZ固定NodePool・Spot混在 |
| 障害注入 | AWS FIS | 3種類の実験テンプレート |
| 観測 | AMP + AMG | マネージドPrometheus/Grafana |
| IaC | Terraform（モジュール構成） | 全リソースコード管理 |
| CI/CD | GitHub Actions（OIDC） | アクセスキー不使用 |

---

## ハンズオン実行手順

### 前提条件

**ローカルツール（バージョン確認コマンド付き）**

```bash
aws --version          # AWS CLI v2 以上
terraform --version    # 1.9 以上
kubectl version --client  # 1.28 以上
helm version           # 3.14 以上
```

**AWSアカウント要件**

- IAM ユーザーまたはロールで以下の権限を持っていること
  - EKS・EC2・VPC・IAM・S3・DynamoDB の作成権限
  - FIS・CloudWatch・AMP・AMG の作成権限
- AWS CLIのプロファイルが設定済みであること

```bash
# 認証確認
aws sts get-caller-identity
```

---

### Step 0: リポジトリのクローンと変数の設定

```bash
git clone <this-repo>
cd eks-chaos-cell
```

`terraform/terraform.tfvars` を作成する（`.example` をコピーして編集）:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

```hcl
# terraform/terraform.tfvars
aws_account_id = "123456789012"   # 自分のAWSアカウントID
owner          = "your-name"      # リソースのOwnerタグ値
```

AWSアカウントIDの確認方法:

```bash
aws sts get-caller-identity --query Account --output text
```

---

### Step 1: Backend のデプロイ（S3 / DynamoDB / GitHub OIDC）

Terraformのtfstateを保管するS3バケットと、同時実行を防ぐDynamoDBロックテーブルを作成する。
**このステップだけはローカルにtfstateを置いて実行する（鶏と卵の問題）。**

```bash
cd terraform/backend

# 変数を設定して apply（ここは手動で行う唯一のステップ）
terraform init
terraform apply \
  -var="aws_account_id=$(aws sts get-caller-identity --query Account --output text)" \
  -var="owner=your-name"
```

成功すると以下が作成される:

```
S3バケット:    eks-chaos-cell-tfstate-{aws_account_id}
DynamoDBテーブル: eks-chaos-cell-tfstate-lock
IAMロール:     ecc-gha-role  (GitHub Actions OIDC用)
```

`cd ../..` でプロジェクトルートに戻る。

---

### Step 2: EKS・全インフラのデプロイ

VPC・EKSクラスター・Karpenter・FIS・観測基盤を一括でデプロイする。
**所要時間: 約15〜20分**

```bash
cd terraform

terraform init
terraform plan -var-file="terraform.tfvars"
```

planの内容を確認したら apply を実行（CLAUDE.mdポリシーによりこの手順はユーザーが実行する）:

```bash
terraform apply -var-file="terraform.tfvars"
```

apply 完了後、重要な出力値を確認する:

```bash
terraform output
```

以下の値が出力されることを確認する:

```
cluster_name          = "eks-chaos-cell-prod"
cluster_endpoint      = "https://XXXX.gr7.ap-northeast-1.eks.amazonaws.com"
amp_remote_write_url  = "https://aps-workspaces.ap-northeast-1.amazonaws.com/..."
amp_query_endpoint    = "https://aps-workspaces.ap-northeast-1.amazonaws.com/..."
grafana_endpoint      = "https://XXXX.grafana-workspace.ap-northeast-1.amazonaws.com"
adot_role_arn         = "arn:aws:iam::123456789012:role/eks-chaos-cell-prod-adot-collector"
```

`cd ..` でプロジェクトルートに戻る。

---

### Step 3: EKS初期セットアップ

kubeconfigの設定とALB Controllerのインストールを行う。

```bash
./scripts/bootstrap.sh
```

スクリプトが実行すること:
1. `aws eks update-kubeconfig` でkubeconfigを設定
2. EKSアドオン（CoreDNS・kube-proxy・VPC CNI）の存在確認
3. ALB Controller用のHelmリポジトリ追加

完了後、ノードが2台（システムノード）表示されることを確認:

```bash
kubectl get nodes -o wide
```

期待する出力:

```
NAME                                          STATUS   ROLES    AGE   VERSION   ZONE
ip-10-0-10-xxx.ap-northeast-1.compute.internal   Ready    <none>   3m    v1.31.x   ap-northeast-1a
ip-10-0-10-yyy.ap-northeast-1.compute.internal   Ready    <none>   3m    v1.31.x   ap-northeast-1a
```

---

### Step 4: Karpenter の動作確認

Karpenterコントローラーが正常に起動しており、Cell-A・Cell-Bそれぞれの
NodePoolとEC2NodeClassが作成されていることを確認する。

```bash
./scripts/verify_karpenter.sh
```

スクリプトが実行すること:
1. Karpenter Pod の稼働確認
2. EC2NodeClass（`cell-a`・`cell-b`）の確認
3. NodePool（`cell-a`・`cell-b`）の確認
4. Cell-A 向けのテストPodを起動してKarpenterがAZ-a にEC2を起動することを確認

期待する出力（抜粋）:

```
NAME          CLASS    NODES   READY   AGE
cell-a        cell-a   0       True    5m
cell-b        cell-b   0       True    5m
```

テストPodが Ready になるまでの時間を確認する。これが後の実験のベースラインになる。

```bash
# ノードのAZ確認（topology.kubernetes.io/zone が ap-northeast-1a であることを確認）
kubectl get nodes --label-columns=cell,topology.kubernetes.io/zone
```

---

### Step 5: ワークロードのデプロイ

Cell-A（AZ-a）とCell-B（AZ-c）にアプリケーションをデプロイする。

```bash
./scripts/deploy_workloads.sh
```

スクリプトが実行すること:
1. `cell-a` / `cell-b` Namespace の作成
2. 各Cell に Deployment（replica=4）・Service・PDB をデプロイ
3. ALB Ingress の作成
4. Pod起動完了を待機（タイムアウト300秒）

完了後の確認:

```bash
# Pod確認（各Cell 4台ずつ Running になっていること）
kubectl get pods -n cell-a -o wide
kubectl get pods -n cell-b -o wide

# PDB確認（ALLOWED DISRUPTIONS が 2 であること）
kubectl get pdb -A

# ノード確認（cell-a/cell-b ラベルのノードが起動していること）
kubectl get nodes --label-columns=cell,topology.kubernetes.io/zone
```

期待する出力:

```
# kubectl get pods -n cell-a -o wide
NAME                   READY   STATUS    NODE                    ...   ZONE
app-7d6f4b9-xxxx       1/1     Running   ip-10-0-10-aaa...            ap-northeast-1a
app-7d6f4b9-yyyy       1/1     Running   ip-10-0-10-bbb...            ap-northeast-1a
app-7d6f4b9-zzzz       1/1     Running   ip-10-0-10-ccc...            ap-northeast-1a
app-7d6f4b9-wwww       1/1     Running   ip-10-0-10-ddd...            ap-northeast-1a

# kubectl get pdb -A
NAMESPACE   NAME      MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS
cell-a      app-pdb   2               N/A               2
cell-b      app-pdb   2               N/A               2
```

**ALB URLを取得する（作成まで1〜3分かかる）:**

```bash
ALB_URL=$(kubectl get ingress chaos-cell-ingress -n cell-a \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "ALB URL: ${ALB_URL}"

# ヘルスチェック疎通確認
curl -I "http://${ALB_URL}/healthz"
```

`HTTP/1.1 200 OK` が返ってくれば準備完了。

---

### Step 6: 観測基盤のセットアップ

Container Insights・ADOT Collector・Amazon Managed Prometheusを接続する。

```bash
./scripts/setup_observability.sh
```

スクリプトが実行すること:
1. Container Insights を EKS クラスターで有効化
2. ADOT Operator を EKS アドオンとしてインストール
3. Terraform output から AMP URL・ADOT ロールARN を自動取得
4. ADOT Collector マニフェストを生成してデプロイ

完了後、GrafanaのURLが表示される:

```
============================================
Grafana URL:
https://XXXX.grafana-workspace.ap-northeast-1.amazonaws.com
============================================
```

**Grafana データソースの設定（手動）:**

1. 上記URLにブラウザでアクセスし、AWS SSO でログイン
2. 左メニュー → `Configuration` → `Data Sources` → `Add data source`
3. `Prometheus` を選択し、以下を設定:
   ```
   URL: <terraform output amp_query_endpoint の値>
   Authentication: SigV4
   Default Region: ap-northeast-1
   ```
4. `Save & Test` で接続確認

**ダッシュボードのインポート:**

```bash
# grafana-dashboard-configmap.yaml 内の dashboard.json を取り出す
kubectl get configmap grafana-dashboard -n amazon-metrics \
  -o jsonpath='{.data.dashboard\.json}' > /tmp/dashboard.json
```

Grafana → `Dashboards` → `Import` → `/tmp/dashboard.json` の内容を貼り付けてインポート。

**メトリクスが届いているか確認（Grafanaが開く前でも確認できる）:**

```bash
# AMPにメトリクスが到達しているか確認
aws aps query-metrics \
  --workspace-id $(cd terraform && terraform output -raw amp_workspace_id) \
  --query 'karpenter_nodes_total' \
  --region ap-northeast-1
```

---

### Step 7: FIS 実験の実行

**実験前に Grafana を開いておくこと。** リアルタイムでPod数・ノード数の変化が見える。

#### 実験1: AZ障害（メイン実験）

Cell-AのEC2インスタンスを全台停止し、Karpenterの自動回復とCell-Bへの影響を計測する。

```bash
./fis/run_experiment.sh az-outage
```

実験中のターミナル出力例:

```
==============================================
FIS実験開始: az-outage
開始時刻: 2026-05-11 14:30:00
==============================================

実験前スナップショット...
--- スナップショット: 実験前 ---
Cell-A Pod数: 4
Cell-B Pod数: 4

実験テンプレートID: EXT123XXXXXXX
実験を開始します...
実験ID: EXP456YYYYYYY

実験中モニタリング開始...

[10s]  Status:running    | ALB:200 | CellA:4Pod | CellB:4Pod
[20s]  Status:running    | ALB:200 | CellA:0Pod | CellB:4Pod  ← EC2停止・Pod消滅
[30s]  Status:running    | ALB:000 | CellA:0Pod | CellB:4Pod  ← ALBヘルスチェック失敗
[60s]  Status:running    | ALB:000 | CellA:0Pod | CellB:4Pod  ← Karpenter新規EC2起動中
[120s] Status:running    | ALB:200 | CellA:2Pod | CellB:4Pod  ← 新規ノードReady・Pod回復開始
[150s] Status:completed  | ALB:200 | CellA:4Pod | CellB:4Pod  ← 完全回復

実験完了: completed
```

実験後、結果ファイルが自動生成される:

```
結果を記録: results/experiment-20260511-143000.md
```

#### 実験2: CPUストレス（任意）

Cell-Aノードの50%にCPU負荷をかけてスロットリングの挙動を確認する。

```bash
./fis/run_experiment.sh cpu-stress
```

#### 実験3: ネットワーク遅延注入（任意）

Cell-Aノードに200ms+50msジッターの遅延を注入してタイムアウト動作を確認する。

```bash
./fis/run_experiment.sh network-latency
```

---

### Step 8: 実験結果の記録

実験後に以下を手動で計測し、`results/experiment-results.md` と `README.md` の実測値テーブルを更新する。

```bash
# CloudWatch Logsで実験の詳細ログを確認
aws logs tail /aws/fis/eks-chaos-cell-prod --follow --region ap-northeast-1

# Karpenterのログで起動時間を確認
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --since=1h | grep -E "launched|registered"

# 実験中のALBアクセスログ確認（S3に保存されている場合）
# Grafanaで以下のメトリクスを確認:
#   karpenter_nodes_total        (ノード台数の時系列)
#   karpenter_pods_startup_*     (Pod起動時間)
#   container_cpu_usage_seconds  (CPU使用率)
```

**記録すべき数値:**

| 指標 | 計測方法 | 記録先 |
|------|---------|--------|
| Karpenterノード起動時間 | Karpenterログのタイムスタンプ差分 | experiment-results.md |
| Pod完全回復時間 | モニタリングログの CellA:0Pod → 4Pod の経過秒数 | experiment-results.md |
| Cell-Bエラー率 | 実験中の ALB:000 が Cell-B に影響したか | experiment-results.md |
| ALB切り替え時間 | ALB:200 → 000 → 200 の経過秒数 | experiment-results.md |

---

### Step 9: クリーンアップ

**課金を止めるためにリソースを削除する。**

```bash
# ワークロード削除（Karpenterがノードをスケールダウンする）
kubectl delete namespace cell-a cell-b

# Karpenterが管理するノードが削除されるまで待機（数分）
kubectl get nodes --watch

# Terraform リソースの削除
cd terraform
terraform destroy -var-file="terraform.tfvars"
```

> Backend（S3・DynamoDB）は `prevent_destroy` が設定されているため、
> `terraform destroy` では削除されない。手動で削除する場合は AWS コンソールから。

---

## コスト試算

| リソース | 月額 |
|----------|------|
| EKS Control Plane | ~$73 |
| EC2（平時: t4g.medium × 4台） | ~$28 |
| NAT Gateway | ~$32 |
| AMP + AMG | ~$10 |
| FIS・ALB・その他 | ~$10 |
| **合計** | **~$153/月** |

> 実験時以外はKarpenterがノードを最小化するため、実際はこれより低い。
> 使わない時間帯は `kubectl scale deployment app --replicas=0 -n cell-a` でPodを0にするとKarpenterがノードを削除する。

---

## 設計ドキュメント

| ドキュメント | 内容 |
|------------|------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | システム全体の詳細アーキテクチャ・コンポーネント解説 |
| [ADR-001: Cell vs AZ分散](docs/adr/ADR-001-cell-vs-az.md) | なぜCell Architectureを選んだか |
| [ADR-002: Karpenter vs CAS](docs/adr/ADR-002-karpenter-vs-cas.md) | なぜKarpenterを選んだか |
| [ADR-003: FIS安全設計](docs/adr/ADR-003-fis-experiment-design.md) | カオス実験の安全機構の設計判断 |
| [面接想定Q&A](docs/runbook/interview-qa.md) | 技術面接での想定質問と回答例 |
| [実験結果記録](results/experiment-results.md) | FIS実験の実測値 |
