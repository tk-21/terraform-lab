# ✅Phase 5: 観測基盤（AMP・AMG・Container Insights）

## Phase 1-4 完了サマリー

- EKSクラスター・Karpenter（cell-a/cell-b NodePool）稼働中
- Cell-A/B ワークロード デプロイ済み・PDB設定済み
- FIS実験テンプレート3種類作成済み（AZ障害・CPUストレス・ネットワーク遅延）
- Stop Conditionアラーム設定済み

---

## このフェーズの目的

FIS実験の結果をリアルタイムで可視化できる観測基盤を構築する。

**計測したい指標**:
- Pod数の変化（AZ障害後のKarpenter再作成）
- ALBレスポンスタイム・エラー率（Cell間の影響確認）
- ノードのCPU/Memory使用率（ストレス実験）
- MTTR（Mean Time To Recovery）

---

## 作成対象ファイル

### 1. terraform/modules/observability/main.tf

```hcl
# =============================================================
# 観測基盤モジュール
# Amazon Managed Prometheus（AMP）+ Amazon Managed Grafana（AMG）
# + CloudWatch Container Insights
#
# 設計:
# - AMP: Prometheusメトリクスの長期保存
# - AMG: Grafanaダッシュボード（マネージドで運用負荷ゼロ）
# - ADOT: EKS上のOpenTelemetryコレクター（AMP送信役）
# =============================================================

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

# --- Amazon Managed Prometheus ワークスペース ---
resource "aws_prometheus_workspace" "main" {
  alias = "${var.cluster_name}-prometheus"

  logging_configuration {
    log_group_arn = "${aws_cloudwatch_log_group.amp.arn}:*"
  }

  tags = var.common_tags
}

resource "aws_cloudwatch_log_group" "amp" {
  name              = "/aws/prometheus/${var.cluster_name}"
  retention_in_days = 30
  tags              = var.common_tags
}

# --- Amazon Managed Grafana ワークスペース ---
resource "aws_grafana_workspace" "main" {
  name                     = "${var.cluster_name}-grafana"
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["AWS_SSO"]  # AWS SSOでログイン
  permission_type          = "SERVICE_MANAGED"
  role_arn                 = aws_iam_role.grafana.arn

  data_sources = ["PROMETHEUS", "CLOUDWATCH", "XRAY"]

  tags = var.common_tags
}

# --- Grafana IAMロール ---
resource "aws_iam_role" "grafana" {
  name = "${var.cluster_name}-grafana-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "grafana.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "grafana" {
  name = "${var.cluster_name}-grafana-policy"
  role = aws_iam_role.grafana.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # AMP クエリ権限
      {
        Effect = "Allow"
        Action = [
          "aps:QueryMetrics",
          "aps:GetSeries",
          "aps:GetLabels",
          "aps:GetMetricMetadata",
          "aps:ListWorkspaces",
          "aps:DescribeWorkspace"
        ]
        Resource = aws_prometheus_workspace.main.arn
      },
      # CloudWatch 読み取り（Container Insights）
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricData",
          "cloudwatch:ListMetrics",
          "cloudwatch:DescribeAlarms",
          "logs:DescribeLogGroups",
          "logs:GetLogGroupFields",
          "logs:StartQuery",
          "logs:GetQueryResults"
        ]
        Resource = "*"
      },
      # X-Ray 読み取り
      {
        Effect = "Allow"
        Action = [
          "xray:GetTraceSummaries",
          "xray:GetGroups",
          "xray:GetGroup",
          "xray:GetTimeSeriesServiceStatistics"
        ]
        Resource = "*"
      }
    ]
  })
}

# --- ADOT（AWS Distro for OpenTelemetry）IRSA ---
# EKSクラスター上のADOTコレクターがAMPにメトリクスを送信するためのIAMロール
resource "aws_iam_role" "adot" {
  name = "${var.cluster_name}-adot-collector"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_issuer}:sub" : "system:serviceaccount:amazon-metrics:adot-collector"
          "${var.oidc_issuer}:aud" : "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "adot_amp" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonPrometheusRemoteWriteAccess"
  role       = aws_iam_role.adot.name
}

# Container Insights 用のCloudWatch Logsグループ
resource "aws_cloudwatch_log_group" "container_insights" {
  name              = "/aws/containerinsights/${var.cluster_name}/performance"
  retention_in_days = 30
  tags              = var.common_tags
}
```

