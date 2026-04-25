# ✅Phase5: CloudWatch Agent + Dashboard + Alarm

## Phaseサマリー（前Phaseまでの状態）
Phase1-4完了済み:
- インフラ全体稼働中（VPC / EC2 / ALB / Flask API）
- GitHub Actions OIDC CI/CD稼働中
- EC2のIAM RoleにCloudWatchAgentServerPolicy付与済み（Phase2で先行付与）
- ALBヘルスチェックHealthy

## このPhaseの目的
CloudWatch Agentでカスタムメトリクス収集、ダッシュボードで可視化、
Alarmでアラート通知を構築してプロダクションレディな監視基盤を完成させる。

---

## Task 1: CloudWatch Agent設定をSSM Parameter Storeに保存（Terraform）

`terraform/modules/cloudwatch/main.tf` を新規作成:

### SSM Parameter Store にAgent設定を格納

```hcl
# CloudWatch Agent設定をSSM Parameter Storeで一元管理
resource "aws_ssm_parameter" "cw_agent_config" {
  name  = "/tap/${var.environment}/cloudwatch-agent/config"
  type  = "String"
  value = jsonencode({
    agent = {
      metrics_collection_interval = 60
      run_as_user                 = "root"
    }
    metrics = {
      namespace = "TerraformAnsiblePlatform/${var.environment}"
      metrics_collected = {
        # CPU詳細メトリクス（EC2デフォルトにないidle/steal等）
        cpu = {
          measurement                 = ["cpu_usage_idle", "cpu_usage_user", "cpu_usage_system"]
          metrics_collection_interval = 60
          totalcpu                    = true
        }
        # メモリ使用率（EC2デフォルトでは取れない）
        mem = {
          measurement = ["mem_used_percent", "mem_available_percent"]
        }
        # ディスク使用率
        disk = {
          measurement              = ["used_percent", "inodes_free"]
          metrics_collection_interval = 60
          resources                = ["/"]
        }
        # ネットワーク
        net = {
          measurement = ["bytes_sent", "bytes_recv", "packets_sent", "packets_recv"]
          resources   = ["eth0"]
        }
      }
    }
    logs = {
      logs_collected = {
        files = {
          collect_list = [
            {
              # Nginxアクセスログ
              file_path        = "/var/log/nginx/access.log"
              log_group_name   = "/tap/${var.environment}/nginx/access"
              log_stream_name  = "{instance_id}"
              timestamp_format = "%d/%b/%Y:%H:%M:%S %z"
            },
            {
              # Nginxエラーログ
              file_path        = "/var/log/nginx/error.log"
              log_group_name   = "/tap/${var.environment}/nginx/error"
              log_stream_name  = "{instance_id}"
            },
            {
              # Flaskアプリログ（journald経由）
              file_path        = "/var/log/flask-app.log"
              log_group_name   = "/tap/${var.environment}/flask-app"
              log_stream_name  = "{instance_id}"
            }
          ]
        }
      }
    }
  })

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
```

### CloudWatch Log Groups（保持期間付き）

```hcl
# ログコスト削減のため保持期間を設定
resource "aws_cloudwatch_log_group" "nginx_access" {
  name              = "/tap/${var.environment}/nginx/access"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "nginx_error" {
  name              = "/tap/${var.environment}/nginx/error"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "flask_app" {
  name              = "/tap/${var.environment}/flask-app"
  retention_in_days = 14
}
```

---

## Task 2: AnsibleでCloudWatch Agentインストール

`ansible/roles/` に `cloudwatch_agent` ロールを追加:

### roles/cloudwatch_agent/tasks/main.yml

```yaml
---
# CloudWatch Agent インストール・設定

- name: CloudWatch Agentパッケージのインストール
  ansible.builtin.dnf:
    name: amazon-cloudwatch-agent
    state: present

- name: SSM Parameter StoreからAgent設定を取得
  # AWS CLIでParameter Storeから設定を取得してローカルに保存
  ansible.builtin.command:
    cmd: >
      aws ssm get-parameter
      --name "/tap/{{ env }}/cloudwatch-agent/config"
      --region ap-northeast-1
      --query "Parameter.Value"
      --output text
  register: cw_agent_config
  changed_when: false

- name: Agent設定ファイルを配置
  ansible.builtin.copy:
    content: "{{ cw_agent_config.stdout }}"
    dest: /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
    owner: root
    group: root
    mode: '0644'
  notify: restart cloudwatch agent

- name: CloudWatch Agentを有効化・起動
  ansible.builtin.systemd:
    name: amazon-cloudwatch-agent
    enabled: true
    state: started

- name: Agent起動確認（30秒待機してメトリクス送信を確認）
  ansible.builtin.uri:
    url: "http://localhost/"
    status_code: 200
  register: health
  until: health.status == 200
  retries: 5
  delay: 10
```

### roles/cloudwatch_agent/handlers/main.yml

