# Runbook: CPU ストレス実験手順

## 概要

AWS FIS を使用して EC2 インスタンスに CPU ストレスを注入し、
ASG の Target Tracking スケールアウトを検証する手順書。

- **実験時間**: 約 10〜15 分
- **対象環境**: dev (ap-northeast-1)
- **影響範囲**: ASG 内インスタンスの 50%（FIS フィルタで制御）

---

## 前提条件

以下がすべて満たされていることを確認する:

- [ ] AWS CLI がインストール済み・設定済み (`aws sts get-caller-identity` で確認)
- [ ] `jq` がインストール済み (`jq --version` で確認)
- [ ] Terraform が適用済み（全フェーズ 1〜3 完了）
- [ ] `scripts/` ディレクトリに実行権限付きスクリプトが存在する

```bash
# 前提確認コマンド
aws sts get-caller-identity
jq --version
ls -la scripts/
```

---

## 実験前チェックリスト

### ASG ヘルシー確認

```bash
export ASG_NAME=$(cd terraform/environments/dev && terraform output -raw asg_name)

aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --region ap-northeast-1 \
  --query 'AutoScalingGroups[0].{Desired:DesiredCapacity,Min:MinSize,Max:MaxSize,Instances:Instances[*].{ID:InstanceId,State:LifecycleState,Health:HealthStatus}}' \
  --output json
```

**期待値**: InService 状態のインスタンスが 2 台以上

### CloudWatch アラーム状態確認

```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix "cel-dev" \
  --region ap-northeast-1 \
  --query 'MetricAlarms[*].{Name:AlarmName,State:StateValue}' \
  --output table
```

**期待値**: FIS 停止条件アラームが `OK` 状態であること

### ALB ヘルスチェック確認

```bash
export ALB_DNS=$(cd terraform/environments/dev && terraform output -raw alb_dns_name)
curl -sf "http://$ALB_DNS/health" && echo "ALB OK" || echo "ALB NG"
```

---

## 実験手順

### Step 1: Terraform 出力値の確認

```bash
cd terraform/environments/dev
terraform output
```

出力例:
```
alb_dns_name              = "cel-dev-alb-123456789.ap-northeast-1.elb.amazonaws.com"
asg_name                  = "cel-dev-asg"
fis_experiment_template_id = "EXT1234ABCD567890"
```

### Step 2: 環境変数のエクスポート

```bash
# プロジェクトルートに戻る
cd /path/to/chaos-engineering-lab

export FIS_TEMPLATE_ID=$(cd terraform/environments/dev && terraform output -raw fis_experiment_template_id)
export ASG_NAME=$(cd terraform/environments/dev && terraform output -raw asg_name)
export ALB_DNS=$(cd terraform/environments/dev && terraform output -raw alb_dns_name)

# 確認
echo "FIS_TEMPLATE_ID: $FIS_TEMPLATE_ID"
echo "ASG_NAME: $ASG_NAME"
echo "ALB_DNS: $ALB_DNS"
```

### Step 3: ドライラン確認

```bash
./scripts/run_experiment.sh --dry-run
```

`[DRY RUN] 実験は起動しません` と表示されれば設定 OK。

### Step 4: 実験起動

```bash
./scripts/run_experiment.sh
```

スクリプトは以下を自動実行する:
1. 実験前インスタンス数を記録
2. FIS 実験を起動（`aws fis start-experiment`）
3. 15 分以内に完了を待機（30 秒ごとにステータスを確認）
4. 実験後インスタンス数と比較して結果をサマリー表示

### Step 5: スケールアウト監視（別ターミナルで実行）

```bash
# 別ターミナルを開いて実行
export ASG_NAME=$(cd terraform/environments/dev && terraform output -raw asg_name)
watch -n 30 ./scripts/check_scaling.sh
```

`watch` が使えない環境では:
```bash
while true; do ./scripts/check_scaling.sh; sleep 30; done
```

### Step 6: FIS ログ確認（CloudWatch Logs）

```bash
aws logs get-log-events \
  --log-group-name "/aws/fis/cel-dev-cpu-stress" \
  --log-stream-name "$(aws logs describe-log-streams \
    --log-group-name '/aws/fis/cel-dev-cpu-stress' \
    --order-by LastEventTime \
    --descending \
    --max-items 1 \
    --query 'logStreams[0].logStreamName' \
    --output text)" \
  --region ap-northeast-1 \
  --query 'events[*].message' \
  --output text
```

