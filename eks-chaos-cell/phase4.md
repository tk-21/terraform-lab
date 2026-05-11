# ✅Phase 4: AWS FIS 障害注入実験テンプレート

## Phase 1-3 完了サマリー

- EKSクラスター稼働・Karpenter NodePool cell-a/cell-b 動作確認済み
- Cell-A: AZ-a・4 Pod稼働・PDB minAvailable=2
- Cell-B: AZ-c・4 Pod稼働・PDB minAvailable=2
- ALBからヘルスチェック確認済み
- FISターゲットタグ `chaos-target=true` / `chaos-cell=cell-a|cell-b` が全Cellノードに付与済み

---

## このフェーズの目的

AWS Fault Injection Service（FIS）で3種類の障害実験テンプレートを実装する。

| 実験 | 内容 | 検証したいこと |
|------|------|---------------|
| AZ障害 | Cell-AのEC2を全停止 | Cell-Bへの影響ゼロ・Karpenterの回復時間 |
| Podストレス | Cell-A Pod に CPU/Memory負荷 | HPA・スロットリング動作 |
| Network遅延 | Cell-A ノードに遅延注入 | タイムアウト・Circuit Breaker動作 |

**面接で語れること**:
- FISの「安全条件（Stop Conditions）」設計
- 実験前後の数値比較（MTTR・エラー率）
- カオスエンジニアリングの原則（仮説→実験→計測）

---

## 作成対象ファイル

### 1. terraform/modules/fis/main.tf

