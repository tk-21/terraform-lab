# Phase 4: 可観測性 + ロードテスト + ECS vs EKS定量比較

## このフェーズの目的

「ECS vs EKS どちらが優れているか」を**実測データ**で語れるようにする。
定性的な比較ではなく、手元の計測値を根拠に面接で即答できるレベルを目指す。

## 前フェーズの確認

```bash
cd ~/ecs-eks-deepdive-lab

# ECS: APIが応答していることを確認
ECS_ALB=$(cd terraform/ecs && terraform output -raw alb_dns_name)
curl -s "http://${ECS_ALB}/health" | python3 -m json.tool

# EKS: APIが応答していることを確認
EKS_ALB=$(kubectl get ingress deepdive-api -n deepdive -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s "http://${EKS_ALB}/health" | python3 -m json.tool

# SQSキューが空であることを確認
QUEUE_URL=$(aws ssm get-parameter --name /deepdive/sqs-queue-url --query Parameter.Value --output text)
aws sqs get-queue-attributes \
  --queue-url "${QUEUE_URL}" \
  --attribute-names ApproximateNumberOfMessages \
  --query Attributes
```

---

## Step 1: EKS Container Insights セットアップ

ECSはPhase 2でContainer Insights有効化済み。EKS側をセットアップする。

### 1-1. Pod Identity用IAMロール追加

```hcl
# terraform/eks/cloudwatch.tf
# EKS Container Insights用 Pod Identityロール
resource "aws_iam_role" "cloudwatch_agent" {
  # ロール名64文字以内
  name = "deepdive-eks-cw-agent"

  # Pod Identityトラスト（OIDC IRSAではなく新方式）
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }]
  })

  tags = {
    Project = "ecs-eks-deepdive"
    Phase   = "4"
  }
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.cloudwatch_agent.name
  # AWSマネージドポリシー: CloudWatch Agentに必要な最小権限
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Pod Identity Association: cloudwatch-agentサービスアカウントにロールをバインド
resource "aws_eks_pod_identity_association" "cloudwatch_agent" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "amazon-cloudwatch"
  service_account = "cloudwatch-agent"
  role_arn        = aws_iam_role.cloudwatch_agent.arn
}
```

### 1-2. amazon-cloudwatch-observability アドオン

```hcl
# terraform/eks/cloudwatch.tf (続き)
resource "aws_eks_addon" "cloudwatch_observability" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "amazon-cloudwatch-observability"

  # アドオンが作成するサービスアカウントはPod Identity Associationと自動連携
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_pod_identity_association.cloudwatch_agent,
    aws_eks_node_group.system
  ]

  tags = {
    Project = "ecs-eks-deepdive"
    Phase   = "4"
  }
}
```

```bash
cd terraform/eks
terraform apply -target=aws_iam_role.cloudwatch_agent \
                -target=aws_iam_role_policy_attachment.cloudwatch_agent \
                -target=aws_eks_pod_identity_association.cloudwatch_agent \
                -target=aws_eks_addon.cloudwatch_observability \
                --auto-approve

# CloudWatch Agentが起動しているか確認
kubectl get pods -n amazon-cloudwatch
# NAME                                     READY   STATUS    RESTARTS
# cloudwatch-agent-xxxxx                   1/1     Running   0   ← 各ノードに1つ

# ログが流れているか（数分待つ）
aws logs describe-log-groups \
  --log-group-name-prefix "/aws/containerinsights/deepdive-eks" \
  --query "logGroups[].logGroupName"
```

---

## Step 2: CloudWatch Dashboard 作成

ECS と EKS を横並びで比較できるダッシュボードをTerraformで作成。

