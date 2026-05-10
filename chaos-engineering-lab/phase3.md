# ✅Phase 3 — IAM ロール + FIS 実験テンプレート

## 前フェーズ（Phase 1-2）の成果物

Phase 1:
- `terraform/modules/vpc/` — VPC / サブネット / IGW / NAT GW
- `terraform/modules/sg/` — ALB SG / EC2 SG

Phase 2:
- `terraform/modules/alb/` — ALB / ターゲットグループ / S3 アクセスログ
- `terraform/modules/asg/` — Launch Template / ASG / Target Tracking Policy (CPU 70%)
- `terraform/environments/dev/main.tf` — vpc / sg / alb / asg モジュール有効化済み

## このフェーズのゴール

以下のファイルを生成する:
1. IAM モジュール（FIS 実行ロール + EC2 インスタンスプロファイル）
2. FIS モジュール（CPU ストレス実験テンプレート + CloudWatch 停止条件）
3. `environments/dev/main.tf` の iam / fis モジュール呼び出しを有効化

---

## 生成指示

### 1. `terraform/modules/iam/main.tf`

#### 1-1. EC2 インスタンスプロファイル

```
# EC2 が SSM・CloudWatch と通信するための最小権限ロール
aws_iam_role               # cel-ec2-ssm-role
  assume_role_policy: EC2 サービスプリンシパル

aws_iam_role_policy_attachment (× 3)
  - arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore  # SSM 必須
  - arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy   # CW メトリクス送信
  # ※ 管理ポリシーは最小限に留める。カスタムポリシーで上書きしない。

aws_iam_instance_profile   # cel-ec2-instance-profile
  role: aws_iam_role.ec2_ssm_role.name
```

#### 1-2. FIS 実行ロール

```
# FIS が SSM SendCommand を使って EC2 に CPU 負荷を注入するロール
aws_iam_role               # cel-fis-execution-role
  assume_role_policy: fis.amazonaws.com サービスプリンシパル

aws_iam_role_policy        # cel-fis-execution-policy（インラインポリシー）
  Statement:
    - Effect: Allow
      Action:
        - ssm:SendCommand         # EC2 に stress-ng コマンドを送信
        - ssm:GetCommandInvocation  # コマンド実行状態の確認
        - ssm:ListCommands
        - ssm:CancelCommand       # FIS 停止時のクリーンアップ
      Resource: "*"
    - Effect: Allow
      Action:
        - ec2:DescribeInstances      # FIS ターゲット EC2 を探索
        - autoscaling:DescribeAutoScalingGroups  # ASG 状態確認
        - autoscaling:DescribeAutoScalingInstances
      Resource: "*"
    - Effect: Allow
      Action:
        - logs:CreateLogGroup
        - logs:CreateLogStream
        - logs:PutLogEvents       # FIS 実験ログを CloudWatch に書き込み
        - logs:DescribeLogGroups
      Resource: "arn:aws:logs:ap-northeast-1:*:log-group:/aws/fis/*"
    - Effect: Allow
      Action:
        - cloudwatch:DescribeAlarms  # 停止条件アラームを監視
      Resource: "*"

# コメント: iam:PutPolicy / iam:CreatePolicy は意図的に除外。
# FIS ロールが IAM を操作できないよう最小権限設計。
```

`terraform/modules/iam/variables.tf`: prefix, env, tags
`terraform/modules/iam/outputs.tf`: fis_role_arn, instance_profile_name, ec2_role_arn

---

### 2. `terraform/modules/fis/main.tf`

#### 2-1. CloudWatch 停止条件アラーム

```
aws_cloudwatch_metric_alarm  # cel-{env}-fis-stop-condition
  # CPU が 90% を超えて 10 分継続したら FIS 実験を強制停止する安全弁
  alarm_name: "cel-{env}-fis-cpu-stop-condition"
  comparison_operator: GreaterThanThreshold
  evaluation_periods: 2        # 5 分 × 2 = 10 分継続
  metric_name: CPUUtilization
  namespace: AWS/EC2
  period: 300
  statistic: Average
  threshold: 90
  alarm_description: "FIS 実験停止条件: CPU 90% 超過が 10 分継続"
  # ※ アクションなし。FIS が このアラームを監視して自動停止する。
```

#### 2-2. FIS CloudWatch Logs ロググループ

```
aws_cloudwatch_log_group   # /aws/fis/cel-{env}-cpu-stress
  retention_in_days: 30   # 30 日間保持
```

#### 2-3. FIS 実験テンプレート（メインリソース）

