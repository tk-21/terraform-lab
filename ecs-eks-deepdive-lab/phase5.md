# Phase 5: ADR + Interview Prep + Cleanup

## このフェーズの目的

ハンズオンで得た**実体験を言語化**し、面接で即座に語れるポートフォリオ資産に変換する。
コードを書けることより「なぜその設計か」を論理的に説明できることが本番で差を生む。

---

## 前提: Phase 4 の計測値を埋めてあること

```bash
# 確認
cat docs/measurement.txt | head -30
cat docs/load_test_results.json | python3 -m json.tool | head -30
```

計測値が未記入の場合はPhase 4に戻ること。

---

## Step 1: ドキュメントディレクトリ作成

```bash
mkdir -p docs
```

---

## Step 2: ADR-001 作成（⚠️ Decision セクションは必ず自筆）

```bash
cat > docs/adr-001-ecs-vs-eks.md << 'ADREOF'
# ADR-001: ECS Fargate vs EKS Karpenter 選定基準

## Status
Accepted

## Date
<!-- 実施日を記入 -->

## Context

同一ワークロード（FastAPI API + SQS Worker）をECS FargateとEKS Karpenterの
両環境にデプロイし、スケーリング速度・レイテンシ・運用コストを定量比較した。

### 比較対象

| 項目 | ECS (Fargate) | EKS (Karpenter) |
|------|--------------|-----------------|
| スケーリングトリガー | CloudWatch Alarm (60s評価) | KEDA (15sポーリング) |
| コンピュート確保 | Fargate 即時 | Karpenter NodePool |
| ゼロスケール | 非対応 (min=1) | 対応 (minReplicaCount=0) |
| 設定ファイル数 | Terraform HCL のみ | HCL + Kubernetes マニフェスト |
| 学習コスト | 低 | 高 (k8s知識必須) |

### 実測データ（Phase 4 計測値）

<!-- 自分の計測値を記入すること -->
- ロードテスト (200 jobs / 20 concurrency)
  - ECS: p50=___ms, p95=___ms, p99=___ms
  - EKS: p50=___ms, p95=___ms, p99=___ms
- スケールアウト開始まで
  - ECS: ___秒（CloudWatch Alarm評価待ち）
  - EKS: ___秒（KEDA 15s + Karpenter起動）
- Karpenter ノード起動時間: ___秒

---

## Decision

<!-- ⚠️ このセクションは必ずTakuya自身が書くこと。AIによる生成禁止。
     実際にデプロイして感じたこと、驚いたこと、難しかったことを書く。
     計測値を根拠に「自分ならどちらを選ぶか」を論じること。

     以下は問いかけ（削除して自分の言葉で置き換えること）:
     - 計測値を見て、予想と違った点は何か？
     - KEDA + Karpenter の組み合わせを実際に動かしてみてどう感じたか？
     - Fargate Spotの中断リスクとSIGTERMハンドリングをどう評価するか？
     - 自分が次のプロジェクトでどちらを選ぶか、その理由は？
-->

ADREOF

echo "ADR-001 テンプレート作成完了"
echo "★ docs/adr-001-ecs-vs-eks.md の ## Decision セクションを自分の言葉で記入すること"
```

---

## Step 3: Runbook 作成

```bash
cat > docs/runbook.md << 'RUNEOF'
# Runbook: ECS/EKS Deepdive Lab 運用手順

## 共通前提

- Region: ap-northeast-1
- Profile: 適切なAWS認証済み
- kubectl context: deepdive-eks に向いていること

```bash
aws sts get-caller-identity
kubectl config current-context  # → deepdive-eks であること
```

---

## ECS 運用手順

### ヘルスチェック

```bash
# クラスター状態
aws ecs describe-clusters --clusters deepdive-ecs \
  --query 'clusters[0].{status:status,runningTasks:runningTasksCount}'

# サービス状態
aws ecs describe-services --cluster deepdive-ecs \
  --services deepdive-api deepdive-job-worker \
  --query 'services[].{name:serviceName,running:runningCount,desired:desiredCount,status:status}'

