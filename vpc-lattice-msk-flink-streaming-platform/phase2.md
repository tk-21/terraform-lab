# ✅Phase 2: MSK Serverless + Lambda Producer の構築

## このフェーズの概要（Phase 1 の続き）

Phase 1 で作成した以下のリソースが存在する前提で進める：
- VPC / プライベートサブネット / sg_msk / sg_lambda
- S3バケット（output / flink-app）
- IAMロール（streaming-flink-role / streaming-producer-role）

このフェーズで作成するもの：
- Amazon MSK Serverless クラスター
- Lambda Producer（Kafkaへのダミーデータ送信）
- EventBridge Scheduler（5分おき自動実行）

---

## タスク一覧

### 1. MSK Serverlessモジュールの作成

`terraform/modules/msk/main.tf` を作成する。

```
# [1] MSK Serverlessクラスター
# resource: aws_msk_serverless_cluster
# cluster_name: "${var.name_prefix}-msk-cluster"
# vpc_config:
#   - subnet_ids: プライベートサブネット2つ（networking moduleのoutputから）
#   - security_group_ids: [sg_msk.id]
# client_authentication:
#   sasl:
#     iam:
#       enabled: true  # IAM認証のみ許可（PLAINTEXTは禁止）
# # 日本語コメント: MSK ServerlessはブローカーレスのフルマネージドKafka
# # パーティション数・レプリケーション係数はAWS側で自動管理される
#
# [2] MSK クラスターポリシー（IAMアクセス制御）
# resource: aws_msk_cluster_policy
# cluster_arn: msk_serverlessクラスターのARN
# policy:
#   - Lambda ProducerロールにWriteDataを許可
#   - FlinkロールにReadDataを許可
#   - 両ロールにDescribeCluster, ConnectClusterを許可
#   # 日本語コメント: MSK IAM認証ではクラスターポリシーとIAMロールポリシーの両方が必要

# outputs.tf に以下を出力:
# - msk_cluster_arn
# - msk_bootstrap_brokers_sasl_iam（接続エンドポイント）
# - msk_cluster_name
```

**重要な補足 (Claude Code への指示)**:
MSK Serverless の Terraform resource は `aws_msk_serverless_cluster` を使う。
`aws_msk_cluster` (Provisioned) とは別のリソースであることに注意。

---

### 2. Lambda Producerのソースコード作成

`terraform/modules/lambda_producer/src/producer.py` を作成する。

```python
# 要件:
# - AWS Lambda Powertools (Logger) を使用
# - ランタイム: Python 3.12
# - 1回の実行で100件のダミーイベントを生成してKafkaトピックに送信
#
# ダミーイベントのスキーマ（CLAUDE.mdの仕様に準拠）:
# {
#   "event_id": str（uuid4）,
#   "timestamp": str（ISO8601: datetime.utcnow().isoformat()）,
#   "service_name": "auth" | "api" | "payment" | "notification"（ランダム）,
#   "action": "login" | "request" | "charge" | "send"（ランダム）,
#   "user_id": f"u_{random 4桁数字}",
#   "latency_ms": int（10〜500のランダム）,
#   "status": "success" | "error" | "timeout"（重み付き: 80%, 15%, 5%）,
#   "region": "ap-northeast-1"
# }
#
# Kafka送信:
# - ライブラリ: kafka-python-ng（MSK IAM認証対応）
# - ブートストラップサーバー: 環境変数 MSK_BOOTSTRAP_SERVERS から取得
# - トピック名: 環境変数 KAFKA_TOPIC から取得（default: "streaming-events"）
# - 認証: MSKAuthTokenProvider を使ったSASL/OAUTHBEARER（IAM認証）
# - 100件を1バッチで送信し、producer.flush()で確実にコミット
#
# エラーハンドリング:
# - try/exceptで送信失敗をキャッチしてCloudWatch Logsに記録
# - 全件送信後に成功件数・失敗件数をログ出力
#
# Lambda Powertools:
# - @logger.inject_lambda_context デコレーターを使用
# - 送信開始・完了・エラーを構造化ログで記録
# # 日本語コメント: Lambda Powertoolsにより構造化ログをCloudWatch Insightsで検索可能
```

`terraform/modules/lambda_producer/main.tf` を作成する。