```hcl
# terraform/foundation/dashboard.tf
resource "aws_cloudwatch_dashboard" "comparison" {
  dashboard_name = "deepdive-ecs-eks-comparison"

  # Terraformでダッシュボード定義をJSONで記述
  dashboard_body = jsonencode({
    widgets = [
      # ─── 行1: SQSメトリクス（共通） ───
      {
        type   = "metric"
        x      = 0; y = 0; width = 12; height = 6
        properties = {
          title  = "SQS - キュー深度（ロードテスト確認用）"
          region = "ap-northeast-1"
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible",
             "QueueName", "deepdive-job-queue",
             { stat = "Maximum", period = 60, label = "Visible Messages" }],
            ["AWS/SQS", "NumberOfMessagesSent",
             "QueueName", "deepdive-job-queue",
             { stat = "Sum", period = 60, label = "Sent" }],
            ["AWS/SQS", "NumberOfMessagesDeleted",
             "QueueName", "deepdive-job-queue",
             { stat = "Sum", period = 60, label = "Processed" }]
          ]
          view   = "timeSeries"
          period = 60
        }
      },
      # ─── 行1右: ECS vs EKS Worker数比較 ───
      {
        type   = "metric"
        x      = 12; y = 0; width = 12; height = 6
        properties = {
          title  = "Worker数比較: ECS (Fargate) vs EKS (Karpenter+KEDA)"
          region = "ap-northeast-1"
          metrics = [
            ["ECS/ContainerInsights", "RunningTaskCount",
             "ClusterName", "deepdive-ecs",
             "ServiceName", "deepdive-job-worker",
             { stat = "Maximum", period = 60, label = "ECS Worker Tasks" }],
            ["ContainerInsights", "pod_number_of_running_containers",
             "ClusterName", "deepdive-eks",
             "Namespace", "deepdive",
             "PodName", "deepdive-worker",
             { stat = "Maximum", period = 60, label = "EKS Worker Pods" }]
          ]
          view   = "timeSeries"
        }
      },
      # ─── 行2: ECS スケーリングメトリクス ───
      {
        type   = "metric"
        x      = 0; y = 6; width = 12; height = 6
        properties = {
          title  = "ECS: CPU使用率 + スケーリングイベント"
          region = "ap-northeast-1"
          metrics = [
            ["ECS/ContainerInsights", "CpuUtilized",
             "ClusterName", "deepdive-ecs",
             "ServiceName", "deepdive-api",
             { stat = "Average", period = 60, label = "API CPU (avg)" }],
            ["ECS/ContainerInsights", "CpuUtilized",
             "ClusterName", "deepdive-ecs",
             "ServiceName", "deepdive-job-worker",
             { stat = "Average", period = 60, label = "Worker CPU (avg)" }]
          ]
          view = "timeSeries"
        }
      },
      # ─── 行2右: EKS スケーリングメトリクス ───
      {
        type   = "metric"
        x      = 12; y = 6; width = 12; height = 6
        properties = {
          title  = "EKS: Pod CPU + Karpenter ノード数"
          region = "ap-northeast-1"
          metrics = [
            ["ContainerInsights", "pod_cpu_utilization",
             "ClusterName", "deepdive-eks",
             "Namespace", "deepdive",
             { stat = "Average", period = 60, label = "Pod CPU (avg)" }],
            ["ContainerInsights", "node_number_of_running_pods",
             "ClusterName", "deepdive-eks",
             { stat = "Maximum", period = 60, label = "Node Running Pods" }]
          ]
          view = "timeSeries"
        }
      },
      # ─── 行3: ALBレスポンスタイム比較 ───
      {
        type   = "metric"
        x      = 0; y = 12; width = 24; height = 6
        properties = {
          title  = "ALB レスポンスタイム比較 (p50/p95/p99)"
          region = "ap-northeast-1"
          # NOTE: LoadBalancerはTerraform apply後に実際のARNで置き換える
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime",
             "LoadBalancer", "app/deepdive-ecs-alb/REPLACE_ME",
             { stat = "p50",  period = 60, label = "ECS p50" }],
            ["AWS/ApplicationELB", "TargetResponseTime",
             "LoadBalancer", "app/deepdive-ecs-alb/REPLACE_ME",
             { stat = "p95",  period = 60, label = "ECS p95" }],
            ["AWS/ApplicationELB", "TargetResponseTime",
             "LoadBalancer", "app/deepdive-ecs-alb/REPLACE_ME",
             { stat = "p99",  period = 60, label = "ECS p99" }],
            ["AWS/ApplicationELB", "TargetResponseTime",
             "LoadBalancer", "app/deepdive-eks-alb/REPLACE_ME",
             { stat = "p50",  period = 60, label = "EKS p50" }],
            ["AWS/ApplicationELB", "TargetResponseTime",
             "LoadBalancer", "app/deepdive-eks-alb/REPLACE_ME",
             { stat = "p95",  period = 60, label = "EKS p95" }],
            ["AWS/ApplicationELB", "TargetResponseTime",
             "LoadBalancer", "app/deepdive-eks-alb/REPLACE_ME",
             { stat = "p99",  period = 60, label = "EKS p99" }]
          ]
          view = "timeSeries"
        }
      }
    ]
  })
}
```