# タスク一覧
aws ecs list-tasks --cluster deepdive-ecs --query 'taskArns'
```

### ECS Exec でコンテナに接続

```bash
# タスクARNを取得
TASK_ARN=$(aws ecs list-tasks --cluster deepdive-ecs \
  --service-name deepdive-api \
  --query 'taskArns[0]' --output text)

# コンテナにシェル接続（SSM Session Manager経由）
aws ecs execute-command \
  --cluster deepdive-ecs \
  --task "${TASK_ARN}" \
  --container api \
  --interactive \
  --command "/bin/sh"
```

### スケーリング手動操作

```bash
# Workerを手動スケール（緊急時）
aws ecs update-service \
  --cluster deepdive-ecs \
  --service deepdive-job-worker \
  --desired-count 5
```

### Fargate Spot中断時の確認

```bash
# スポット中断イベントをEventBridgeで確認
aws logs filter-log-events \
  --log-group-name /ecs/deepdive \
  --filter-pattern "SIGTERM" \
  --start-time $(date -d '1 hour ago' +%s000)
```

---

## EKS 運用手順

### ヘルスチェック

```bash
# ノード状態
kubectl get nodes -o wide

# Pod状態
kubectl get pods -n deepdive -o wide

# Karpenter NodePool状態
kubectl get nodeclaim -A

# KEDA ScaledObject状態
kubectl get scaledobject -n deepdive
```

### Pod ログ確認

```bash
# API Pod ログ
kubectl logs -n deepdive -l app=deepdive-api --tail=50

# Worker Pod ログ（複数Pod）
kubectl logs -n deepdive -l app=deepdive-worker --tail=50

# Karpenter ログ（ノードプロビジョニング確認）
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=50
```

### Pod に接続

```bash
POD=$(kubectl get pod -n deepdive -l app=deepdive-api -o name | head -1)
kubectl exec -it -n deepdive "${POD}" -- /bin/sh
```

### Karpenter 強制ドレイン

```bash
# 特定ノードを削除（Karpenterが自動再プロビジョニング）
kubectl delete node <node-name>
```

### KEDA スケーリング確認

```bash
# ScaledObjectのトリガー状態
kubectl describe scaledobject deepdive-worker-scaler -n deepdive

# 現在のSQSキュー深度をKEDAが認識しているか
kubectl get hpa -n deepdive
```

---

## SQS 運用手順

```bash
QUEUE_URL=$(aws ssm get-parameter \
  --name /deepdive/sqs-queue-url \
  --query Parameter.Value --output text)

# キュー深度確認
aws sqs get-queue-attributes \
  --queue-url "${QUEUE_URL}" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible

# DLQメッセージ確認
DLQ_URL="${QUEUE_URL}-dlq"
aws sqs receive-message --queue-url "${DLQ_URL}" --max-number-of-messages 10

# DLQ → 本キューへ再送（メッセージ救済）
# ※ DLQのメッセージを手動で本キューへ移動する場合
aws sqs start-message-move-task \
  --source-arn "$(aws sqs get-queue-attributes \
    --queue-url ${DLQ_URL} \
    --attribute-names QueueArn \
    --query Attributes.QueueArn --output text)"
```

RUNEOF

echo "Runbook 作成完了"
```

---

## Step 4: STAR形式 面接Q&A 作成