```
# [1] Lambda Layer (依存ライブラリ)
# resource: null_resource + local-exec で
# pip install kafka-python-ng aws-lambda-powertools -t layer/python/
# してzipにする方式 OR
# 代替: Lambda Layerを使わずLambdaのソースzipに同梱する方式を採用
# → シンプルな方式として: archive_file で src/ 配下をzip化
#    ただし kafka-python-ng は pip install が必要なのでビルドスクリプト方式を推奨
# ★ ここは以下の方針で実装:
#   - scripts/build_lambda.sh でパッケージをインストールしてzipを生成
#   - terraform data "archive_file" でzipを参照
#   - コメントで「terraform apply前にscripts/build_lambda.shの実行が必要」と明記
#
# [2] Lambda関数
# resource: aws_lambda_function
# function_name: "${var.name_prefix}-producer"
# runtime: python3.12
# handler: producer.lambda_handler
# architectures: ["arm64"]  # コスト削減
# timeout: 60（100件送信には余裕が必要）
# memory_size: 256
# role: var.lambda_role_arn
# vpc_config:
#   subnet_ids: プライベートサブネット
#   security_group_ids: [sg_lambda.id]
# environment variables:
#   MSK_BOOTSTRAP_SERVERS: var.msk_bootstrap_brokers
#   KAFKA_TOPIC: "streaming-events"
#   POWERTOOLS_SERVICE_NAME: "kafka-producer"
#   LOG_LEVEL: "INFO"
# # 日本語コメント: arm64アーキテクチャはx86_64比で約20%コスト削減
#
# [3] EventBridge Scheduler（5分おき自動実行）
# resource: aws_scheduler_schedule
# name: "${var.name_prefix}-producer-schedule"
# schedule_expression: "rate(5 minutes)"
# flexible_time_window: mode = "OFF"（固定間隔）
# target:
#   arn: Lambda関数のARN
#   role_arn: EventBridge Scheduler用のIAMロール（LambdaInvokeを許可）
# # 日本語コメント: EventBridge SchedulerはEventBridge Rulesより柔軟なタイムゾーン設定が可能
#
# [4] CloudWatch Logs グループ
# resource: aws_cloudwatch_log_group
# name: "/aws/lambda/${var.name_prefix}-producer"
# retention_in_days: 7
```

---

### 3. ルートモジュールへのMSK・Lambda追加

`terraform/main.tf` に以下を追記する。

```hcl
# module "msk" を呼び出す
# 引数: name_prefix, vpc_id, subnet_ids, sg_msk_id, lambda_role_arn, flink_role_arn

# module "lambda_producer" を呼び出す
# 引数: name_prefix, lambda_role_arn, msk_bootstrap_brokers, subnet_ids, sg_lambda_id
# depends_on: [module.msk]
```

---

### 4. ビルドスクリプトの作成

`scripts/build_lambda.sh` を作成する。

```bash
#!/bin/bash
# Lambdaデプロイパッケージのビルドスクリプト
# 使い方: bash scripts/build_lambda.sh
#
# 処理内容:
# 1. terraform/modules/lambda_producer/package/ ディレクトリを作成
# 2. pip install kafka-python-ng aws-lambda-powertools -t package/
# 3. cp terraform/modules/lambda_producer/src/producer.py package/
# 4. cd package && zip -r ../lambda_producer.zip .
# 5. 完了メッセージ表示
#
# 注意: Python 3.12 + arm64 環境でビルドすること
# macOSの場合: docker run --platform linux/arm64 でビルド推奨
```

---

### 5. 動作確認手順

全ファイル作成後、README.mdに以下を追記すること：

```markdown
## Phase 2: 動作確認

### Lambda手動テスト
```bash
aws lambda invoke \
  --function-name streaming-producer \
  --payload '{}' \
  --region ap-northeast-1 \
  output.json
cat output.json
```

### MSK接続確認（踏み台不要、CloudWatch Logsで確認）
```bash
# Lambdaのログを確認
aws logs tail /aws/lambda/streaming-producer --follow
```
```

---

## 完了条件

- [ ] MSK Serverlessクラスターが `ACTIVE` 状態になる
- [ ] Lambda Producerを手動実行してエラーが出ない
- [ ] CloudWatch LogsにLambda Powertoolsの構造化ログが出力される
- [ ] MSK トピック `streaming-events` にメッセージが積まれていることをログで確認
- [ ] EventBridge Schedulerが5分おきにLambdaをトリガーしている
- [ ] `terraform plan` で変更差分がない（冪等性確認）