# ✅Phase 3 — FIS 3シナリオ実験テンプレート + Lambda（シナリオ3用）

## 前フェーズ（Phase 1-2）の成果物

Phase 1:
- `modules/vpc/` — VPC 10.1.0.0/16 / サブネット / IGW / NAT GW
- `modules/sg/` — ALB SG / ECS Task SG
- `modules/ecr/` — ecl-dev-nginx リポジトリ
- `modules/alb/` — ALB / TG (target_type="ip") / HTTP:80 Listener

Phase 2:
- `modules/iam/` — FIS 実行ロール(ecl-fis-exec-role) / Task 実行ロール / Task ロール
- `modules/ecs/` — Cluster(ecl-dev-cluster) / TD / Service(desired=2, awsvpc) / CW アラーム×2
- `scripts/bootstrap.sh` — ECR イメージプッシュ済みを想定

## このフェーズのゴール

生成するファイル:
- `terraform/modules/fis/main.tf` — 3シナリオの FIS 実験テンプレート
- `terraform/modules/fis/lambda.tf` — シナリオ3用 Lambda（DesiredCount 変更）
- `terraform/modules/fis/lambda_src/desired_count_changer.py`
- `terraform/environments/dev/main.tf` の fis モジュールを有効化

---

## 生成指示

### 1. `terraform/modules/fis/lambda_src/desired_count_changer.py`

```python
"""
FIS シナリオ3用 Lambda: ECS Service の DesiredCount を変更する
FIS から aws:lambda:invoke アクションで呼び出される

環境変数:
  CLUSTER_NAME: ECS クラスター名
  SERVICE_NAME: ECS サービス名
  TARGET_COUNT: 変更後の desired count（デフォルト: 0）
  RESTORE_COUNT: 復元後の desired count（デフォルト: 2）

イベント構造:
  {"action": "set_zero" | "restore"}
"""
import boto3
import os
import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ecs = boto3.client("ecs", region_name="ap-northeast-1")

CLUSTER_NAME = os.environ["CLUSTER_NAME"]
SERVICE_NAME = os.environ["SERVICE_NAME"]
TARGET_COUNT = int(os.environ.get("TARGET_COUNT", "0"))
RESTORE_COUNT = int(os.environ.get("RESTORE_COUNT", "2"))


def lambda_handler(event, context):
    action = event.get("action", "set_zero")
    logger.info(f"アクション: {action}, クラスター: {CLUSTER_NAME}, サービス: {SERVICE_NAME}")

    if action == "set_zero":
        # シナリオ3: DesiredCount を 0 に変更（全 Task 停止）
        desired = TARGET_COUNT
        logger.info(f"DesiredCount を {desired} に変更（全 Task 停止）")
    elif action == "restore":
        # FIS 実験終了後の復旧: DesiredCount を元に戻す
        desired = RESTORE_COUNT
        logger.info(f"DesiredCount を {desired} に復元")
    else:
        raise ValueError(f"不明なアクション: {action}")

    response = ecs.update_service(
        cluster=CLUSTER_NAME,
        service=SERVICE_NAME,
        desiredCount=desired,
        forceNewDeployment=False,
    )

    current = response["service"]["desiredCount"]
    logger.info(f"更新完了: desiredCount = {current}")

    return {
        "statusCode": 200,
        "body": json.dumps({
            "action": action,
            "cluster": CLUSTER_NAME,
            "service": SERVICE_NAME,
            "desiredCount": current,
        }),
    }
```

### 2. `terraform/modules/fis/lambda.tf`

#### Lambda 実行ロール

```hcl
# シナリオ3 Lambda が ECS Service を更新するための最小権限ロール
resource "aws_iam_role" "lambda_desired_count" {
  name = "${var.prefix}-lambda-desired-count-role"

  assume_role_policy = jsonencode({
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda_desired_count" {
  name = "${var.prefix}-lambda-desired-count-policy"
  role = aws_iam_role.lambda_desired_count.id

  policy = jsonencode({
    Statement = [
      {
        # ECS Service の DesiredCount 変更のみ許可
        Effect   = "Allow"
        Action   = ["ecs:UpdateService", "ecs:DescribeServices"]
        Resource = "arn:aws:ecs:${var.aws_region}:${var.account_id}:service/${var.cluster_name}/${var.service_name}"
      },
      {
        # Lambda ログ書き込み
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/aws/lambda/${var.prefix}-desired-count-changer:*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_desired_count.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
```

#### Lambda 関数