```bash
cat > docs/interview-star.md << 'STAREOF'
# STAR形式 面接想定Q&A: ECS/EKS Deepdive Lab

---

## Q1. ECSとEKSの選定経験を教えてください

**Situation（背景）**:
同一のジョブワークロード（FastAPI API + SQSバックグラウンドWorker）を
ECS FargateとEKS Karpenterの両環境に実際にデプロイし、定量比較を実施した。

**Task（課題）**:
「ECSとEKSどちらを選ぶべきか」という問いに対して、感覚論ではなく
実測データに基づいた回答ができるエンジニアになることが目標だった。

**Action（行動）**:
- 200ジョブ / 並列20リクエストのロードテストを両環境で実施
- CloudWatch Container Insights + KEDA メトリクスでスケーリング挙動を計測
- スケールアウト開始時刻をストップウォッチで記録

**Result（結果）**:
<!-- 実測値を記入 -->
- ECS: p95=___ms、スケールアウト開始まで約___秒（CloudWatch Alarm 60s評価が律速）
- EKS: p95=___ms、スケールアウト開始まで約___秒（KEDA 15sポーリングが高速）
- KEDA minReplicaCount=0 により、静穏時のWorker EC2コストをゼロにできることを確認

**面接での差分化ポイント**:
「ECSはシンプルだがスケーリングが遅い」という定性論ではなく、
「ECSのトリガーはCloudWatch Alarm評価周期60秒、KEDAは15秒ポーリングで
4倍の頻度差がある」と数値で語れること。

---

## Q2. Karpenter と Cluster Autoscaler の違いを説明してください

**Situation**: EKS環境でコスト最適化のためのノード自動スケーリングを実装した。

**Task**: Karpenterを選定した理由を設計根拠込みで説明する。

**Action**:
Karpenterを選んだ主な理由3点:
1. **ノードグループ不要**: CA(Cluster Autoscaler)はNode Groupのmin/maxで制約されるが、
   KarpenterはNodePool定義内で複数インスタンスタイプを列挙でき、
   その場の最安値SpotインスタンスをBinpackで選択する
2. **プロビジョニング速度**: CA≈3-5分 vs Karpenter≈30-60秒（実測）。
   CA経由のASGスケールアップはAWS API待ちが長い
3. **consolidation**: WhenUnderutilized でアイドルノードを自動削除、
   Disruption Budget(20%)でダウンタイムを制御

**Result**: Spot + arm64(c6g/m6g/r6g) 組み合わせでコンピュートコストを
オンデマンドx86比で約___%削減（実測値）。

---

## Q3. Pod Identity と OIDC IRSA の違いを説明してください

**Situation**: EKS上のワークロード（KEDA, LBC, APIサーバー等）に
最小権限のIAMロールを付与する必要があった。

**Task**: 新規プロジェクトでPod IdentityとIRSAどちらを使うか判断した。

**Action**:
Pod Identity（2023年11月 GA）を選択した理由:
- IRSA: ServiceAccount annotationにrole ARNを直接書く →
  Terraformのmodule分離が難しく、role ARNがk8s側に漏出する
- Pod Identity: `aws_eks_pod_identity_association` リソースでAWS側が
  ServiceAccount↔IAMロールのマッピングを管理。
  k8s manifestにIAM情報が一切不要
- Trust Policy: `pods.eks.amazonaws.com` という新しいサービスプリンシパルを使用。
  `sts:TagSession` アクションが必須（忘れると403になる）

**Result**: Terraform側でIAM + Pod Identity Associationを管理し、
k8s manifestはIAM非依存に保てた。後からロールを変更する際の
diff範囲がTerraformのみになりレビューしやすい。

---

## Q4. Fargate Spot でのグレースフルシャットダウン実装を教えてください

**Situation**: コスト削減のためWorkerをFargate Spotで動かしていた。

**Task**: Spot中断（2分前通知 → SIGTERM）時にSQSメッセージを処理中断せず
安全にシャットダウンする仕組みが必要だった。

**Action**:
ECSタスク定義で2点設定:
1. `stopTimeout=30`: SIGTERM受信からSIGKILLまでの猶予を30秒確保
2. `initProcessEnabled=true`: PID1をtini（init process）にし、
   シグナルが正しく子プロセスへ伝播するようにした

Pythonコード側:
```python
import signal

def sigterm_handler(signum, frame):
    """SIGTERM受信時: 現在処理中のメッセージを完了してから終了"""
    global shutdown_requested
    shutdown_requested = True  # whileループを抜ける
    # SQS visibility timeout内（300秒）に完了できなければDLQへ