### 2. terraform/modules/observability/variables.tf

```hcl
variable "cluster_name" { type = string }
variable "aws_region" { type = string; default = "ap-northeast-1" }
variable "oidc_provider_arn" { type = string }
variable "oidc_issuer" { type = string }
variable "common_tags" { type = map(string); default = {} }
```

### 3. terraform/modules/observability/outputs.tf

```hcl
output "amp_workspace_id" { value = aws_prometheus_workspace.main.id }
output "amp_remote_write_url" {
  value = "${aws_prometheus_workspace.main.prometheus_endpoint}api/v1/remote_write"
}
output "grafana_workspace_id" { value = aws_grafana_workspace.main.id }
output "grafana_endpoint" { value = aws_grafana_workspace.main.endpoint }
output "adot_role_arn" { value = aws_iam_role.adot.arn }
```

---

### 4. ADOTコレクター（Kubernetes マニフェスト）

#### `k8s/monitoring/adot-collector.yaml`

```yaml
# =============================================================
# ADOT（AWS Distro for OpenTelemetry）コレクター
# EKS上のPrometheusメトリクスをスクレイプしてAMPに送信する
#
# 収集対象:
# - Karpenter メトリクス（ノード起動時間・中断数）
# - Node メトリクス（CPU・Memory・Network）
# - Pod メトリクス（cell-a・cell-b の区別）
# - ALB メトリクス（レスポンスタイム・エラー率）
# =============================================================
apiVersion: v1
kind: Namespace
metadata:
  name: amazon-metrics

---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: adot-collector
  namespace: amazon-metrics
  annotations:
    # IRSA: このServiceAccountがADOT IAMロールを使う
    eks.amazonaws.com/role-arn: ADOT_ROLE_ARN  # Terraform outputで置換

---
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: adot-collector
  namespace: amazon-metrics
spec:
  serviceAccount: adot-collector
  # システムノードで動作させる（Karpenter管理外）
  nodeSelector:
    node.kubernetes.io/purpose: system

  config: |
    receivers:
      prometheus:
        config:
          global:
            scrape_interval: 15s
            external_labels:
              cluster: eks-chaos-cell-prod
              region: ap-northeast-1

          scrape_configs:
            # Karpenterメトリクス（最重要: ノード起動時間を計測）
            - job_name: 'karpenter'
              static_configs:
                - targets: ['karpenter.karpenter:8000']
              metric_relabel_configs:
                - source_labels: [__name__]
                  regex: 'karpenter_(nodes_|pods_|cloudprovider_).*'
                  action: keep

            # ノードメトリクス
            - job_name: 'node-exporter'
              kubernetes_sd_configs:
                - role: node
              relabel_configs:
                - action: labelmap
                  regex: __meta_kubernetes_node_label_(.+)
                - source_labels: [__meta_kubernetes_node_label_cell]
                  target_label: cell

            # Podメトリクス（Cell別に区別）
            - job_name: 'kubernetes-pods'
              kubernetes_sd_configs:
                - role: pod
              relabel_configs:
                - source_labels: [__meta_kubernetes_pod_label_cell]
                  target_label: cell
                - source_labels: [__meta_kubernetes_namespace]
                  target_label: namespace
                - source_labels: [__meta_kubernetes_pod_name]
                  target_label: pod

    exporters:
      prometheusremotewrite:
        endpoint: AMP_REMOTE_WRITE_URL  # Terraform outputで置換
        auth:
          authenticator: sigv4auth

    extensions:
      sigv4auth:
        region: ap-northeast-1
        service: aps

    service:
      extensions: [sigv4auth]
      pipelines:
        metrics:
          receivers: [prometheus]
          exporters: [prometheusremotewrite]
```

