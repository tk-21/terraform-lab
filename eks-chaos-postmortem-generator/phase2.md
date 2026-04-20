# ✅Phase 2: FIS実験テンプレート・EventBridge・Orchestrator Lambda

## Phase 1の実装サマリー（必ず読むこと）

Phase 1で以下を実装済み：
- VPC（10.0.0.0/16、パブリック×2、プライベート×2、ap-northeast-1）
- EKSクラスター（eks-chaos-postmortem-dev、Kubernetes 1.30）
- ノードグループ×2（baseline: ChaosTarget=false、chaos: ChaosTarget=true）
- サンプルアプリ（namespace: chaos-target、nginx×3 Pod）
- GitHub Actions（OIDC認証、terraform plan/apply）

## プロジェクト設計（必ず読むこと）

CLAUDE.mdを読み、命名規則・タグ戦略・禁止パターンを確認してから実装すること。

---

## Phase 2で実装するもの

### 1. FISモジュール（terraform/modules/fis/）

4種類の実験テンプレートをTerraformで管理する。

**共通設計**:
- 全実験にStopCondition設定（CloudWatchアラーム閾値超過で自動停止）
- 対象はタグ`ChaosTarget=true`のリソースのみ
- FIS実験ロールを専用IAMロールで実行
- 日本語コメントで実験の意図を明記

**① Pod Kill実験**（`aws:eks:pod-delete`）:
- 名前: `eks-chaos-postmortem-pod-kill-dev`
- 対象: namespace=chaos-target の全Pod
- selectionMode: ALL
- 説明: Podの突然削除によるKubernetesの自己修復能力を検証

**② Node Termination実験**（`aws:eks:terminate-nodegroup-instances`）:
- 名前: `eks-chaos-postmortem-node-termination-dev`
- 対象: NodeGroup=`eks-chaos-postmortem-chaos-dev`（ChaosTargetノードグループのみ）
- instanceTerminationPercentage: 50
- 説明: ノード障害時のKarpenterによる自動復旧を検証

**③ Network Latency実験**（aws-node-termination-handler経由のtc netem）:
- 名前: `eks-chaos-postmortem-network-latency-dev`
- 実装方式: Kubernetes Job（`k8s/chaos-jobs/network-latency-job.yaml`）を使用
  - tc netemコマンドでchaos-targetネームスペースに100ms遅延を注入
- FISからはaws:eks:inject-kubernetes-custom-resourceで起動
- 期間: 60秒
- 説明: ネットワーク遅延によるサービス品質劣化を検証

**④ CPU Stress実験**:
- 名前: `eks-chaos-postmortem-cpu-stress-dev`
- 実装方式: stress-ng DaemonSet（`k8s/chaos-jobs/cpu-stress-job.yaml`）
  - chaos-targetネームスペースのNodeに対してCPU 80%のストレスを注入
- FISからはaws:eks:inject-kubernetes-custom-resourceで起動
- 期間: 60秒
- 説明: CPU枯渇時のPodエビクションとKarpenterのスケールアウトを検証

**StopConditionアラーム**（`terraform/modules/fis/main.tf`内で作成）:
```
CloudWatch Alarm:
  メトリクス: node_cpu_utilization（Container Insights）
  閾値: 90%以上が5分継続
  アクション: FIS実験を自動停止
```

**FIS実行IAMロール**:
- 信頼ポリシー: `fis.amazonaws.com`
- 権限:
  - `eks:*`（実験対象操作）
  - `ec2:TerminateInstances`（ノード停止）
  - `cloudwatch:DescribeAlarms`（StopCondition評価）
  - `logs:CreateLogGroup`, `logs:PutLogEvents`（実験ログ）

---

### 2. EventBridgeモジュール（terraform/modules/eventbridge/）

FIS実験の完了イベントを検知してOrchestrator Lambdaを起動する。

**ルール設定**:
```json
{
  "source": ["aws.fis"],
  "detail-type": ["FIS Experiment State Change"],
  "detail": {
    "state": {
      "status": ["completed", "failed", "stopped"]
    }
  }
}
```

- ターゲット: Orchestrator Lambda（fis-event-handler）
- Dead Letter Queue: SQS（失敗イベントを保全）
- ルール名: `eks-chaos-postmortem-fis-state-change-dev`

---

### 3. Orchestrator Lambda（lambda/fis-event-handler/）

FIS実験完了イベントを受け取り、Step Functionsを起動する。

**main.py の実装**:

```python
# 設計意図:
# FISイベントを受け取り、実験IDと実験種別を抽出してStep Functionsに渡す。
# DynamoDBで冪等性を保証し、同一実験IDの重複処理を防ぐ。
```

- AWS Lambda Powertoolsを使用（構造化ログ・トレーシング）
- DynamoDB（テーブル名: `eks-chaos-postmortem-experiments-dev`）で冪等性チェック
  - パーティションキー: `experiment_id`
  - TTL: 7日間
- Step Functionsへの入力:
  ```json
  {
    "experiment_id": "EXP-xxxxx",
    "experiment_type": "pod-kill",
    "start_time": "2026-04-18T10:00:00Z",
    "end_time": "2026-04-18T10:05:00Z",
    "state": "completed"
  }
  ```
- エラーハンドリング: 例外発生時はDead Letter Queueへ

**IAMロール**:
- DynamoDB: GetItem, PutItem（experiments テーブルのみ）
- Step Functions: StartExecution（postmortem-workflowのみ）
- CloudWatch Logs: 構造化ログ出力
- X-Ray: トレーシング

**requirements.txt**:
```
aws-lambda-powertools>=2.0.0
boto3>=1.34.0
```

---

### 4. DynamoDBテーブル（terraform/modules/lambda/内で定義）

- テーブル名: `eks-chaos-postmortem-experiments-dev`
- パーティションキー: `experiment_id`（String）
- BillingMode: PAY_PER_REQUEST
- TTL属性: `ttl`
- PointInTimeRecovery: 有効
- タグ: 必須5タグ付与

---

### 5. Chaos Engineeringマニフェスト（k8s/chaos-jobs/）

`network-latency-job.yaml`:
- Jobリソース（namespace: chaos-target）
- initContainerでtc netemを実行（100ms遅延）
- 完了後に自動削除（ttlSecondsAfterFinished: 60）
- securityContext: NET_ADMIN capability（tc netem実行に必要）

`cpu-stress-job.yaml`:
- Jobリソース（namespace: chaos-target）
- stress-ng imageを使用（CPUストレス80%）
- リソースリミット: cpu=500m, memory=128Mi
- 実行時間: 60秒

---

## 実装上の注意事項

1. FIS実験テンプレートのTerraformリソースは`aws_fis_experiment_template`を使用
2. EventBridgeルールはFISの`completed`・`failed`・`stopped`全状態を対象にする
3. Orchestrator Lambdaは**失敗状態のFIS実験もStep Functionsに渡す**（失敗分析のため）
4. DynamoDBの冪等性チェックは`ConditionExpression`で`attribute_not_exists(experiment_id)`を使用
5. 全ファイルに日本語インラインコメントで設計意図を記載

## 完了確認

- [ ] terraform/modules/fis/main.tf, variables.tf, outputs.tf
- [ ] terraform/modules/eventbridge/main.tf, variables.tf
- [ ] lambda/fis-event-handler/main.py, requirements.txt
- [ ] k8s/chaos-jobs/network-latency-job.yaml
- [ ] k8s/chaos-jobs/cpu-stress-job.yaml
- [ ] DynamoDBテーブルがterraform/modules/lambda/main.tf内に定義されている
- [ ] CLAUDE.mdの命名規則・タグ戦略と一致していること