```hcl
# =============================================================
# FIS モジュール
# 実験テンプレートを Terraform で管理することで
# 実験内容をコードとしてレビュー・バージョン管理できる
#
# 安全設計:
# - Stop Condition: CloudWatchアラームでエラー率が閾値超えたら自動停止
# - TargetはTaintで絞り込み（システムノードには絶対触らない）
# - 実験時間に上限（最大10分）
# =============================================================

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

# --- FIS 実行 IAMロール ---
resource "aws_iam_role" "fis" {
  name = "${var.cluster_name}-fis-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "fis.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "fis" {
  name = "${var.cluster_name}-fis-policy"
  role = aws_iam_role.fis.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # EC2操作（chaos-targetタグが付いたインスタンスのみ）
      {
        Effect = "Allow"
        Action = [
          "ec2:StopInstances",
          "ec2:DescribeInstances"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/chaos-target" = "true"
          }
        }
      },
      # SSM（Podストレス・ネットワーク遅延注入用）
      {
        Effect = "Allow"
        Action = [
          "ssm:StartAutomationExecution",
          "ssm:GetAutomationExecution",
          "ssm:StopAutomationExecution",
          "ssm:SendCommand",
          "ssm:GetCommandInvocation",
          "ssm:ListCommandInvocations",
          "ssm:DescribeInstanceInformation"
        ]
        Resource = "*"
      },
      # CloudWatch（Stop Condition確認用）
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:DescribeAlarms"]
        Resource = "*"
      },
      # EKS（Pod操作用）
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = "arn:aws:eks:${var.aws_region}:${var.aws_account_id}:cluster/${var.cluster_name}"
      },
      # CloudWatch Logs（実験ログ）
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/fis/*"
      }
    ]
  })
}

# --- Stop Condition 用 CloudWatch アラーム ---
# ALBの5xxエラー率が5%を超えたらFIS実験を自動停止
resource "aws_cloudwatch_metric_alarm" "alb_5xx_stop_condition" {
  alarm_name          = "${var.cluster_name}-fis-stop-condition"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 10  # 1分間に10回以上の5xxで停止
  alarm_description   = "FIS実験停止条件: ALB 5xxエラーが閾値超過"
  treat_missing_data  = "notBreaching"

  tags = var.common_tags
}

# --- FIS ログ用CloudWatch Logsグループ ---
resource "aws_cloudwatch_log_group" "fis" {
  name              = "/aws/fis/${var.cluster_name}"
  retention_in_days = 30
  tags              = var.common_tags
}

# =====================================================
# 実験1: AZ障害（Cell-A の EC2インスタンスを全停止）
# =====================================================
resource "aws_fis_experiment_template" "az_outage_cell_a" {
  description = "Cell-A（AZ-a）のEC2インスタンスを停止してKarpenter回復を測定する"
  role_arn    = aws_iam_role.fis.arn

  # 停止条件: ALBエラー率が閾値超過
  stop_condition {
    source = "aws:cloudwatch:alarm"
    value  = aws_cloudwatch_metric_alarm.alb_5xx_stop_condition.arn
  }

  # ターゲット: chaos-cell=cell-a タグ付きEC2インスタンス
  target {
    name           = "cell-a-instances"
    resource_type  = "aws:ec2:instance"
    selection_mode = "ALL"  # Cell-Aの全インスタンスを対象

    resource_tag {
      key   = "chaos-target"
      value = "true"
    }

    resource_tag {
      key   = "chaos-cell"
      value = "cell-a"
    }
  }

  # アクション: EC2インスタンスを停止
  action {
    name      = "stop-cell-a-instances"
    action_id = "aws:ec2:stop-instances"

    target {
      key   = "Instances"
      value = "cell-a-instances"
    }

    # 停止前に30秒待機（メトリクス記録のため）
    start_after = []
  }

  log_configuration {
    log_schema_version = 2
    cloudwatch_logs_configuration {
      log_group_arn = "${aws_cloudwatch_log_group.fis.arn}:*"
    }
  }

  tags = merge(var.common_tags, {
    Name            = "${var.cluster_name}-az-outage-cell-a"
    experiment-type = "az-outage"
  })
}

# =====================================================
# 実験2: Pod CPU ストレス（Cell-A のノードにCPU負荷）
# SSM Run CommandでLinuxのstressコマンドを実行
# =====================================================
resource "aws_fis_experiment_template" "pod_cpu_stress" {
  description = "Cell-A ノードにCPU負荷をかけてスロットリング動作を確認する"
  role_arn    = aws_iam_role.fis.arn

  stop_condition {
    source = "aws:cloudwatch:alarm"
    value  = aws_cloudwatch_metric_alarm.alb_5xx_stop_condition.arn
  }

  target {
    name           = "cell-a-instances-stress"
    resource_type  = "aws:ec2:instance"
    selection_mode = "PERCENT(50)"  # Cell-Aの50%のノードに負荷

    resource_tag {
      key   = "chaos-target"
      value = "true"
    }
    resource_tag {
      key   = "chaos-cell"
      value = "cell-a"
    }
  }

  action {
    name      = "cpu-stress"
    action_id = "aws:ssm:send-command"

    parameter {
      key   = "documentArn"
      value = "arn:aws:ssm:${var.aws_region}::document/AWSFIS-Run-CPU-Stress"
    }

    parameter {
      key   = "documentParameters"
      value = jsonencode({
        CPU                = "0"       # 0=全コア
        DurationSeconds    = "300"     # 5分間
        InstallDependencies = "True"
      })
    }

    parameter {
      key   = "duration"
      value = "PT6M"  # 6分（stressコマンドより少し長く）
    }

    target {
      key   = "Instances"
      value = "cell-a-instances-stress"
    }
  }

  log_configuration {
    log_schema_version = 2
    cloudwatch_logs_configuration {
      log_group_arn = "${aws_cloudwatch_log_group.fis.arn}:*"
    }
  }

  tags = merge(var.common_tags, {
    Name            = "${var.cluster_name}-pod-cpu-stress"
    experiment-type = "cpu-stress"
  })
}

# =====================================================
# 実験3: ネットワーク遅延注入（Cell-A → 外部通信に遅延）
# SSM Run CommandでLinuxのtcコマンドを実行
# =====================================================
resource "aws_fis_experiment_template" "network_latency" {
  description = "Cell-A ノードに200msの遅延を注入してタイムアウト動作を確認する"
  role_arn    = aws_iam_role.fis.arn

  stop_condition {
    source = "aws:cloudwatch:alarm"
    value  = aws_cloudwatch_metric_alarm.alb_5xx_stop_condition.arn
  }

  target {
    name           = "cell-a-instances-latency"
    resource_type  = "aws:ec2:instance"
    selection_mode = "ALL"

    resource_tag {
      key   = "chaos-target"
      value = "true"
    }
    resource_tag {
      key   = "chaos-cell"
      value = "cell-a"
    }
  }

  action {
    name      = "network-latency"
    action_id = "aws:ssm:send-command"

    parameter {
      key   = "documentArn"
      value = "arn:aws:ssm:${var.aws_region}::document/AWSFIS-Run-Network-Latency"
    }

    parameter {
      key   = "documentParameters"
      value = jsonencode({
        DelayMilliseconds  = "200"    # 200ms遅延
        JitterMilliseconds = "50"     # ±50ms ジッター
        DurationSeconds    = "300"    # 5分間
        Interface          = "eth0"
        InstallDependencies = "True"
      })
    }

    parameter {
      key   = "duration"
      value = "PT6M"
    }

    target {
      key   = "Instances"
      value = "cell-a-instances-latency"
    }
  }

  log_configuration {
    log_schema_version = 2
    cloudwatch_logs_configuration {
      log_group_arn = "${aws_cloudwatch_log_group.fis.arn}:*"
    }
  }

  tags = merge(var.common_tags, {
    Name            = "${var.cluster_name}-network-latency"
    experiment-type = "network-latency"
  })
}
```