signal.signal(signal.SIGTERM, sigterm_handler)
```

**Result**: Spot中断発生時も処理中メッセージをDLQに落とさずに完了できることを
ECS Execでログ確認してテスト済み。
`stopTimeout` を30秒にした根拠: ジョブの平均処理時間が約___秒のため、
30秒あれば99%のジョブが完了できる（実測）。

STAREOF

echo "STAR Q&A テンプレート作成完了"
echo "★ 数値（___）部分は実測値で埋めること"
```

---

## Step 5: Zenn 記事アウトライン

```bash
cat > docs/zenn-outline.md << 'ZENNEOF'
# Zenn 記事アウトライン

## タイトル案

「ECS vs EKS を同一ワークロードで実測比較：スケーリング速度・コスト・運用の違い」

## ターゲット読者

- ECSは使ったことあるがEKSをまだ使っていないエンジニア
- 「ECSとEKS何が違うの？」という問いに答えられないエンジニア

## 構成

### 1. はじめに（400字）
- ECSとEKSの比較記事は多いが、定量データで比較しているものは少ない
- 同一ワークロードを両方にデプロイして実測した

### 2. アーキテクチャ概要（Mermaidで図示）（600字）
- FastAPI API + SQS Worker を ECS / EKS 両方に
- 共通: SQS, ALB, ECR
- ECS: Fargate + Service Connect + Step Scaling
- EKS: Karpenter + KEDA + Pod Identity

### 3. スケーリング設計の違い（メイン）（1200字）

#### ECS: CloudWatch Alarm → Step Scaling
```
SQSキュー深度 → CloudWatch Alarm(60s評価) → Step Scaling Policy → Fargate Task
```
- 60秒評価の意味: スパイク直後にスケールできない
- Fargate起動は約10秒で速い

#### EKS: KEDA → HPA → Karpenter
```
SQSキュー深度 → KEDA(15sポーリング) → HPA → Pod Pending → Karpenter Node起動
```
- 15秒ポーリング = 60秒評価の4倍速
- ただしノード起動（30-60s）がボトルネック

### 4. 実測データ（★差別化ポイント）（800字）
<!-- 実際の計測値を記入 -->
| 指標 | ECS | EKS |
|------|-----|-----|
| p50レイテンシ | ___ms | ___ms |
| p95レイテンシ | ___ms | ___ms |
| スケールアウト開始 | ___秒 | ___秒 |
| ゼロスケール | 非対応 | 対応 |

### 5. KEDA minReplicaCount=0 の実際（600字）
- キュー空 → Worker Pod 0台 → Karpenter ノード削除 → EC2 0台
- 夜間・週末のコスト削減が見込める

### 6. 選定基準まとめ（400字）
- チームにk8s経験者がいる → EKS + Karpenter
- 小規模・シンプルに始めたい → ECS Fargate
- ゼロスケールが必要 → EKS + KEDA 一択

### 7. まとめ（200字）
- GitHubリポジトリ、フィードバック歓迎

## 付記
- Mermaid アーキテクチャ図: docs/adr-001-ecs-vs-eks.md から流用
- コードスニペット: GitHub リポジトリへリンク

ZENNEOF

echo "Zenn アウトライン作成完了"
```

---

## Step 6: 15分口頭説明 最終チェック

Phase 5 最大の目的。以下を**ノートなし・15分**で説明できれば合格。

