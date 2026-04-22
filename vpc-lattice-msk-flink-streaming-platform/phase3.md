# ✅Phase 3: VPC Lattice + Managed Apache Flink の構築

## このフェーズの概要（Phase 1〜2 の続き）

Phase 1〜2 で以下が存在する前提：
- VPC / サブネット / sg_msk / sg_flink / sg_vpc_lattice
- MSK Serverless クラスター（ACTIVE状態）
- Lambda Producer（5分おきにKafkaにデータを送信中）
- S3バケット（output / flink-app）

このフェーズで作成するもの：
- VPC Lattice Service Network + Service + Listener + Target Group
- Amazon Managed Service for Apache Flink アプリケーション
- Flink Javaアプリのソースコード

---

## タスク一覧

### 1. VPC Lattice モジュールの作成

`terraform/modules/vpc_lattice/main.tf` を作成する。

```
# [1] Service Network
# resource: aws_vpclattice_service_network
# name: "${var.name_prefix}-service-network"
# auth_type: "AWS_IAM"
# # 日本語コメント: AWS_IAMを指定することでIAMポリシーベースのL7アクセス制御が可能
# # NONE を指定すると全アクセスが許可されるため本番環境では必ず AWS_IAM を使用
#
# [2] Service Network VPC Association
# resource: aws_vpclattice_service_network_vpc_association
# service_network_identifier: service_network.id
# vpc_identifier: var.vpc_id
# security_group_ids: [sg_vpc_lattice.id]
# # 日本語コメント: VPCをService Networkに関連付けることでVPC内からLattice経由のアクセスが可能に
#
# [3] Service（MSKへのプロキシ）
# resource: aws_vpclattice_service
# name: "${var.name_prefix}-msk-service"
# auth_type: "AWS_IAM"
# # 日本語コメント: VPC Lattice Serviceは実際のバックエンド（MSK）への論理的なエントリーポイント
#
# [4] Service Network Service Association
# resource: aws_vpclattice_service_network_service_association
# service_identifier: vpclattice_service.id
# service_network_identifier: service_network.id
#
# [5] Target Group（MSK Kafkaポートへのルーティング）
# resource: aws_vpclattice_target_group
# name: "${var.name_prefix}-msk-tg"
# type: "IP"
# config:
#   port: 9098（MSK IAM認証ポート）
#   protocol: "TCP"
#   vpc_identifier: var.vpc_id
#   health_check:
#     enabled: true
#     port: 9098
#     protocol: "TCP"
# # 日本語コメント: MSK ServerlessはIPターゲットグループで接続
# # ポート9098はSASL/IAM認証用TLSポート
#
# [6] VPC Lattice Listener
# resource: aws_vpclattice_listener
# name: "${var.name_prefix}-kafka-listener"
# service_identifier: vpclattice_service.id
# protocol: "TCP"（KafkaはHTTPでなくTCP）
# port: 9098
# default_action:
#   forward:
#     target_groups:
#       - target_group_identifier: target_group.id
#         weight: 100
#
# [7] Auth Policy（Service Networkレベル）
# resource: aws_vpclattice_auth_policy
# resource_identifier: service_network.arn
# policy:
#   - Lambda ProducerロールとFlinkロールからのアクセスを許可
#   - Action: "vpc-lattice-svcs:Invoke"
#   # 日本語コメント: VPC LatticeのAuth PolicyでL7レベルの認可を制御
#   # IAMロールベースで「誰がどのサービスにアクセスできるか」を宣言的に管理
```

---

### 2. Flink Javaアプリのソースコード作成

`flink-app/src/main/java/com/example/streaming/StreamingJob.java` を作成する。