```
aws_fis_experiment_template  # cel-{env}-cpu-stress-experiment
  description: "CPUストレス負荷によるASGスケールアウト検証"
  role_arn: var.fis_role_arn

  # 停止条件: CloudWatch アラームが ALARM 状態になったら実験停止
  stop_condition {
    source = "aws:cloudwatch:alarm"
    value  = aws_cloudwatch_metric_alarm.stop_condition.arn
  }

  # アクション: SSM ドキュメントで CPU ストレスを注入
  action {
    name      = "cpu-stress"
    action_id = "aws:ssm:send-command"

    parameter {
      key   = "documentArn"
      # AWS 提供マネージドドキュメントを使用（カスタム不要）
      value = "arn:aws:ssm:ap-northeast-1::document/AWSFIS-Run-CPU-Stress"
    }
    parameter {
      key   = "documentParameters"
      # CPU 全コアに 100% 負荷を 300 秒（5 分）注入
      value = jsonencode({
        CPU            = "0"    # 0 = 全 CPU コア対象
        Workers        = "0"    # 0 = コア数と同数のワーカー
        LoadPercent    = "100"  # 100% 負荷
        DurationSeconds = "300" # 5 分間継続
      })
    }
    parameter {
      key   = "duration"
      value = "PT5M"  # ISO 8601 形式: 5 分
    }

    # ターゲット: ASG インスタンスの 50% をランダム選択
    target {
      key   = "Instances"
      value = "asg-instances"
    }
  }

  # ターゲット定義: ASG 配下のインスタンス 50% を選択
  target {
    name           = "asg-instances"
    resource_type  = "aws:ec2:instance"
    selection_mode = "PERCENT(50)"  # インスタンスの 50% に注入

    # ASG タグでフィルタリング（正しいターゲットのみ選択）
    resource_tag {
      key   = "aws:autoscaling:groupName"
      value = var.asg_name
    }
    resource_tag {
      key   = "Project"
      value = "chaos-engineering-lab"
    }
  }

  # 実験ログ設定
  log_configuration {
    cloudwatch_logs_configuration {
      log_group_arn = "${aws_cloudwatch_log_group.fis.arn}:*"
    }
    log_schema_version = 2
  }

  tags = merge(var.tags, {
    Name = "cel-${var.env}-cpu-stress-experiment"
    # コメント: このテンプレート ID を run_experiment.sh に設定して実行
  })
```

`terraform/modules/fis/variables.tf`: prefix, env, fis_role_arn, asg_name, tags
`terraform/modules/fis/outputs.tf`:
- `experiment_template_id`
- `stop_condition_alarm_arn`
- `log_group_name`

---

### 3. `terraform/environments/dev/main.tf` 最終更新

iam / fis モジュールのコメントアウトを解除:

```hcl
module "iam" {
  source = "../../modules/iam"
  prefix = var.prefix
  env    = var.env
  tags   = local.common_tags
}

module "fis" {
  source       = "../../modules/fis"
  prefix       = var.prefix
  env          = var.env
  fis_role_arn = module.iam.fis_role_arn
  asg_name     = module.asg.asg_name
  tags         = local.common_tags

  depends_on = [module.asg, module.iam]
}
```

`outputs.tf` に追加:
- `fis_experiment_template_id` — 実験テンプレート ID（スクリプトで使用）
- `fis_role_arn`
- `stop_condition_alarm_arn`

---

## セキュリティ設計の注記（コメントとして各ファイルに記載）

```
# 多層安全弁設計:
# Layer 1: FIS 停止条件（CPU 90% × 10 分でアラームトリガー → 自動停止）
# Layer 2: FIS アクション duration PT5M（5 分で自動終了）
# Layer 3: PERCENT(50) 選択（全インスタンスへの同時注入を防止）
# Layer 4: IAM 最小権限（FIS ロールは SSM SendCommand のみ許可）
```

---

## 完了条件

- [ ] `terraform fmt` / `terraform validate` が通ること
- [ ] FIS 停止条件アラームが設定されていること
- [ ] `AWSFIS-Run-CPU-Stress` マネージドドキュメントを使用していること
- [ ] ASG タグによるターゲットフィルタリングが設定されていること
- [ ] FIS ログが CloudWatch Logs に出力される設定であること
- [ ] IAM ロールの assume_role_policy が `fis.amazonaws.com` になっていること

---

## 次フェーズへの引き継ぎ情報

Phase 4 開始時に必要な情報:
- `output.fis_experiment_template_id`: スクリプトに埋め込む
- `output.asg_name`: スケーリング確認スクリプトで使用
- `output.alb_dns_name`: ヘルスチェック確認用
- FIS ログは `/aws/fis/cel-dev-cpu-stress` に出力