```bash
cd terraform/foundation
terraform apply -target=aws_cloudwatch_dashboard.comparison --auto-approve

# ダッシュボードURL確認
echo "https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#dashboards:name=deepdive-ecs-eks-comparison"
```

---

## Step 3: ロードテストスクリプト作成

```bash
mkdir -p scripts
cat > scripts/load_test.py << 'PYEOF'
#!/usr/bin/env python3
"""
ECS vs EKS ロードテスト & 計測スクリプト
使い方: python3 scripts/load_test.py --target ecs|eks|both
"""
import asyncio
import aiohttp
import argparse
import time
import statistics
import json
from datetime import datetime, UTC

# ── 設定 ────────────────────────────────────────────
CONCURRENCY   = 20   # 同時リクエスト数
TOTAL_JOBS    = 200  # 送信するジョブ総数
JOB_PAYLOAD   = {"task": "load-test", "sleep_seconds": 2}


async def post_job(session: aiohttp.ClientSession, url: str) -> float:
    """1リクエスト送信して応答時間(ms)を返す"""
    start = time.monotonic()
    try:
        async with session.post(
            f"{url}/jobs",
            json=JOB_PAYLOAD,
            timeout=aiohttp.ClientTimeout(total=10)
        ) as resp:
            await resp.text()
            return (time.monotonic() - start) * 1000  # ms
    except Exception as e:
        print(f"  ERROR: {e}")
        return -1.0


async def run_load_test(name: str, base_url: str) -> dict:
    """ロードテスト実行 → 統計を返す"""
    print(f"\n{'='*50}")
    print(f"[{name}] ロードテスト開始: {base_url}")
    print(f"  同時リクエスト: {CONCURRENCY}, 総ジョブ数: {TOTAL_JOBS}")
    print(f"  開始時刻: {datetime.now(UTC).isoformat()}")

    latencies = []
    errors = 0
    semaphore = asyncio.Semaphore(CONCURRENCY)
    test_start = time.monotonic()

    async def bounded_post(session):
        async with semaphore:
            return await post_job(session, base_url)

    connector = aiohttp.TCPConnector(limit=CONCURRENCY * 2)
    async with aiohttp.ClientSession(connector=connector) as session:
        tasks = [bounded_post(session) for _ in range(TOTAL_JOBS)]
        results = await asyncio.gather(*tasks)

    total_elapsed = time.monotonic() - test_start

    for r in results:
        if r < 0:
            errors += 1
        else:
            latencies.append(r)

    if not latencies:
        print(f"  [ERROR] 全リクエスト失敗")
        return {}

    latencies.sort()
    stats = {
        "name":       name,
        "total":      TOTAL_JOBS,
        "errors":     errors,
        "success":    len(latencies),
        "elapsed_s":  round(total_elapsed, 2),
        "rps":        round(TOTAL_JOBS / total_elapsed, 1),
        "p50_ms":     round(statistics.median(latencies), 1),
        "p95_ms":     round(latencies[int(len(latencies) * 0.95)], 1),
        "p99_ms":     round(latencies[int(len(latencies) * 0.99)], 1),
        "max_ms":     round(max(latencies), 1),
        "mean_ms":    round(statistics.mean(latencies), 1),
    }

    print(f"\n  ─── 結果 ({name}) ───")
    print(f"  成功: {stats['success']}/{TOTAL_JOBS}  エラー: {errors}")
    print(f"  総時間: {stats['elapsed_s']}s  RPS: {stats['rps']}")
    print(f"  レイテンシ p50={stats['p50_ms']}ms  p95={stats['p95_ms']}ms  p99={stats['p99_ms']}ms  max={stats['max_ms']}ms")

    return stats


def print_comparison(ecs_stats: dict, eks_stats: dict):
    """ECS vs EKS 比較テーブル表示"""
    print(f"\n{'='*60}")
    print("ECS vs EKS 定量比較")
    print(f"{'='*60}")
    print(f"{'指標':<20} {'ECS (Fargate)':<20} {'EKS (Karpenter)':<20}")
    print(f"{'-'*60}")
    metrics = [
        ("RPS",          "rps",      "req/s"),
        ("p50レイテンシ",  "p50_ms",  "ms"),
        ("p95レイテンシ",  "p95_ms",  "ms"),
        ("p99レイテンシ",  "p99_ms",  "ms"),
        ("エラー率",       "errors",  "件"),
    ]
    for label, key, unit in metrics:
        e = ecs_stats.get(key, "N/A")
        k = eks_stats.get(key, "N/A")
        print(f"  {label:<18} {str(e)+' '+unit:<20} {str(k)+' '+unit:<20}")
    print(f"{'='*60}")
    print("\n※ スケーリング速度はCloudWatchダッシュボードで確認:")
    print("  ECS: CloudWatch Alarm (60s評価) → Step Scaling")
    print("  EKS: KEDA pollingInterval=15s → HPA → Karpenter")


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ecs-url",  help="ECS ALB URL (http://...)")
    parser.add_argument("--eks-url",  help="EKS ALB URL (http://...)")
    parser.add_argument("--target",   choices=["ecs","eks","both"], default="both")
    parser.add_argument("--jobs",     type=int, default=TOTAL_JOBS)
    parser.add_argument("--concurrency", type=int, default=CONCURRENCY)
    args = parser.parse_args()

    global TOTAL_JOBS, CONCURRENCY
    TOTAL_JOBS  = args.jobs
    CONCURRENCY = args.concurrency

    ecs_stats, eks_stats = {}, {}

    if args.target in ("ecs", "both"):
        url = args.ecs_url or input("ECS ALB URL: ").strip()
        ecs_stats = await run_load_test("ECS", url)

    if args.target in ("eks", "both"):
        if args.target == "both":
            print("\n30秒待機（SQSキューをフラッシュ）...")
            await asyncio.sleep(30)
        url = args.eks_url or input("EKS ALB URL: ").strip()
        eks_stats = await run_load_test("EKS", url)

    if ecs_stats and eks_stats:
        print_comparison(ecs_stats, eks_stats)

    # 結果をJSONで保存
    output = {
        "timestamp": datetime.now(UTC).isoformat(),
        "ecs": ecs_stats,
        "eks": eks_stats
    }
    with open("load_test_results.json", "w") as f:
        json.dump(output, f, indent=2, ensure_ascii=False)
    print("\n結果を load_test_results.json に保存しました")


if __name__ == "__main__":
    asyncio.run(main())
PYEOF

chmod +x scripts/load_test.py
pip3 install aiohttp --quiet
echo "スクリプト作成完了"
```