```java
// 要件:
// - Flink 1.19 + Java 17
// - Source: Kafka Consumer（MSK Serverless、SASL/IAM認証）
// - 処理: 60秒タンブリングウィンドウ集計
// - Sink: S3 FileSink（Parquet形式）
//
// Kafkaソース設定:
//   - bootstrapServers: 環境変数 BOOTSTRAP_SERVERS から取得
//   - topicName: "streaming-events"
//   - groupId: "flink-streaming-consumer"
//   - SASL/OAUTHBEARER: MSKAuthTokenProvider使用
//   - デシリアライズ: SimpleStringSchema（JSONをStringとして読み込み）
//
// 処理ロジック:
//   1. KafkaメッセージをJSONパース（Gson）
//   2. service_nameをキーにグループ化
//   3. 60秒タンブリングウィンドウで集計:
//      - total_count: イベント総数
//      - error_count: status = "error" の件数
//      - avg_latency_ms: latency_msの平均値
//      - window_start: ウィンドウ開始時刻（ISO8601）
//      - window_end: ウィンドウ終了時刻（ISO8601）
//   4. 集計結果をParquet形式でS3に書き込み
//
// S3 FileSink設定:
//   - basePath: 環境変数 OUTPUT_S3_PATH から取得
//   - bucketAssigner: DateTimeBucketAssigner("'year='yyyy/'month='MM/'day='dd/'hour='HH")
//   - bulkFormat: ParquetAvroWriters（AvroParquetWriters.forReflectRecord）
//   - rollingPolicy: OnCheckpointRollingPolicy（チェックポイント時にロール）
//
// Avroスキーマ（集計結果）:
//   ServiceMetrics {
//     String service_name;
//     long total_count;
//     long error_count;
//     double avg_latency_ms;
//     String window_start;
//     String window_end;
//   }
//
// チェックポイント設定:
//   - interval: 60000ms（60秒）
//   - mode: EXACTLY_ONCE
//   - storage: S3（環境変数 CHECKPOINT_S3_PATH）
//
// // 日本語コメント: タンブリングウィンドウはイベント時刻ではなく処理時刻（ProcessingTime）を使用
// // イベント時刻ベースにするにはウォーターマーク設定が必要（Phase 4以降の拡張候補）
```

`flink-app/pom.xml` を作成する。

```xml
<!-- 依存ライブラリ:
  - flink-streaming-java: 1.19.0
  - flink-connector-kafka: 3.2.0-1.19
  - flink-connector-aws-kinesis-streams（MSK IAM認証用）
  - flink-s3-fs-hadoop（S3 FileSink用）
  - flink-avro（Avroシリアライズ用）
  - parquet-avro: 1.13.1
  - aws-msk-iam-auth: 2.2.0（MSK IAM認証ライブラリ）
  - gson: 2.10.1（JSONパース）

  ビルド設定:
  - maven-shade-plugin でfat jarを生成
  - mainClass: com.example.streaming.StreamingJob
  - 出力: target/streaming-job-1.0.0.jar
-->
```

---

### 3. Flinkアプリのビルド・アップロードスクリプト

`scripts/build_flink_app.sh` を作成する。

```bash
#!/bin/bash
# Flinkアプリケーションのビルドとデプロイ
# 使い方: bash scripts/build_flink_app.sh <S3_BUCKET_NAME>
#
# 処理:
# 1. cd flink-app && mvn clean package -DskipTests
# 2. aws s3 cp target/streaming-job-1.0.0.jar s3://${S3_BUCKET}/flink-app/streaming-job-1.0.0.jar
# 3. アップロード成功メッセージ表示
# # 日本語コメント: -DskipTestsでテストをスキップ。CI環境では外す
```

---

### 4. Managed Apache Flinkモジュールの作成

`terraform/modules/flink/main.tf` を作成する。