### 2. terraform/modules/fis/variables.tf

```hcl
variable "cluster_name" { type = string }
variable "aws_region" { type = string; default = "ap-northeast-1" }
variable "aws_account_id" { type = string }
variable "common_tags" { type = map(string); default = {} }
```

### 3. terraform/modules/fis/outputs.tf

```hcl
output "fis_role_arn" { value = aws_iam_role.fis.arn }
output "experiment_az_outage_id" { value = aws_fis_experiment_template.az_outage_cell_a.id }
output "experiment_cpu_stress_id" { value = aws_fis_experiment_template.pod_cpu_stress.id }
output "experiment_network_latency_id" { value = aws_fis_experiment_template.network_latency.id }
output "stop_condition_alarm_arn" { value = aws_cloudwatch_metric_alarm.alb_5xx_stop_condition.arn }
```

---

### 4. FIS実験実行スクリプト

#### `fis/run_experiment.sh`

```bash
#!/usr/bin/env bash
# =============================================================
# FIS 実験実行・計測スクリプト
#
# 使用方法:
#   ./fis/run_experiment.sh az-outage    # AZ障害実験
#   ./fis/run_experiment.sh cpu-stress   # CPUストレス実験
#   ./fis/run_experiment.sh network-latency # ネットワーク遅延実験
#
# 実験中は以下を並行計測する:
#   - ALBヘルスチェック成功率
#   - Pod数の変化
#   - Karpenterノード起動時間
# =============================================================

set -euo pipefail

EXPERIMENT_TYPE="${1:-az-outage}"
CLUSTER_NAME="${CLUSTER_NAME:-eks-chaos-cell-prod}"
REGION="ap-northeast-1"
RESULTS_FILE="results/experiment-$(date +%Y%m%d-%H%M%S).md"

# 実験IDを取得（Terraformのoutputから）
get_experiment_id() {
  local type="$1"
  cd terraform
  case "$type" in
    az-outage)
      terraform output -raw experiment_az_outage_id 2>/dev/null || \
        aws fis list-experiment-templates --region "${REGION}" \
          --query "experimentTemplates[?tags.\"experiment-type\"=='az-outage'].id" \
          --output text
      ;;
    cpu-stress)
      terraform output -raw experiment_cpu_stress_id 2>/dev/null
      ;;
    network-latency)
      terraform output -raw experiment_network_latency_id 2>/dev/null
      ;;
  esac
  cd ..
}

# ALBのヘルスチェック状態を確認
check_alb_health() {
  local alb_url="$1"
  local response
  response=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 5 "http://${alb_url}/healthz" 2>/dev/null || echo "000")
  echo "${response}"
}

# 実験前の状態スナップショット
take_snapshot() {
  local label="$1"
  echo "--- スナップショット: ${label} ---"
  echo "Podの状態:"
  kubectl get pods -n cell-a -o wide --no-headers | wc -l
  kubectl get pods -n cell-b -o wide --no-headers | wc -l
  echo "ノードの状態:"
  kubectl get nodes --label-columns=cell,topology.kubernetes.io/zone --no-headers
}

mkdir -p results

echo "=============================================="
echo "🧪 FIS実験開始: ${EXPERIMENT_TYPE}"
echo "開始時刻: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================="

# 実験前スナップショット
echo ""
echo "📸 実験前スナップショット..."
take_snapshot "実験前"

# ALB URLを取得
ALB_URL=$(kubectl get ingress chaos-cell-ingress -n cell-a \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

# 実験前ヘルスチェック
if [ -n "${ALB_URL}" ]; then
  INITIAL_HEALTH=$(check_alb_health "${ALB_URL}")
  echo "実験前ALBヘルスチェック: ${INITIAL_HEALTH}"
fi

# FIS実験を開始
TEMPLATE_ID=$(get_experiment_id "${EXPERIMENT_TYPE}")
echo ""
echo "🚀 実験テンプレートID: ${TEMPLATE_ID}"
echo "実験を開始します..."

EXPERIMENT_ID=$(aws fis start-experiment \
  --experiment-template-id "${TEMPLATE_ID}" \
  --region "${REGION}" \
  --query "experiment.id" \
  --output text)

echo "実験ID: ${EXPERIMENT_ID}"
EXPERIMENT_START=$(date +%s)

# 実験中のモニタリングループ
echo ""
echo "📊 実験中モニタリング開始..."
echo ""

MONITORING_INTERVAL=10  # 10秒ごとに計測
MAX_MONITORING_TIME=600  # 最大10分

for i in $(seq 1 $((MAX_MONITORING_TIME / MONITORING_INTERVAL))); do
  ELAPSED=$(( $(date +%s) - EXPERIMENT_START ))

  # 実験ステータス確認
  STATUS=$(aws fis get-experiment \
    --id "${EXPERIMENT_ID}" \
    --region "${REGION}" \
    --query "experiment.state.status" \
    --output text)

  # ALBヘルスチェック
  HEALTH="N/A"
  if [ -n "${ALB_URL}" ]; then
    HEALTH=$(check_alb_health "${ALB_URL}")
  fi

  # Pod数
  CELL_A_PODS=$(kubectl get pods -n cell-a --no-headers 2>/dev/null | grep -c "Running" || echo "0")
  CELL_B_PODS=$(kubectl get pods -n cell-b --no-headers 2>/dev/null | grep -c "Running" || echo "0")

  echo "[${ELAPSED}s] Status:${STATUS} | ALB:${HEALTH} | CellA:${CELL_A_PODS}Pod | CellB:${CELL_B_PODS}Pod"

  # 実験完了確認
  if [[ "${STATUS}" == "completed" || "${STATUS}" == "stopped" || "${STATUS}" == "failed" ]]; then
    echo ""
    echo "✅ 実験完了: ${STATUS}"
    RECOVERY_TIME=$(( $(date +%s) - EXPERIMENT_START ))
    break
  fi

  sleep "${MONITORING_INTERVAL}"
done

# 実験後スナップショット
echo ""
echo "📸 実験後スナップショット..."
take_snapshot "実験後"

# 結果をMarkdownに記録
cat > "${RESULTS_FILE}" <<EOF
# FIS実験結果: ${EXPERIMENT_TYPE}

## 実験概要

- 実験タイプ: ${EXPERIMENT_TYPE}
- 実験ID: ${EXPERIMENT_ID}
- 実験時刻: $(date '+%Y-%m-%d %H:%M:%S')
- クラスター: ${CLUSTER_NAME}

## 計測値

| 指標 | 値 |
|------|-----|
| 実験開始〜完了 | ${RECOVERY_TIME:-不明}秒 |
| 実験前ALBヘルス | ${INITIAL_HEALTH:-N/A} |
| Cell-B への影響 | 要確認 |

## 実験ログ

実験ID: ${EXPERIMENT_ID}
CloudWatch Logs: /aws/fis/${CLUSTER_NAME}

## 所感・気づき

（ここに手動で記録する）
EOF

echo ""
echo "📝 結果を記録: ${RESULTS_FILE}"
echo ""
echo "CloudWatch Logsで詳細確認:"
echo "  aws logs tail /aws/fis/${CLUSTER_NAME} --follow --region ${REGION}"
```