---

## Step 4: ロードテスト実行 & 計測

### 4-1. 事前確認

```bash
# ALB URLを環境変数にセット
export ECS_URL="http://$(cd terraform/ecs && terraform output -raw alb_dns_name)"
export EKS_URL="http://$(kubectl get ingress deepdive-api -n deepdive \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"

echo "ECS: ${ECS_URL}"
echo "EKS: ${EKS_URL}"

# 両方ヘルスチェック
curl -s "${ECS_URL}/health" | python3 -m json.tool
curl -s "${EKS_URL}/health" | python3 -m json.tool

# スケーリング前のWorker数を記録（★計測値として保存）
echo "=== スケーリング前 Worker数 ===" | tee -a measurement.txt
echo "ECS Workers: $(aws ecs describe-services \
  --cluster deepdive-ecs --services deepdive-job-worker \
  --query 'services[0].runningCount')" | tee -a measurement.txt
echo "EKS Workers: $(kubectl get pods -n deepdive -l app=deepdive-worker \
  --no-headers | grep Running | wc -l)" | tee -a measurement.txt
echo "EKS Nodes: $(kubectl get nodes --no-headers | wc -l)" | tee -a measurement.txt
```

### 4-2. ロードテスト実行

```bash
# ロードテスト実行（両方）
# ※ ECSを先に実行、30秒待機後EKSを実行
python3 scripts/load_test.py \
  --target both \
  --ecs-url "${ECS_URL}" \
  --eks-url "${EKS_URL}" \
  --jobs 200 \
  --concurrency 20
```