```
# [1] Flink アプリケーション
# resource: aws_kinesisanalyticsv2_application
# # 注意: Managed Service for Apache Flink の Terraform リソース名は
# # aws_kinesisanalyticsv2_application（名称変更前のKinesis Analytics v2）
#
# name: "${var.name_prefix}-flink-app"
# runtime_environment: "FLINK-1_19"
# service_execution_role: var.flink_role_arn
#
# application_configuration:
#   application_code_configuration:
#     code_content:
#       s3_content_location:
#         bucket_arn: var.flink_app_bucket_arn
#         file_key: "flink-app/streaming-job-1.0.0.jar"
#     code_content_type: "ZIPFILE"  # JARファイルはZIPFILE扱い
#
#   flink_application_configuration:
#     checkpoint_configuration:
#       configuration_type: "CUSTOM"
#       checkpointing_enabled: true
#       checkpoint_interval: 60000
#       min_pause_between_checkpoints: 5000
#     monitoring_configuration:
#       configuration_type: "CUSTOM"
#       log_level: "INFO"
#       metrics_level: "APPLICATION"
#     parallelism_configuration:
#       configuration_type: "CUSTOM"
#       parallelism: 1
#       parallelism_per_kpu: 1
#       auto_scaling_enabled: false
#       # 日本語コメント: Parallelism=1でコスト最小化。1KPU = $0.11/時
#
#   vpc_configuration:
#     subnet_ids: var.private_subnet_ids
#     security_group_ids: [var.sg_flink_id]
#     # 日本語コメント: VPC内に配置してMSKへのプライベート接続を確保
#
#   environment_properties:
#     property_groups:
#       - property_group_id: "FlinkApplicationProperties"
#         property_map:
#           BOOTSTRAP_SERVERS: var.msk_bootstrap_brokers
#           OUTPUT_S3_PATH: "s3a://${var.output_bucket_name}/events/"
#           CHECKPOINT_S3_PATH: "s3a://${var.flink_app_bucket_name}/checkpoints/"
#           KAFKA_TOPIC: "streaming-events"
#
# [2] CloudWatch Log Group（Flinkログ）
# resource: aws_cloudwatch_log_group
# name: "/aws/kinesis-analytics/${var.name_prefix}-flink-app"
# retention_in_days: 7
#
# [3] CloudWatch Log Stream
# resource: aws_cloudwatch_log_stream
# name: "flink-app-log-stream"
# log_group_name: log_group.name
```

---

### 5. ルートモジュールへのVPC Lattice・Flink追加

`terraform/main.tf` に以下を追記する。

```hcl
# module "vpc_lattice" を呼び出す
# 引数: name_prefix, vpc_id, sg_vpc_lattice_id, lambda_role_arn, flink_role_arn
# depends_on: [module.msk]

# module "flink" を呼び出す
# 引数: name_prefix, flink_role_arn, flink_app_bucket_arn, flink_app_bucket_name,
#        output_bucket_name, msk_bootstrap_brokers, private_subnet_ids, sg_flink_id
# depends_on: [module.msk, module.vpc_lattice]
```

---

## 完了条件

- [ ] VPC Lattice Service Networkが `ACTIVE` 状態
- [ ] VPC Lattice Service / Listener / Target Groupが正常に作成される
- [ ] Flinkアプリが `scripts/build_flink_app.sh` でビルド・S3アップロードできる
- [ ] Flink アプリケーションが `READY` 状態になる
- [ ] Flink アプリを手動で `RUNNING` 状態に変更後、S3に出力ファイルが生成される
- [ ] CloudWatch Logsにフリンクのログが出力される
- [ ] `terraform plan` で変更差分なし

## VPC Lattice 学習ポイント（READMEへの追記指示）

以下の内容をREADMEの「Architecture Decisions」セクションに記載すること：

```markdown
## VPC Lattice を採用した理由

### 従来構成との比較
| 方式 | 課題 |
|---|---|
| VPC Peering | 推移的ルーティング不可、管理複雑 |
| Transit Gateway | コスト高($0.05/アタッチメント/時) |
| PrivateLink | サービスごとにNLB必要、コスト高 |
| **VPC Lattice** | **L7制御・IAM認可・シンプル設定** |

### VPC Lattice のメリット
- IAMポリシーでL7レベルのアクセス制御が可能
- 将来のマルチアカウント拡張に対応（Resource Sharing via RAM）
- サービスディスカバリが不要（DNS自動解決）
```