### Step 7: 実験後の状態確認

```bash
# run_experiment.sh が保存した実験 ID を読み込む
export EXPERIMENT_ID=$(cat .last_experiment_id)
echo "EXPERIMENT_ID: $EXPERIMENT_ID"

# インスタンス数の確認
./scripts/check_scaling.sh

# FIS 実験の詳細確認
aws fis get-experiment \
  --id "$EXPERIMENT_ID" \
  --region ap-northeast-1 \
  --query 'experiment.{Status:state.status,StartTime:startTime,EndTime:endTime}' \
  --output json
```

---

## ロールバック手順

実験後にインスタンス数が自動でスケールインしない場合（Target Tracking が効かない場合）:

```bash
# ASG の DesiredCapacity を手動でリセット
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name "$ASG_NAME" \
  --desired-capacity 2 \
  --region ap-northeast-1
```

FIS 実験を手動停止する場合:

```bash
# 実験 ID を確認してから停止
export EXPERIMENT_ID=$(cat .last_experiment_id)
aws fis stop-experiment \
  --id "$EXPERIMENT_ID" \
  --region ap-northeast-1
```

---

## トラブルシューティング

### FIS が `failed` ステータスになる場合

**原因候補**:
1. FIS 実行ロールに SSM SendCommand 権限が不足している
2. 対象インスタンスに SSM Agent が起動していない
3. SSM マネージドドキュメント `AWSFIS-Run-CPU-Stress` がリージョンに存在しない

**確認コマンド**:
```bash
# SSM Agent 接続確認
aws ssm describe-instance-information \
  --region ap-northeast-1 \
  --query 'InstanceInformationList[*].{ID:InstanceId,Status:PingStatus}' \
  --output table

# FIS 実験の失敗理由を確認
export EXPERIMENT_ID=$(cat .last_experiment_id)
aws fis get-experiment \
  --id "$EXPERIMENT_ID" \
  --region ap-northeast-1 \
  --query 'experiment.state.reason' \
  --output text
```

### スケールアウトしない場合

**原因候補**:
1. CPU 使用率が Target Tracking の閾値（70%）に達していない
2. ASG のスケーリングクールダウン期間中
3. Target Tracking ポリシーが正しく設定されていない

**確認コマンド**:
```bash
# CPU メトリクスをリアルタイム確認（Linux/macOS 両対応）
START_TIME=$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-5M +%Y-%m-%dT%H:%M:%SZ)
aws cloudwatch get-metric-statistics \
  --namespace AWS/EC2 \
  --metric-name CPUUtilization \
  --dimensions Name=AutoScalingGroupName,Value="$ASG_NAME" \
  --start-time "$START_TIME" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 \
  --statistics Average \
  --region ap-northeast-1

# スケーリングポリシーの確認
aws autoscaling describe-policies \
  --auto-scaling-group-name "$ASG_NAME" \
  --region ap-northeast-1 \
  --output json
```

### SSM SendCommand が失敗する場合

**原因候補**:
1. EC2 インスタンスプロファイルに SSM 権限が不足
2. インスタンスがプライベートサブネットで VPC エンドポイントが未設定
3. `stress-ng` が UserData でインストールされていない

**確認コマンド**:
```bash
# SSM コマンド実行履歴確認
aws ssm list-command-invocations \
  --region ap-northeast-1 \
  --query 'CommandInvocations[*].{ID:InstanceId,Status:Status,Error:StandardErrorContent}' \
  --output table
```

---

## コスト影響（実験 1 回あたりの概算）

| リソース | 実験中 | 備考 |
|----------|--------|------|
| EC2 t3.micro | $0.004/時間 × インスタンス数 | 実験中の追加インスタンス含む |
| ALB | 変わらず | 固定 LCU コスト |
| FIS | $0.00 | FIS 自体は無料 |
| SSM SendCommand | $0.00 | 無料枠内 |
| CloudWatch ログ | $0.001 以下 | 少量のログ書き込み |
| **合計（15 分実験）** | **〜$0.05** | スケールアウト 2 インスタンム追加想定 |

> ⚠️ NAT Gateway は実験の有無に関わらず時間課金。
> 検証完了後は `terraform destroy` でリソースを削除することを推奨。