```
【口頭説明 チェックリスト】

□ アーキテクチャ全体図を口頭で描ける（5分）
  - ECS側: ALB → API(Fargate, Service Connect) → SQS → Worker(Spot, SIGTERM)
  - EKS側: ALB → API(Karpenter, PDB, TopologySpread) → SQS → Worker(KEDA, 0→N)
  - 共通コンポーネント: ECR, SSM, CloudWatch, VPC Endpoints

□ ECS 設計根拠を語れる（3分）
  - なぜ base=1, weight=4 か（Fargate最低1台保証 + Spot最大化）
  - なぜ spread → binpack の順か（AZ耐障害性優先、その後コスト最適化）
  - Service Connect vs Cloud Map DNS の違い（サイドカー自動 vs DNS解決）

□ EKS 設計根拠を語れる（3分）
  - なぜ Karpenter か（CAより速いプロビジョニング、consolidation）
  - なぜ Pod Identity か（k8s manifestにIAM情報を持ち込まない）
  - KEDA minReplicaCount=0 のビジネス価値

□ 実測値を根拠に選定基準を語れる（3分）
  - p95レイテンシの差: ECS=___ms vs EKS=___ms
  - スケールアウト速度の差と理由
  - 次のプロジェクトでどちらを選ぶか
```

---

## Step 7: クリーンアップ

**順序厳守**: k8s → Helm → EKS Terraform → ECS Terraform → Foundation Terraform

```bash
echo "=== Phase 5: クリーンアップ開始 ==="

# 1. Kubernetes リソース削除（マニフェスト）
echo "[1/5] k8s マニフェスト削除"
kubectl delete -f k8s/manifests/ -n deepdive --ignore-not-found
kubectl delete namespace deepdive --ignore-not-found

# 2. Helm リリース削除（Karpenter, KEDA, LBC）
echo "[2/5] Helm リリース削除"
helm uninstall karpenter  -n kube-system 2>/dev/null || true
helm uninstall keda       -n kube-system 2>/dev/null || true
helm uninstall aws-lbc    -n kube-system 2>/dev/null || true

# 3. EKS Terraform 削除
echo "[3/5] EKS Terraform destroy"
cd terraform/eks
terraform destroy --auto-approve
cd ../..

# EKS削除後の確認
echo "EKSクラスター削除確認..."
aws eks list-clusters --query 'clusters' 2>/dev/null

# 4. ECS Terraform 削除
echo "[4/5] ECS Terraform destroy"
cd terraform/ecs
terraform destroy --auto-approve
cd ../..

# 5. Foundation Terraform 削除（最後: ECRイメージ削除してからVPC削除）
echo "[5/5] Foundation Terraform destroy"

# ECRイメージを先に削除（Terraformがfail-safeで残す設計のため）
for repo in api-server job-worker; do
  images=$(aws ecr list-images \
    --repository-name "deepdive-${repo}" \
    --query 'imageIds' --output json 2>/dev/null)
  if [ "${images}" != "[]" ] && [ -n "${images}" ]; then
    aws ecr batch-delete-image \
      --repository-name "deepdive-${repo}" \
      --image-ids "${images}" 2>/dev/null
    echo "ECR ${repo}: イメージ削除完了"
  fi
done

cd terraform/foundation
terraform destroy --auto-approve
cd ../..

echo ""
echo "=== クリーンアップ完了 ==="
echo ""
echo "残留リソース確認:"
aws ecs list-clusters --query 'clusterArns' 2>/dev/null
aws eks list-clusters --query 'clusters' 2>/dev/null
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=ecs-eks-deepdive" \
  --query 'Vpcs[].VpcId' 2>/dev/null
echo "上記が空であれば完全クリーンアップ成功"
```

---

## ラボ完了チェックリスト

```
【ecs-eks-deepdive-lab 完了基準】

□ Phase 1: VPC/SQS/ECR/IAM/アプリビルド完了
□ Phase 2: ECS Fargate + Service Connect + Step Scaling 動作確認
□ Phase 3: EKS + Karpenter + KEDA + Pod Identity 動作確認
□ Phase 4: ロードテスト実施・計測値記録済み
□ Phase 5:
  □ ADR-001 の ## Decision を自分の言葉で記入済み
  □ STAR Q&A の数値（___）を実測値で埋めた
  □ 口頭説明15分チェックをパス
  □ クリーンアップ完了・残留リソースなし

【ポートフォリオ化】
□ GitHubリポジトリにプッシュ
□ READMEに計測値サマリーを記載
□ Zenn記事を docs/zenn-outline.md を元に執筆
```