```hcl
# コメント: lambda_src/ をその場で zip 化して Lambda にデプロイ。
# ECR/S3 不要でシンプルな構成。FIS 専用の小さな関数のため inline zip で十分。
data "archive_file" "desired_count_changer" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_src"
  output_path = "${path.module}/.lambda_build/desired_count_changer.zip"
}

resource "aws_lambda_function" "desired_count_changer" {
  function_name = "${var.prefix}-desired-count-changer"
  role          = aws_iam_role.lambda_desired_count.arn
  runtime       = "python3.12"
  handler       = "desired_count_changer.lambda_handler"
  filename      = data.archive_file.desired_count_changer.output_path
  source_code_hash = data.archive_file.desired_count_changer.output_base64sha256
  timeout       = 30
  architectures = ["arm64"]  # コスト最適化（Graviton2）

  environment {
    variables = {
      CLUSTER_NAME  = var.cluster_name
      SERVICE_NAME  = var.service_name
      TARGET_COUNT  = "0"
      RESTORE_COUNT = "2"
    }
  }

  tags = var.tags
}

# FIS が Lambda を invoke できるようリソースベースポリシーを追加
resource "aws_lambda_permission" "fis_invoke" {
  statement_id  = "AllowFISInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.desired_count_changer.function_name
  principal     = "fis.amazonaws.com"
  source_arn    = "arn:aws:fis:${var.aws_region}:${var.account_id}:experiment-template/*"
}
```

---

### 3. `terraform/modules/fis/main.tf` — FIS 実験テンプレート × 3

#### 共通: FIS CloudWatch Logs グループ

```hcl
resource "aws_cloudwatch_log_group" "fis" {
  name              = "/aws/fis/${var.prefix}-${var.env}"
  retention_in_days = 30
}
```

#### シナリオ1: Task 強制停止

```hcl
resource "aws_fis_experiment_template" "task_kill" {
  description = "【シナリオ1】ECS Task の強制停止 → Service 自己回復確認"
  role_arn    = var.fis_role_arn

  # 停止条件: RunningTaskCount < 1 が 5 分継続（全 Task 停止 = 実験失敗とみなす）
  stop_condition {
    source = "aws:cloudwatch:alarm"
    value  = var.stop_condition_task_kill_arn
  }

  action {
    name      = "stop-ecs-tasks"
    action_id = "aws:ecs:stop-task"

    parameter {
      key   = "cluster"
      value = var.cluster_arn
    }

    # コメント: PERCENT(100) で全 Task を停止し、Service の自己回復速度を計測する。
    # ECS Service は desired_count=2 を維持しようと即座に新 Task を起動するはず。
    target {
      key   = "Tasks"
      value = "all-running-tasks"
    }
  }

  target {
    name           = "all-running-tasks"
    resource_type  = "aws:ecs:task"
    selection_mode = "PERCENT(100)"

    resource_tag {
      key   = "aws:ecs:clusterName"
      value = var.cluster_name
    }
    resource_tag {
      key   = "aws:ecs:serviceName"
      value = var.service_name
    }
  }

  log_configuration {
    cloudwatch_logs_configuration {
      log_group_arn = "${aws_cloudwatch_log_group.fis.arn}:*"
    }
    log_schema_version = 2
  }

  tags = merge(var.tags, {
    Name     = "${var.prefix}-${var.env}-scenario1-task-kill"
    Scenario = "task-kill"
  })
}
```

#### シナリオ2: ネットワーク遮断

```hcl
resource "aws_fis_experiment_template" "network_disruption" {
  description = "【シナリオ2】ECS Task のネットワーク遮断 → ALB Unhealthy 確認"
  role_arn    = var.fis_role_arn

  # 停止条件: HealthyHostCount = 0 が 3 分継続（全断 = 即座に停止）
  stop_condition {
    source = "aws:cloudwatch:alarm"
    value  = var.stop_condition_network_arn
  }

  action {
    name      = "disrupt-task-network"
    # コメント: Fargate Task の ENI に対してインバウンド TCP:80 を遮断する。
    # EC2 の aws:network:disrupt-connectivity とは異なる ECS 専用アクション。
    # awsvpc ネットワークモードが前提（ENI が Task に直接アタッチされているため）。
    action_id = "aws:ecs:task-network-blackhole-port"

    parameter {
      key   = "trafficType"
      value = "ingress"  # インバウンドのみ遮断（ALB → Task のトラフィック）
    }
    parameter {
      key   = "port"
      value = "80"
    }
    parameter {
      key   = "protocol"
      value = "tcp"
    }
    parameter {
      key   = "duration"
      value = "PT3M"  # 3分間遮断（ALB ヘルスチェック失敗 → Unhealthy を観測）
    }

    target {
      key   = "Tasks"
      value = "running-tasks-50pct"
    }
  }

  target {
    name           = "running-tasks-50pct"
    resource_type  = "aws:ecs:task"
    # コメント: 全 Task を遮断すると完全断になるため 50% に絞る。
    # 残り 50% は正常稼働し、ALB が Unhealthy Task を切り離す動作を確認する。
    selection_mode = "PERCENT(50)"

    resource_tag {
      key   = "aws:ecs:clusterName"
      value = var.cluster_name
    }
    resource_tag {
      key   = "aws:ecs:serviceName"
      value = var.service_name
    }
  }

  log_configuration {
    cloudwatch_logs_configuration {
      log_group_arn = "${aws_cloudwatch_log_group.fis.arn}:*"
    }
    log_schema_version = 2
  }

  tags = merge(var.tags, {
    Name     = "${var.prefix}-${var.env}-scenario2-network"
    Scenario = "network-disruption"
  })
}
```

