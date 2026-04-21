# ✅Phase 2: Global Accelerator + ALB + Lambda + Kinesis Data Firehose の構築

## このフェーズの概要（Phase 1 の続き）

Phase 1 で以下が存在する前提：
- VPC / パブリック・プライベートサブネット / sg_alb / sg_lambda_receiver / sg_lambda_generator
- S3バケット（raw / processed / athena-results）
- IAMロール（firehose / receiver / generator / databrew / scheduler）

このフェーズで作成するもの：
- Kinesis Data Firehose 配信ストリーム
- Lambda Receiver（HTTP受信 → Firehose PutRecord）
- Lambda Generator（ダミーリクエスト生成 → Global Accelerator HTTPS送信）
- ALB（Lambda Receiverをターゲットとして登録）
- AWS Global Accelerator（ALBをエンドポイントとして登録）
- EventBridge Scheduler（Generator を3分おきに起動）

---

## タスク一覧

### 1. Kinesis Data Firehose モジュール

`terraform/modules/firehose/main.tf` を作成する。

```
# resource: aws_kinesis_firehose_delivery_stream
# name: "${var.name_prefix}-delivery-stream"
# destination: "extended_s3"
#
# extended_s3_configuration:
#   role_arn: var.firehose_role_arn
#   bucket_arn: var.raw_bucket_arn
#   prefix: "logs/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/"
#   error_output_prefix: "errors/year=!{timestamp:yyyy}/month=!{timestamp:MM}/!{firehose:error-output-type}/"
#   # 日本語コメント: Hive形式パーティションプレフィックスを使うことで
#   # Athenaのパーティションプロジェクション機能と相性が良くなる
#
#   buffering_size: 5（MB）
#   buffering_interval: 60（秒）
#   # 日本語コメント: どちらか先に達したらS3に書き込む。
#   # 60秒バッファでほぼリアルタイムに近いデータ到達を実現
#
#   compression_format: "UNCOMPRESSED"
#   # 日本語コメント: Raw層はあえて非圧縮NDJSONで保存
#   # DataBrewが読みやすく、デバッグ時に中身を直接確認できる
#
#   cloudwatch_logging_options:
#     enabled: true
#     log_group_name: "/aws/kinesisfirehose/${var.name_prefix}-delivery-stream"
#     log_stream_name: "S3Delivery"
#
# server_side_encryption:
#   enabled: true
#   key_type: "AWS_OWNED_CMK"
#   # 日本語コメント: S3バケット側暗号化に加えてFirehose転送中も暗号化
```

---

### 2. Lambda Receiver のソースコード

`terraform/modules/lambda_receiver/src/receiver.py` を作成する。

```python
# 要件:
# - AWS Lambda Powertools (Logger) 使用
# - ALBからのイベントを受け取るLambda（ALB Lambda integration形式）
# - リクエストをパースして構造化JSONログを生成し Firehose に PutRecord
#
# 受け取るALBイベントから抽出するフィールド:
#   - request_id: str（uuid4で生成。ALBにはリクエストIDがないため自前生成）
#   - timestamp: str（datetime.utcnow().isoformat()）
#   - source_ip: str（event["headers"]["x-forwarded-for"] から取得）
#   - source_region: str（event["headers"]["x-forwarded-for"] のIPからダミーマッピング）
#     ※ IPを実際にGeolookupせず、末尾オクテットで "us-east-1"|"eu-west-1"|"ap-northeast-1"|"ap-southeast-1" に割り当て
#   - method: str（event["httpMethod"]）
#   - path: str（event["path"]）
#   - status_code: int（後述のレスポンスコード）
#   - latency_ms: int（Lambda開始から処理完了までをtime.time()で計測）
#   - user_agent: str（event["headers"]["user-agent"]、なければ "unknown"）
#   - accelerator_ip: str（event["headers"]["x-forwarded-for"] の最後のIP）
#   - edge_location: str（X-Amz-Cf-Id ヘッダーがあれば "NRT" など、なければ "UNKNOWN"）
#
# Firehose送信:
#   - boto3 client: firehose
#   - DeliveryStreamName: 環境変数 FIREHOSE_STREAM_NAME から取得
#   - Data: json.dumps(log_record) + "\n"（NDJSON形式。末尾改行必須）
#   # 日本語コメント: Firehoseは改行区切りでS3に書き込むためレコード末尾に\nが必須
#
# レスポンス:
#   - 正常: statusCode=200, body={"status": "ok", "request_id": "..."}
#   - エラー: statusCode=500, body={"status": "error", "message": "..."}
#
# エラーハンドリング:
#   - Firehose送信失敗はCloudWatch Logsに記録してStatusCode=500を返す
#   - Lambda Powertoolsの構造化ログで全フィールドを記録
```

`terraform/modules/lambda_receiver/main.tf` を作成する。