### 4-3. スケーリング挙動の計測

```bash
# ロードテスト中に別ターミナルで実行
# スケーリング開始時刻を計測する

watch_scaling() {
  local start=$(date +%s)
  local initial_ecs=$(aws ecs describe-services \
    --cluster deepdive-ecs --services deepdive-job-worker \
    --query 'services[0].desiredCount' --output text)
  local initial_eks=$(kubectl get pods -n deepdive -l app=deepdive-worker \
    --no-headers | grep -c Running)

  echo "監視開始 (ECS初期Worker=${initial_ecs}, EKS初期Worker=${initial_eks})"
  while true; do
    sleep 5
    local ecs_count=$(aws ecs describe-services \
      --cluster deepdive-ecs --services deepdive-job-worker \
      --query 'services[0].desiredCount' --output text)
    local eks_count=$(kubectl get pods -n deepdive -l app=deepdive-worker \
      --no-headers | grep -c Running)
    local elapsed=$(( $(date +%s) - start ))

    echo "[${elapsed}s] ECS Worker=${ecs_count}  EKS Worker=${eks_count}"

    # スケールアウト検出
    if [ "${ecs_count}" -gt "${initial_ecs}" ] && [ -z "${ecs_scaled_at}" ]; then
      local ecs_scaled_at=$elapsed
      echo "★ ECSスケールアウト検出: ${elapsed}秒後" | tee -a measurement.txt
    fi
    if [ "${eks_count}" -gt "${initial_eks}" ] && [ -z "${eks_scaled_at}" ]; then
      local eks_scaled_at=$elapsed
      echo "★ EKSスケールアウト検出: ${elapsed}秒後" | tee -a measurement.txt
    fi
  done
}

watch_scaling
```

### 4-4. 計測結果の記録

ロードテスト完了後、以下を `measurement.txt` に追記する。

```bash
echo "=== ロードテスト結果 ===" >> measurement.txt
cat load_test_results.json | python3 -m json.tool >> measurement.txt

# Karpenter ノードプロビジョニング時間
echo "=== Karpenter イベントログ ===" >> measurement.txt
kubectl get events -n deepdive \
  --field-selector reason=ProvisioningSucceeded \
  --sort-by='.lastTimestamp' | tail -10 >> measurement.txt

# ECS スケーリングイベント
echo "=== ECS Service Events ===" >> measurement.txt
aws ecs describe-services \
  --cluster deepdive-ecs \
  --services deepdive-job-worker \
  --query 'services[0].events[:10]' >> measurement.txt

cat measurement.txt
```