```yaml
---
- name: restart cloudwatch agent
  ansible.builtin.systemd:
    name: amazon-cloudwatch-agent
    state: restarted
```

### site.yml に cloudwatch_agent ロールを追加

```yaml
roles:
  - common
  - nginx
  - flask_app
  - cloudwatch_agent  # 追加
```

---

## Task 3: CloudWatch Dashboard（Terraform）

`terraform/modules/cloudwatch/main.tf` にダッシュボードを追加:

```hcl
# 統合監視ダッシュボード
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "tap-${var.environment}-overview"

  dashboard_body = jsonencode({
    widgets = [
      # ALBリクエスト数
      {
        type = "metric"
        properties = {
          title  = "ALB Request Count"
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount",
              "LoadBalancer", var.alb_arn_suffix]
          ]
        }
      },
      # ALBレイテンシ
      {
        type = "metric"
        properties = {
          title  = "ALB Target Response Time (p99)"
          period = 60
          stat   = "p99"
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime",
              "LoadBalancer", var.alb_arn_suffix]
          ]
        }
      },
      # EC2 CPUカスタムメトリクス
      {
        type = "metric"
        properties = {
          title  = "EC2 CPU Usage (%)"
          period = 60
          stat   = "Average"
          metrics = [
            ["TerraformAnsiblePlatform/${var.environment}",
              "cpu_usage_user", "host", "tap-dev-app-01"],
            ["TerraformAnsiblePlatform/${var.environment}",
              "cpu_usage_user", "host", "tap-dev-app-02"]
          ]
        }
      },
      # メモリ使用率（カスタムメトリクス）
      {
        type = "metric"
        properties = {
          title  = "Memory Used (%)"
          period = 60
          stat   = "Average"
          metrics = [
            ["TerraformAnsiblePlatform/${var.environment}",
              "mem_used_percent", "host", "tap-dev-app-01"],
            ["TerraformAnsiblePlatform/${var.environment}",
              "mem_used_percent", "host", "tap-dev-app-02"]
          ]
        }
      },
      # 5xx エラー数
      {
        type = "metric"
        properties = {
          title  = "ALB 5XX Errors"
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count",
              "LoadBalancer", var.alb_arn_suffix]
          ]
        }
      },
      # Unhealthyホスト数
      {
        type = "metric"
        properties = {
          title  = "Unhealthy Host Count"
          period = 60
          stat   = "Maximum"
          metrics = [
            ["AWS/ApplicationELB", "UnHealthyHostCount",
              "TargetGroup", var.target_group_arn_suffix,
              "LoadBalancer", var.alb_arn_suffix]
          ]
        }
      }
    ]
  })
}
```

---

## Task 4: CloudWatch Alarms + SNS通知

```hcl
# SNSトピック（メール通知）
resource "aws_sns_topic" "alerts" {
  name = "tap-${var.environment}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# 高CPU Alarm
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "tap-${var.environment}-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "cpu_usage_user"
  namespace           = "TerraformAnsiblePlatform/${var.environment}"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "EC2 CPU使用率が80%を3分間超えた"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# ALB 5xxエラー急増Alarm
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "tap-${var.environment}-alb-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  treat_missing_data  = "notBreaching"
  alarm_description   = "ALBで1分間に5xxエラーが10件を超えた"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }
}

# UnhealthyホストAlarm
resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "tap-${var.environment}-unhealthy-hosts"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "ALB Target Groupにunhealthyなホストが存在する"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    TargetGroup  = var.target_group_arn_suffix
    LoadBalancer = var.alb_arn_suffix
  }
}
```

---

## Task 5: Ansible + Terraform 再実行

```bash
# Terraform: Log Groups + Dashboard + Alarm + SSM Parameter を作成
cd terraform/environments/dev
terraform apply

# Ansible: cloudwatch_agentロールを追加してプロビジョニング
cd ansible
ansible-playbook site.yml --tags cloudwatch_agent

# Agent動作確認（EC2内でSSM接続して実行）
aws ssm start-session --target <instance_id>
# SSMセッション内:
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a status
```

---

## 完了基準

- [ ] CloudWatchコンソールで `TerraformAnsiblePlatform/dev` カスタム名前空間のメトリクスが表示される
- [ ] `mem_used_percent` がEC2 2台分表示される
- [ ] Dashboardに6つのウィジェットが表示される
- [ ] Nginxアクセスログが `/tap/dev/nginx/access` ロググループに流れている
- [ ] SNSメールサブスクリプションを確認済み（メールのConfirmリンクをクリック）
- [ ] ALBに意図的に大量リクエストを送り、Dashboardでグラフが動くことを確認

---

## ハンズオン完了後のクリーンアップ

```bash
# コスト発生を止める（逆順でdestroy）
cd terraform/environments/dev
terraform destroy

cd ../bootstrap
terraform destroy
```

**NAT Gateway（~$5/日）とALB（~$0.6/日）が最大コスト要因なので即destroyを推奨**