```
# [1] Lambda関数
# function_name: "${var.name_prefix}-receiver"
# runtime: python3.12
# handler: receiver.lambda_handler
# architectures: ["arm64"]
# timeout: 30
# memory_size: 256
# role: var.receiver_role_arn
# vpc_config: プライベートサブネット + sg_lambda_receiver
# environment:
#   FIREHOSE_STREAM_NAME: var.firehose_stream_name
#   POWERTOOLS_SERVICE_NAME: "http-receiver"
#   LOG_LEVEL: "INFO"
# # 日本語コメント: ReceiverはALBから同期呼び出しされるためtimeout=30sで十分
#
# [2] Lambda Permission（ALBからの呼び出し許可）
# resource: aws_lambda_permission
# statement_id: "AllowALBInvoke"
# action: "lambda:InvokeFunction"
# principal: "elasticloadbalancing.amazonaws.com"
# source_arn: var.alb_target_group_arn
#
# [3] CloudWatch Log Group
# name: "/aws/lambda/${var.name_prefix}-receiver"
# retention_in_days: 7
```

---

### 3. Lambda Generator のソースコード

`terraform/modules/lambda_generator/src/generator.py` を作成する。

```python
# 要件:
# - AWS Lambda Powertools (Logger) 使用
# - 1回の実行でダミーHTTPリクエストを50件生成してGlobal AcceleratorエンドポイントにHTTPS送信
#
# ダミーリクエストのバリエーション:
#   - method: GET（60%）/ POST（30%）/ DELETE（10%）
#   - path: "/api/users" | "/api/products" | "/api/orders" | "/health"（ランダム）
#   - user_agent: 3種類をランダム選択
#     "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
#     "python-requests/2.31.0"
#     "curl/7.88.1"
#   - source_ip_hint: ヘッダーに X-Simulated-Region を付与して送信元リージョンを示す
#     "us-east-1" | "eu-west-1" | "ap-northeast-1" | "ap-southeast-1"（ランダム）
#
# 送信:
#   - ライブラリ: urllib.request（標準ライブラリのみ。外部依存なし）
#   - エンドポイント: 環境変数 ACCELERATOR_ENDPOINT から取得（例: https://xxxxx.awsglobalaccelerator.com）
#   - タイムアウト: 10秒
#   - 送信間隔: time.sleep(0.1) でスロットリング（連続50リクエストを緩やかに送信）
#
# 結果集計:
#   - 成功件数・失敗件数・ステータスコード別カウントをLambda Powertoolsでログ出力
#   - 平均レイテンシ（送信〜レスポンスまでの時間）もログに記録
#   # 日本語コメント: Global Acceleratorのレイテンシ改善効果をこの値で可視化できる
```

`terraform/modules/lambda_generator/main.tf` を作成する。

```
# [1] Lambda関数
# function_name: "${var.name_prefix}-generator"
# runtime: python3.12
# handler: generator.lambda_handler
# architectures: ["arm64"]
# timeout: 120（50リクエスト × 最大10秒 = 余裕を持って120秒）
# memory_size: 128（軽量なため）
# role: var.generator_role_arn
# vpc_config: プライベートサブネット + sg_lambda_generator
# environment:
#   ACCELERATOR_ENDPOINT: var.accelerator_endpoint（後でPhase 2内で更新）
#   POWERTOOLS_SERVICE_NAME: "request-generator"
#   LOG_LEVEL: "INFO"
#
# [2] EventBridge Scheduler（3分おき）
# resource: aws_scheduler_schedule
# name: "${var.name_prefix}-generator-schedule"
# schedule_expression: "rate(3 minutes)"
# flexible_time_window: mode = "OFF"
# target:
#   arn: Lambda関数ARN
#   role_arn: var.scheduler_role_arn
# # 日本語コメント: 3分ごとに50件 = 1時間で約1,000件のログが蓄積される
#
# [3] CloudWatch Log Group
# name: "/aws/lambda/${var.name_prefix}-generator"
# retention_in_days: 7
```

---

### 4. ALB モジュール

`terraform/modules/alb/main.tf` を作成する。

```
# [1] Application Load Balancer
# resource: aws_lb
# name: "${var.name_prefix}-alb"
# internal: false（Global Acceleratorはパブリックに公開されたALBをエンドポイントにする）
# load_balancer_type: "application"
# security_groups: [sg_alb.id]
# subnets: パブリックサブネット2つ
# # 日本語コメント: Global Acceleratorのエンドポイントとして登録するためALBはパブリック配置
# # ただし実際のトラフィックはAWSグローバルネットワーク経由でALBに到達する
#
# [2] ALB Target Group（Lambda Receiver）
# resource: aws_lb_target_group
# name: "${var.name_prefix}-receiver-tg"
# target_type: "lambda"
# # 日本語コメント: target_type="lambda" の場合はport/protocolの指定は不要
#
# [3] ALB Target Group Attachment
# resource: aws_lb_target_group_attachment
# target_id: lambda_receiver関数のARN
# # depends_on: [aws_lambda_permission.allow_alb]
#
# [4] ALB Listener（HTTPS:443）
# resource: aws_lb_listener
# load_balancer_arn: alb.arn
# port: 443
# protocol: "HTTPS"
# ssl_policy: "ELBSecurityPolicy-TLS13-1-2-2021-06"
# certificate_arn: var.acm_certificate_arn
# # ⚠️ 注意: HTTPS Listenerには ACM 証明書が必要
# # ハンズオン簡略化のため、certificate_arnがnullの場合はHTTP:80 Listenerにフォールバックする設定を追加
# # 変数 use_https: bool（default=false）で切り替え可能にする
# # use_https=falseの場合はport=80, protocol=HTTP で Listener を作成
# # # 日本語コメント: 本番環境では必ずHTTPSを使用すること。ハンズオンではHTTPで代替可
#
# default_action:
#   type: "forward"
#   target_group_arn: target_group.arn
#
# [5] ALB Listener（HTTP:80 → HTTPSリダイレクト）※ use_https=true の場合のみ
# resource: aws_lb_listener（count = var.use_https ? 1 : 0）
# port: 80
# action: redirect to 443
```