---

### 5. Grafanaダッシュボード設定

#### `k8s/monitoring/grafana-dashboard-configmap.yaml`

```yaml
# Chaos Cell ダッシュボード定義（JSON）
# AMGのダッシュボードとしてインポートする
apiVersion: v1
kind: ConfigMap
metadata:
  name: chaos-cell-dashboard
  namespace: amazon-metrics
data:
  dashboard.json: |
    {
      "title": "EKS Chaos Cell Dashboard",
      "uid": "eks-chaos-cell",
      "panels": [
        {
          "title": "Cell-A Pod数（AZ障害で減少→回復を観測）",
          "type": "stat",
          "targets": [{
            "expr": "count(kube_pod_info{namespace=\"cell-a\",pod=~\"app-.*\"})",
            "legendFormat": "Cell-A Running Pods"
          }],
          "gridPos": {"h": 4, "w": 6, "x": 0, "y": 0}
        },
        {
          "title": "Cell-B Pod数（障害時も変化しないことを確認）",
          "type": "stat",
          "targets": [{
            "expr": "count(kube_pod_info{namespace=\"cell-b\",pod=~\"app-.*\"})",
            "legendFormat": "Cell-B Running Pods"
          }],
          "gridPos": {"h": 4, "w": 6, "x": 6, "y": 0}
        },
        {
          "title": "Karpenter ノード起動数（Cell別）",
          "type": "timeseries",
          "targets": [
            {
              "expr": "sum(karpenter_nodes_created_total) by (nodepool)",
              "legendFormat": "{{nodepool}} nodes created"
            }
          ],
          "gridPos": {"h": 8, "w": 12, "x": 0, "y": 4}
        },
        {
          "title": "ALB レスポンスタイム（ms）",
          "type": "timeseries",
          "targets": [{
            "expr": "aws_applicationelb_target_response_time_average",
            "legendFormat": "ALB Response Time"
          }],
          "gridPos": {"h": 8, "w": 12, "x": 12, "y": 4}
        },
        {
          "title": "ALB 5xxエラー数（Stop Conditionとの関係）",
          "type": "timeseries",
          "targets": [{
            "expr": "aws_applicationelb_httpcode_target_5_xx_count_sum",
            "legendFormat": "5xx errors"
          }],
          "gridPos": {"h": 8, "w": 12, "x": 0, "y": 12}
        }
      ]
    }
```

---

### 6. Container Insights 有効化スクリプト

#### `scripts/enable_container_insights.sh`

```bash
#!/usr/bin/env bash
# =============================================================
# CloudWatch Container Insights 有効化
# FluentBit + CloudWatch Agent を EKS にインストールする
# =============================================================
set -euo pipefail

CLUSTER_NAME="${1:-eks-chaos-cell-prod}"
REGION="ap-northeast-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "📊 Container Insights 有効化: ${CLUSTER_NAME}"

# CloudWatch Agent と FluentBit をインストール
aws eks create-addon \
  --cluster-name "${CLUSTER_NAME}" \
  --addon-name amazon-cloudwatch-observability \
  --region "${REGION}" \
  --service-account-role-arn "arn:aws:iam::${ACCOUNT_ID}:role/${CLUSTER_NAME}-node-role" \
  2>/dev/null || echo "アドオンは既にインストール済みです"

# インストール確認
aws eks describe-addon \
  --cluster-name "${CLUSTER_NAME}" \
  --addon-name amazon-cloudwatch-observability \
  --region "${REGION}" \
  --query "addon.status"

echo "✅ Container Insights 有効化完了"
echo ""
echo "CloudWatch Logs確認:"
echo "  aws logs describe-log-groups --log-group-name-prefix /aws/containerinsights/${CLUSTER_NAME}"
```

---