---

## Step 5: 比較分析

計測後、以下の問いに**自分の言葉**で答えられるか確認する。

### 必須確認事項（数値を埋めること）

```
【計測値記録シート】

1. ロードテスト (200 jobs / 20 concurrency)
   ECS: p50=___ms  p95=___ms  p99=___ms  RPS=___
   EKS: p50=___ms  p95=___ms  p99=___ms  RPS=___

2. スケールアウト速度
   ECS: ジョブ送信から Worker増加まで ___秒
     理由: CloudWatch Alarm評価周期(60s) + Step Scaling反映時間
   EKS: ジョブ送信から Worker増加まで ___秒
     理由: KEDA pollingInterval=15s + HPA → Karpenter ノード起動

3. コールドスタート（0台からの起動）
   ECS FARGATE: PENDING→RUNNING ___秒
   EKS Pod起動: Karpenter ノード起動含めて ___秒

4. Worker最大台数
   ECS: ___台  EKS: ___台
```

### スケーリング速度の差を説明できるか？

| 要因 | ECS | EKS |
|------|-----|-----|
| スケーリングトリガー | CloudWatch Alarm (60s評価) | KEDA pollingInterval=15s |
| スケーリング決定 | Step Scaling Policy | HPA (Kubernetes) |
| コンピュート確保 | Fargate即時 (≈10s) | Karpenter NodePool (≈30-60s) |
| 合計目安 | **約90秒〜** | **約45〜75秒** |

> **なぜEKSのほうが速い場合があるか？**
> KEDAの15秒ポーリングはCloudWatch Alarm(60s)より4倍高頻度。ただし
> Karpenterのノード起動がボトルネックになる場合はECSと逆転する。

---

## Step 6: CloudWatch Logs Insights クエリ

```bash
# API処理時間分布を確認
LOG_GROUP_ECS="/aws/ecs/deepdive-api"
LOG_GROUP_EKS="/aws/containerinsights/deepdive-eks/application"

# ECS: 過去1時間のAPIリクエスト統計
aws logs start-query \
  --log-group-name "${LOG_GROUP_ECS}" \
  --start-time $(date -d '1 hour ago' +%s) \
  --end-time $(date +%s) \
  --query-string '
    fields @timestamp, @message
    | parse @message "duration_ms=*" as duration
    | stats
        count() as requests,
        pct(duration, 50) as p50,
        pct(duration, 95) as p95,
        pct(duration, 99) as p99
        by bin(5m)
    | sort @timestamp desc
  '
```

---

## 口頭説明チェック（15分）

このフェーズ完了後、以下を**ノートなし**で説明できるか確認する。

**Q1: ECSとEKSでスケーリング速度が異なる理由を数値込みで説明してください（5分）**

ポイント:
- CloudWatch Alarm 評価周期 vs KEDA pollingInterval
- Fargate の即時起動 vs Karpenter ノードプロビジョニング
- 実測値（秒数）を根拠に語る

**Q2: 今回の計測結果から、どのユースケースでECS/EKSを選びますか？（5分）**

ポイント:
- レイテンシ結果（p95/p99）を根拠に
- コスト観点（Fargate Spot vs Karpenter Spot）
- 運用複雑度（マニフェストファイル数、学習コスト）

**Q3: KEDA の minReplicaCount=0 のビジネス価値は？（3分）**

ポイント:
- キューが空のとき Worker Pod = 0台
- Karpenterがノードも削除 → EC2コスト¥0
- 夜間/週末の静穏期間でのコスト削減効果

---

## 次のフェーズへ

```bash
# 計測値をphase5で使うためJSONを保存
cp load_test_results.json docs/ 2>/dev/null || mkdir -p docs && cp load_test_results.json docs/
cp measurement.txt docs/

echo "Phase 4 完了"
echo "計測値記録シートの数値を埋めてから Phase 5 へ進む"
echo "  → claude < phase5.md"
```