#### シナリオ3: DesiredCount 0 → 復旧

```hcl
resource "aws_fis_experiment_template" "desired_zero" {
  description = "【シナリオ3】ECS DesiredCount=0 による全 Task 停止 → 手動復旧確認"
  role_arn    = var.fis_role_arn

  # コメント: DesiredCount=0 は意図的なゼロスケールのため FIS 停止条件は設定しない。
  # 実験者が手動で restore アクション（Lambda 経由）を実行して復旧を確認する。
  stop_condition {
    source = "none"
  }

  action {
    name      = "set-desired-count-zero"
    # コメント: FIS ネイティブには ECS DesiredCount 変更アクションがないため
    # Lambda を FIS アクションとして使用する（aws:lambda:invoke）。
    action_id = "aws:lambda:invoke"

    parameter {
      key   = "functionArn"
      value = aws_lambda_function.desired_count_changer.arn
    }
    parameter {
      key   = "payload"
      # {"action": "set_zero"} を Base64 エンコード
      value = base64encode(jsonencode({ action = "set_zero" }))
    }
    parameter {
      key   = "invocationType"
      value = "sync"  # 同期実行（結果を FIS ログに記録）
    }
  }

  log_configuration {
    cloudwatch_logs_configuration {
      log_group_arn = "${aws_cloudwatch_log_group.fis.arn}:*"
    }
    log_schema_version = 2
  }

  tags = merge(var.tags, {
    Name     = "${var.prefix}-${var.env}-scenario3-desired-zero"
    Scenario = "desired-zero"
  })
}
```

`terraform/modules/fis/variables.tf`:
- prefix, env, aws_region, account_id
- fis_role_arn
- cluster_name, cluster_arn
- service_name
- stop_condition_task_kill_arn
- stop_condition_network_arn
- tags

`terraform/modules/fis/outputs.tf`:
- `scenario1_template_id` = aws_fis_experiment_template.task_kill.id
- `scenario2_template_id` = aws_fis_experiment_template.network_disruption.id
- `scenario3_template_id` = aws_fis_experiment_template.desired_zero.id
- `lambda_function_name` = aws_lambda_function.desired_count_changer.function_name
- `fis_log_group_name` = aws_cloudwatch_log_group.fis.name

---

### 4. `terraform/environments/dev/main.tf` 最終更新

fis モジュールのコメントアウトを解除:

```hcl
module "fis" {
  source                       = "../../modules/fis"
  prefix                       = var.prefix
  env                          = var.env
  aws_region                   = var.aws_region
  account_id                   = var.account_id
  fis_role_arn                 = module.iam.fis_role_arn
  cluster_name                 = module.ecs.cluster_name
  cluster_arn                  = module.ecs.cluster_arn
  service_name                 = module.ecs.service_name
  stop_condition_task_kill_arn = module.ecs.stop_condition_alarm_task_kill_arn
  stop_condition_network_arn   = module.ecs.stop_condition_alarm_network_arn
  tags                         = local.common_tags

  depends_on = [module.ecs, module.iam]
}
```

`outputs.tf` に追加:
- `scenario1_template_id`
- `scenario2_template_id`
- `scenario3_template_id`
- `lambda_function_name`

---

## 完了条件

- [ ] FIS テンプレートが 3 種類生成されること
- [ ] シナリオ2の action_id が `aws:ecs:task-network-blackhole-port` であること
- [ ] シナリオ3の action_id が `aws:lambda:invoke` であること
- [ ] Lambda が `arm64` アーキテクチャで生成されること（コスト最適化）
- [ ] Lambda のタイムアウトが 30 秒以上であること
- [ ] `aws_lambda_permission` で FIS からの invoke が許可されていること
- [ ] シナリオ2の selection_mode が `PERCENT(50)` であること（全断防止）
- [ ] シナリオ3の stop_condition source が `"none"` であること
- [ ] FIS ログが `/aws/fis/ecl-dev` に出力される設定であること

---

## 次フェーズへの引き継ぎ情報

Phase 4 で使用する値（`terraform output` で取得）:
- `scenario1_template_id`: run_task_kill.sh に設定
- `scenario2_template_id`: run_network_disruption.sh に設定
- `scenario3_template_id`: run_desired_zero.sh に設定
- `lambda_function_name`: run_desired_zero.sh の復旧コマンドに使用
- `cluster_name` = `ecl-dev-cluster`
- `service_name` = `ecl-dev-service`
- `alb_dns_name`: ヘルスチェック確認用