---

### 5. Global Accelerator モジュール

`terraform/modules/global_accelerator/main.tf` を作成する。

```
# [1] Global Accelerator
# resource: aws_globalaccelerator_accelerator
# name: "${var.name_prefix}-accelerator"
# ip_address_type: "IPV4"
# enabled: true
# attributes:
#   flow_logs_enabled: true
#   flow_logs_s3_bucket: var.raw_bucket_name
#   flow_logs_s3_prefix: "global-accelerator-flow-logs/"
#   # 日本語コメント: Global Acceleratorのフローログを有効化することで
#   # エッジロケーション別のトラフィック分析が可能になる
#
# [2] Listener
# resource: aws_globalaccelerator_listener
# accelerator_arn: accelerator.arn
# client_affinity: "NONE"（ステートレスAPIのため不要）
# protocol: "TCP"
# port_range:
#   from_port: 80
#   to_port: 443
# # 日本語コメント: TCPプロトコルでHTTP(80)とHTTPS(443)両方を受け付ける
#
# [3] Endpoint Group
# resource: aws_globalaccelerator_endpoint_group
# listener_arn: listener.arn
# endpoint_group_region: "ap-northeast-1"
# traffic_dial_percentage: 100
# health_check_path: "/health"
# health_check_protocol: "HTTP"
# health_check_interval_seconds: 30
# threshold_count: 3
# endpoint_configuration:
#   - endpoint_id: var.alb_arn
#     weight: 100
#     client_ip_preservation_enabled: true
#     # 日本語コメント: client_ip_preservation=trueにすることで
#     # ALB・Lambdaでクライアント元IPを確認できる（X-Forwarded-Forヘッダー）

# outputs.tf に以下を出力:
# - accelerator_dns_name（Lambda GeneratorのACCELERATOR_ENDPOINTに使用）
# - accelerator_ip_sets（静的IPアドレス2つ）
```

---

### 6. ルートモジュール呼び出し・依存関係

`terraform/main.tf` に全モジュール呼び出しを記述する（順序通り）。

```hcl
# module "firehose"（s3, iamに依存）
# module "lambda_receiver"（networking, firehoseに依存）
# module "alb"（networking, lambda_receiverに依存）
# module "global_accelerator"（albに依存）
# module "lambda_generator"（networking, global_acceleratorに依存）
#   ※ ACCELERATOR_ENDPOINT = "https://${module.global_accelerator.accelerator_dns_name}"
```

---

### 7. ビルドスクリプト

`scripts/build_lambda.sh` を作成する。

```bash
#!/bin/bash
# Lambdaデプロイパッケージのビルドスクリプト
# receiver と generator 両方をビルドする
#
# receiver:
#   pip install aws-lambda-powertools boto3 -t receiver_pkg/
#   cp src/receiver.py receiver_pkg/
#   cd receiver_pkg && zip -r ../receiver.zip .
#
# generator:
#   aws-lambda-powertools のみ（boto3はランタイム組み込み）
#   urllib.request は標準ライブラリのため追加インストール不要
#   cp src/generator.py generator_pkg/
#   pip install aws-lambda-powertools -t generator_pkg/
#   cd generator_pkg && zip -r ../generator.zip .
#
# 注意: arm64環境でビルドすること
# macOSの場合: docker run --platform linux/arm64 python:3.12-slim で実行推奨
```

---

## 完了条件

- [ ] `terraform validate` / `terraform fmt` がクリーン
- [ ] Global Accelerator が `DEPLOYED` 状態になる（5〜10分かかる）
- [ ] ALB が `active` 状態・ヘルスチェック `/health` が200を返す
- [ ] Lambda Generator を手動実行してログに「成功:50件」が出る
- [ ] S3 Raw バケットに `/logs/year=.../` プレフィックスでNDJSONが蓄積される（Firehoseバッファ経過後）
- [ ] Global Accelerator の静的IPアドレス2つが `terraform output` で確認できる

## ⚠️ Global Accelerator のコスト注意

Global Accelerator は **有効化した瞬間から課金**（$0.025/時 ≒ $18/月）が始まる。
ハンズオン完了後は速やかに `terraform destroy` を実行すること。