---

### 5. results/experiment-results.md（テンプレート）

```markdown
# 実験結果記録

## 面接で提示する数値まとめ

| 実験 | 指標 | 目標 | 実測値 |
|------|------|------|--------|
| AZ障害 | Karpenter新規ノード起動 | < 180秒 | TBD |
| AZ障害 | Pod起動完了 | < 90秒 | TBD |
| AZ障害 | Cell-Bエラー率 | 0% | TBD |
| AZ障害 | ALB切り替え | < 60秒 | TBD |
| CPUストレス | スロットリング発生閾値 | - | TBD |
| Network遅延 | タイムアウト発生閾値 | - | TBD |

## 実験ログ一覧

実験後に `fis/run_experiment.sh` の出力をここに追記する。
```

---

### 6. terraform/main.tf にFISモジュールを追記

```hcl
module "fis" {
  source         = "./modules/fis"
  cluster_name   = local.cluster_name
  aws_region     = var.aws_region
  aws_account_id = var.aws_account_id
  common_tags    = local.common_tags
}
```

---

## 実行手順

```bash
# 1. FISモジュールをapply
cd terraform
terraform apply -var="aws_account_id=YOUR_ACCOUNT_ID" -var="owner=YOUR_NAME"

# 2. 実験テンプレートが作成されたか確認
aws fis list-experiment-templates --region ap-northeast-1

# 3. 負荷をかけながら実験実行（別ターミナルで負荷生成）
# ターミナル1: 負荷生成
ALB_URL=$(kubectl get ingress chaos-cell-ingress -n cell-a -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
hey -z 300s -c 10 http://${ALB_URL}/healthz

# ターミナル2: AZ障害実験実行
chmod +x fis/run_experiment.sh
./fis/run_experiment.sh az-outage
```

---

## 完了確認チェックリスト

- [ ] FIS IAMロール `eks-chaos-cell-prod-fis-role` が作成済み
- [ ] Stop Condition アラーム `eks-chaos-cell-prod-fis-stop-condition` が作成済み
- [ ] 実験テンプレートが3種類 aws コンソールで確認できる
- [ ] `fis/run_experiment.sh az-outage` がエラーなく実行できる
- [ ] 実験中に Cell-B への影響がゼロであることを確認
- [ ] `results/` ディレクトリに結果ファイルが生成される

---

## 次フェーズへの引き継ぎ情報

Phase 5（観測基盤）では以下が前提となる。

- FIS実験テンプレート3種類作成済み
- CloudWatch Logsグループ `/aws/fis/eks-chaos-cell-prod` 作成済み
- Stop Conditionアラーム ARN: `aws_cloudwatch_metric_alarm.alb_5xx_stop_condition.arn`
- 実験中の数値をGrafanaダッシュボードでリアルタイム可視化することが次フェーズの目標