### 7. terraform/main.tf に observability モジュールを追記

```hcl
module "observability" {
  source            = "./modules/observability"
  cluster_name      = local.cluster_name
  aws_region        = var.aws_region
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_issuer       = replace(module.eks.cluster_oidc_issuer, "https://", "")
  common_tags       = local.common_tags
}
```

---

### 8. 観測スタックセットアップスクリプト

#### `scripts/setup_observability.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${1:-eks-chaos-cell-prod}"
REGION="ap-northeast-1"

echo "📊 観測基盤セットアップ開始"

# 1. Container Insights 有効化
./scripts/enable_container_insights.sh "${CLUSTER_NAME}"

# 2. ADOT Operator インストール（EKSアドオン）
aws eks create-addon \
  --cluster-name "${CLUSTER_NAME}" \
  --addon-name adot \
  --region "${REGION}" \
  2>/dev/null || echo "ADOTアドオンは既にインストール済み"

# 3. AMPのエンドポイントを取得してADOT設定に反映
AMP_ID=$(cd terraform && terraform output -raw amp_workspace_id)
AMP_URL=$(cd terraform && terraform output -raw amp_remote_write_url)
ADOT_ROLE=$(cd terraform && terraform output -raw adot_role_arn)

# ADOT マニフェストのプレースホルダーを実際の値に置換
sed -i "s|ADOT_ROLE_ARN|${ADOT_ROLE}|g" k8s/monitoring/adot-collector.yaml
sed -i "s|AMP_REMOTE_WRITE_URL|${AMP_URL}|g" k8s/monitoring/adot-collector.yaml

# 4. ADOT コレクターをデプロイ
kubectl apply -f k8s/monitoring/adot-collector.yaml

# 5. ADOT起動確認
echo "⏳ ADOT起動待機..."
kubectl rollout status deployment/adot-collector-collector \
  -n amazon-metrics --timeout=300s 2>/dev/null || true

echo ""
echo "✅ 観測基盤セットアップ完了"
echo ""
echo "Grafana URL:"
cd terraform && terraform output -raw grafana_endpoint
echo ""
echo "次のステップ:"
echo "  1. Grafanaにログイン（AWS SSO）"
echo "  2. Data Source: AMPワークスペースを追加"
echo "  3. ダッシュボード: k8s/monitoring/grafana-dashboard-configmap.yaml をインポート"
```

---

## 実行手順

```bash
# 1. terraform apply（AMP・AMG・ADOT IAMロール）
cd terraform
terraform apply -var="aws_account_id=YOUR_ACCOUNT_ID" -var="owner=YOUR_NAME"

# 2. Container Insights + ADOT セットアップ
cd ..
chmod +x scripts/setup_observability.sh scripts/enable_container_insights.sh
./scripts/setup_observability.sh

# 3. Grafanaにログインしてダッシュボードを確認
# terraform output grafana_endpoint でURLを確認

# 4. FIS実験を実行しながらGrafanaで確認
./fis/run_experiment.sh az-outage
# → GrafanaでCell-A Pod数が0→4に回復する様子をリアルタイム確認
```

---

## 完了確認チェックリスト

- [ ] `aws prometheus describe-workspace` でAMPワークスペースが `ACTIVE`
- [ ] AMGのエンドポイントURLにアクセスできる
- [ ] `kubectl get pods -n amazon-metrics` でADOTコレクターが `Running`
- [ ] GrafanaのData SourceにAMPが登録されている
- [ ] Grafanaダッシュボードで Cell-A/B の Pod数が表示される
- [ ] FIS実験中にGrafanaでリアルタイムの数値変化が確認できる

---

## 次フェーズへの引き継ぎ情報

Phase 6（ADR・README・実験結果まとめ）では以下が前提となる。

- AMP/AMGでリアルタイム観測が可能な状態
- FIS実験3種類を1回以上実行し、`results/` に実測値が記録されている
- `results/experiment-results.md` に面接で使える数値が入力されている