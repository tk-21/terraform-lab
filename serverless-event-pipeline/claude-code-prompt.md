# Claude Code 実装プロンプト
# serverless-event-pipeline

> **対象者**: AWS SAP保持者・インフラエンジニア  
> **目標**: S3/Kinesis/SQS × Lambda × DynamoDB によるプロダクションレベルのイベント駆動サーバーレスパイプラインを構築し、転職・案件獲得に使えるポートフォリオに仕上げる  
> **推定工数**: 12〜16時間  
> **月額コスト目安**: ~$5

---

## 前提条件（実行前に確認）

- [ ] AWS アカウント・AdministratorAccess 相当の認証情報が手元にある
- [ ] Terraform 1.7+、Python 3.12+、AWS CLI v2 インストール済み
- [ ] GitHub リポジトリ作成済み（public推奨）
- [ ] `ap-northeast-1` をデフォルトリージョンとして使用

---

## ✅STEP 1: プロジェクト骨格・Terraform 基盤

```
以下の要件でプロジェクトの骨格を作成してください。

【作成対象】
1. CLAUDE.md に従ったディレクトリ構成を全て作成（空ファイルでOK）
2. terraform/environments/dev/backend.tf
   - S3バケット: sep-tfstate-<account_id>（KMS暗号化・バージョニング）
   - DynamoDB: sep-tfstate-lock
3. terraform/environments/dev/providers.tf
   - AWS Provider ~> 5.50、リージョン ap-northeast-1
4. terraform/environments/dev/variables.tf
   - environment, project, account_id, alert_email を定義
5. Makefile
   - make init / plan / apply / destroy / fmt / test / lint
6. .gitignore（.terraform・tfstate・__pycache__・*.pyc・.env）
7. scripts/bootstrap.sh
   - tfstate 用 S3・DynamoDB を AWS CLI で作成するスクリプト

【制約】
- Terraform ~> 1.7、AWS Provider ~> 5.50
- arm64 Lambda を想定した locals を事前定義
- 日本語コメントで設計意図を説明
```

---

## ✅STEP 2: Lambda 共通モジュール

```
再利用可能な Lambda 共通 Terraform モジュールを作成してください。

【モジュール: terraform/modules/lambda-function/】

variables.tf で受け取る主要パラメータ:
  - function_name (string)
  - handler       (string)  # 例: handler.lambda_handler
  - source_dir    (string)  # src/<function名> のパス
  - runtime       (string)  # デフォルト: python3.12
  - timeout       (number)  # デフォルト: 30
  - memory_size   (number)  # デフォルト: 256
  - environment_variables (map(string))
  - reserved_concurrent_executions (number) # デフォルト: -1
  - layers        (list(string))            # Powertools Lambda Layer ARN など
  - additional_policy_arns (list(string))   # 関数個別の追加ポリシー
  - common_tags   (map(string))

main.tf で実装する内容:
  1. archive_file で src ディレクトリを zip 化
  2. aws_s3_object で zip を S3 にアップロード（S3バケット名は変数）
  3. aws_lambda_function
     - アーキテクチャ: arm64
     - X-Ray トレーシング: Active
     - CloudWatch Logs: /aws/lambda/<function_name>（保持期間14日）
     - 環境変数に POWERTOOLS_SERVICE_NAME・LOG_LEVEL を自動付与
  4. aws_iam_role（sep-<env>-<function_name>-role）
     - 基本実行ポリシー（AWSLambdaBasicExecutionRole）
     - X-Ray 書き込みポリシー（AWSXRayDaemonWriteAccess）
     - additional_policy_arns で追加ポリシーをアタッチ
  5. aws_lambda_alias（live エイリアス）
     - Weighted Routing 用のプレースホルダー
  6. aws_lambda_function_event_invoke_config
     - 最大リトライ回数: 2
     - 最大イベント保持時間: 21600秒（6時間）

outputs.tf:
  - function_arn, function_name, invoke_arn, role_arn, alias_arn を output

【制約】
- Lambda Layer の Powertools ARN は SSM Parameter Store から取得（data source）
- source_code_hash で変更検知（毎回デプロイされないように）
- 日本語コメントで各リソースの設計意図を説明
```

---

## ✅STEP 3: ingestor Lambda（S3 イベントトリガー）

```
S3 PUT イベントをトリガーに起動する ingestor Lambda を実装してください。

【Terraform: terraform/modules/sqs-pipeline/ および dev 環境呼び出し】

インフラ構成:
  1. S3 バケット（sep-dev-raw-input-<account_id>）
     - バージョニング有効
     - KMS 暗号化
     - PUT イベント通知 → SQS キュー
  2. SQS キュー（sep-dev-ingest-queue）
     - 可視性タイムアウト: Lambda timeout × 6
     - メッセージ保持期間: 4日
     - KMS 暗号化
  3. SQS DLQ（sep-dev-ingest-dlq）
     - 最大受信回数: 3 で DLQ に移動
     - DLQ メッセージ数 >= 1 で CloudWatch Alarm
  4. Lambda（sep-dev-ingestor）
     - イベントソースマッピング: SQS（バッチサイズ10・bisect_on_function_error有効）
     - IAM: S3 GetObject、SQS ReceiveMessage/DeleteMessage、DynamoDB PutItem、SSM GetParameter
  5. S3 → SQS のリソースポリシー（S3 が SQS に SendMessage できる設定）

【Python: src/ingestor/handler.py】

処理フロー:
  1. SQS メッセージからS3イベントを取得
  2. S3 からファイルをダウンロード（JSON / CSV 自動判定）
  3. Pydantic モデル（src/shared/models.py）でバリデーション
     - 必須フィールドチェック
     - 型チェック（日付形式・数値範囲）
     - バリデーション失敗は ValueError を raise（DLQ へ）
  4. 正規化（タイムゾーンをUTC統一・文字列トリム）
  5. DynamoDB に PutItem（条件付き書き込み: 重複防止）
  6. カスタムメトリクス送信:
     - ProcessedRecords（件数）
     - ValidationErrors（件数）
     - ProcessingLatencyMs（処理時間）

バッチ処理:
  - SQS バッチ内の一部失敗を SqsPartialResponse で個別制御
  - 成功メッセージは自動削除、失敗のみ再試行対象

【制約】
- AWS Lambda Powertools: Logger・Tracer・Metrics を全て使用
- @logger.inject_lambda_context で correlation_id を自動付与
- Pydantic v2 使用（src/shared/models.py に EventRecord モデルを定義）
- S3 からの読み込みは streaming（メモリ効率化）
- 日本語コメントで処理の意図を説明
```

---

## ✅STEP 4: Kinesis Data Streams パイプライン（transformer Lambda）

```
Kinesis Data Streams → transformer Lambda → DynamoDB のパイプラインを実装してください。

【Terraform: terraform/modules/kinesis-pipeline/】

インフラ構成:
  1. Kinesis Data Streams（sep-dev-events-stream）
     - シャード数: 1（dev）/ 2（prod）
     - 保持期間: 24時間（dev）/ 168時間（prod）
     - KMS 暗号化
  2. Lambda（sep-dev-transformer）
     - イベントソースマッピング（Kinesis）:
       * バッチサイズ: 100
       * 最大バッチウィンドウ: 5秒
       * 開始位置: LATEST
       * bisect_on_function_error: true
       * 最大リトライ回数: 3
       * 送信先（失敗時）: SQS DLQ
     - IAM: Kinesis GetRecords/GetShardIterator/DescribeStream、DynamoDB BatchWriteItem
  3. DLQ（sep-dev-transform-dlq）
     - Kinesis ESM の失敗送信先
  4. CloudWatch Alarm
     - Kinesis IteratorAgeMilliseconds > 60000ms で警告（遅延検知）

【Python: src/transformer/handler.py と transform.py】

処理フロー:
  1. Kinesis レコードをデコード（base64 → JSON）
  2. キネシスレコードのスキーマバリデーション
  3. transform.py でビジネスロジック変換:
     - イベントタイプ別の変換ルール（PURCHASE / VIEW / CLICK）
     - 集計キーの生成（entity_id の正規化）
     - エンリッチメント（タイムスタンプ付与・ステータス設定）
  4. DynamoDB に BatchWriteItem（25件ずつ分割・再試行付き）
  5. Kinesis チェックポイント制御（KinesisStreamResponseMessage）

カスタムメトリクス:
  - TransformedRecords（件数・イベントタイプ別ディメンション）
  - BatchWriteErrors（件数）
  - RecordAgeSeconds（Kinesis 投入からの経過時間）

【制約】
- Lambda Powertools の batch_processor（Kinesis対応）を使用
- 変換ロジック（transform.py）は純粋関数で実装（テスト容易性）
- DynamoDB の BatchWriteItem の UnprocessedItems を再試行する実装必須
- 日本語コメントで Kinesis の挙動（シャード・イテレータ）を説明
```

---

## ✅STEP 5: DynamoDB Streams → aggregator Lambda

```
DynamoDB Streams をトリガーに集計処理を行う aggregator Lambda を実装してください。

【Terraform】

インフラ構成:
  1. DynamoDB テーブル（sep-dev-events）
     - CLAUDE.md のテーブル設計を実装
     - Streams: NEW_AND_OLD_IMAGES 有効
     - PITR: 有効（本番のみ）
     - TTL: expires_at 属性
  2. 集計用 DynamoDB テーブル（sep-dev-aggregations）
     - PK: aggregate_key (String)  # 例: USER#u123#2024-01-15
     - SK: metric_type   (String)  # 例: TOTAL_AMOUNT
     - Attributes: value (Number), updated_at (String), count (Number)
  3. Lambda（sep-dev-aggregator）
     - イベントソースマッピング（DynamoDB Streams）:
       * バッチサイズ: 50
       * 開始位置: TRIM_HORIZON
       * bisect_on_function_error: true
       * 最大リトライ回数: 3
     - IAM: DynamoDB DescribeStream/GetRecords、sep-dev-aggregations テーブルへの UpdateItem

【Python: src/aggregator/handler.py】

処理フロー:
  1. DynamoDB Streams イベントから INSERT/MODIFY/REMOVE を判定
  2. INSERT・MODIFY のみ処理（REMOVE はスキップ・ログのみ）
  3. 集計ロジック:
     - entity_id + 日付 でグループ化
     - PURCHASE イベント: total_amount・count を加算
     - VIEW イベント: view_count を加算
  4. DynamoDB UpdateItem で条件付き加算（アトミック更新）:
     ADD #value :amount, #count :one
  5. カスタムメトリクス:
     - AggregatedEvents（件数）
     - AggregationErrors（件数）

【制約】
- DynamoDB Streams の旧イメージと新イメージを比較して差分のみ集計
- UpdateItem は ADD 式でアトミック加算（競合状態を防ぐ）
- 日本語コメントで DynamoDB Streams の特性（最低1回配信）を説明
```

---

## ✅STEP 6: DLQ ハンドラー Lambda（失敗イベント再処理）

```
DLQ に溜まった失敗イベントを分類・再処理する dlq-handler Lambda を実装してください。

【Terraform】

インフラ構成:
  1. Lambda（sep-dev-dlq-handler）
     - トリガー: CloudWatch Alarm（DLQ メッセージ数 >= 1）→ EventBridge → Lambda
       または定期実行（EventBridge Scheduler、5分ごと）
     - IAM: 全 DLQ の ReceiveMessage/DeleteMessage、S3 PutObject、SNS Publish、SQS SendMessage（元キューへ）
  2. S3 バケット（sep-dev-dead-letter-archive-<account_id>）
     - 恒久エラーの保存先
     - ライフサイクル: 90日後に GLACIER、365日後に削除
  3. SNS Topic（sep-dev-pipeline-alerts）
     - Email サブスクリプション
     - dlq-handler からのアラート受信

【Python: src/dlq_handler/handler.py】

失敗分類ロジック:
  ```python
  class FailureCategory(Enum):
      TRANSIENT = "transient"    # 再試行可能（Throttling・タイムアウト・接続エラー）
      PERMANENT = "permanent"    # 恒久エラー（バリデーション失敗・スキーマ不整合）
      UNKNOWN   = "unknown"      # 分類不能

  # SQS メッセージの MessageAttributes から失敗理由を取得して分類
  # TRANSIENT → 元のキューに再エンキュー（exponential backoff 用の DelaySeconds を設定）
  # PERMANENT → S3 dead-letter-archive に保存（prefix: permanent/<date>/<message_id>.json）
  # UNKNOWN   → S3 に保存 + SNS でアラート
  ```

レポート機能:
  - 処理完了後に SNS へサマリー送信:
    * 再処理件数・恒久エラー件数・不明件数
    * 直近7日間の累計 DLQ 件数（CloudWatch Metrics から取得）

【制約】
- メッセージ属性（MessageAttributes）に失敗情報を付与する実装方針は STEP 3 から一貫させる
- S3 保存時は gzip 圧縮
- 日本語コメントでエラーハンドリング戦略を説明
```

---

## ✅STEP 7: オブザーバビリティ基盤

```
本番レベルのオブザーバビリティ基盤を Terraform で実装してください。

【モジュール: terraform/modules/observability/】

1. X-Ray トレーシング設定
   - X-Ray グループ（sep-dev-pipeline）
     * フィルタ式: service("sep-dev-ingestor") OR service("sep-dev-transformer")
   - サンプリングルール:
     * 本番: 10%（コスト制御）
     * 開発: 100%

2. CloudWatch ダッシュボード（sep-dev-pipeline-dashboard）
   以下のウィジェットを実装:
   - Lambda 関数別: Invocations・Errors・Duration・Throttles・ConcurrentExecutions
   - カスタムメトリクス: ProcessedRecords・ValidationErrors・TransformedRecords・AggregatedEvents
   - Kinesis: GetRecords.IteratorAgeMilliseconds・PutRecords.Success
   - DLQ: ApproximateNumberOfMessagesVisible（全DLQ）
   - X-Ray: サービスマップへのリンク

3. CloudWatch Alarms（全て SNS 経由でアラート）
   | アラーム名 | 条件 | 重要度 |
   |---|---|---|
   | sep-dev-ingestor-errors | エラー率 > 5% (5分) | CRITICAL |
   | sep-dev-transformer-errors | エラー率 > 5% (5分) | CRITICAL |
   | sep-dev-ingest-dlq-depth | メッセージ数 >= 1 | WARNING |
   | sep-dev-transform-dlq-depth | メッセージ数 >= 1 | WARNING |
   | sep-dev-kinesis-iterator-age | IteratorAge > 60秒 | WARNING |
   | sep-dev-lambda-throttles | スロットル > 10回/5分 | WARNING |
   | sep-dev-cold-start-rate | コールドスタート率 > 30% | INFO |

4. CloudWatch Log Insights クエリ（保存済みクエリとして登録）
   - エラーログ抽出:
     ```
     fields @timestamp, level, message, correlation_id, error
     | filter level = "ERROR"
     | sort @timestamp desc
     | limit 100
     ```
   - 処理レイテンシ集計:
     ```
     fields @timestamp, service, duration_ms
     | filter ispresent(duration_ms)
     | stats avg(duration_ms), max(duration_ms), pct(duration_ms, 95) by service
     ```
   - DLQ 失敗トレース:
     ```
     fields @timestamp, correlation_id, failure_reason, failure_category
     | filter ispresent(failure_reason)
     | sort @timestamp desc
     ```

5. Lambda Insights 有効化
   - 全 Lambda 関数で CloudWatch Lambda Insights を有効化
   - Lambda Insights Layer ARN（arm64）を SSM から取得

【制約】
- ダッシュボード JSON は aws_cloudwatch_dashboard リソースの jsonencode() で管理
- アラームの evaluate_low_sample_count_percentile 設定も含める
- 日本語コメントで各メトリクスの監視意図を説明
```

---

## ✅STEP 8: CI/CD パイプライン（GitHub Actions）

```
本番レベルの CI/CD パイプラインを GitHub Actions で実装してください。

【.github/workflows/ci.yml（PR トリガー）】

ジョブ構成:
  1. lint-python
     - ruff check src/ tests/（高速 linter）
     - black --check src/ tests/
     - mypy src/（型チェック）
  2. test-unit
     - pytest tests/unit/ -v --cov=src --cov-report=xml
     - カバレッジ 80% 未満で失敗
     - coverage.xml を artifacts にアップロード
  3. lint-terraform
     - terraform fmt -check -recursive
     - tflint --recursive（aws plugin 有効）
     - checkov -d terraform/ --framework terraform
  4. terraform-plan
     - OIDC 認証（アクセスキー不使用）
     - terraform plan の結果を PR コメントに投稿
     - plan の変更有無を outputs で後続ジョブに伝達

【.github/workflows/cd.yml（main マージトリガー）】

ジョブ構成:
  1. terraform-apply
     - OIDC 認証
     - terraform apply -auto-approve
     - apply 結果を GitHub Step Summary に記録
  2. deploy-lambda
     - 各 Lambda 関数の zip を S3 にアップロード
     - aws lambda update-function-code で新バージョンを発行
     - Lambda Alias のカナリアウェイトを 10% に設定
  3. integration-test
     - tests/integration/test_pipeline_e2e.py を実行
     - テスト用イベントを投入 → DynamoDB に結果が書き込まれるまで待機（最大60秒）
  4. promote-or-rollback
     - integration-test 成功 → Alias ウェイトを 100% に切り替え
     - integration-test 失敗 → Alias を前バージョンに戻し、Slack/Email でアラート

【OIDC 設定 Terraform】
- terraform/environments/dev/github-oidc.tf を作成
  * aws_iam_openid_connect_provider（GitHub Actions OIDC）
  * aws_iam_role（sep-dev-github-actions-role）
    - 信頼ポリシー: repo:<org>/<repo>:ref:refs/heads/main に限定
    - 権限: Lambda・S3・DynamoDB・Kinesis・SQS の操作権限（最小権限）

【制約】
- GitHub Secrets には AWS_ACCOUNT_ID のみ保存（アクセスキー不使用）
- CI ジョブは並列実行（needs で依存関係のみ直列化）
- 日本語コメントで各ジョブの役割を説明
```

---

## ✅STEP 9: テスト実装（Unit + Integration）

```
本番品質のテストを実装してください。

【Unit テスト: tests/unit/】

test_ingestor.py:
  - 正常系: 有効な JSON・CSV ファイルを処理できること
  - バリデーション失敗: 必須フィールド欠損・型不正で ValueError が発生すること
  - 重複処理: DynamoDB の条件付き書き込みで ConditionalCheckFailedException を適切に処理すること
  - バッチ部分失敗: SqsPartialResponse が正しいアイテム識別子を返すこと
  - モック: boto3 クライアントは moto でモック

test_transformer.py:
  - transform.py の変換ロジックを純粋関数単体でテスト
  - PURCHASE / VIEW / CLICK 各イベントタイプの変換結果を検証
  - Kinesis レコードの base64 デコードが正しく動作すること
  - DynamoDB UnprocessedItems の再試行ロジックを検証

test_aggregator.py:
  - INSERT / MODIFY / REMOVE イベントの処理分岐が正しいこと
  - アトミック加算の UpdateItem 式が正しい形式であること
  - 旧イメージと新イメージの差分計算が正しいこと

共通:
  - pytest fixtures で共通テストデータを管理
  - @mock_aws（moto v4）でAWSサービスをモック
  - カバレッジ目標: 80% 以上

【Integration テスト: tests/integration/test_pipeline_e2e.py】

エンドツーエンドテスト:
  1. テスト用 S3 バケットにサンプル JSON ファイルをアップロード
  2. SQS → Lambda の起動を確認（5秒ポーリング × 12回）
  3. DynamoDB に期待するレコードが書き込まれるまで待機（最大60秒）
  4. 集計テーブルの値を検証
  5. CloudWatch Metrics でカスタムメトリクスが記録されたことを確認
  6. テスト後のクリーンアップ（作成したリソースを削除）

conftest.py:
  - AWS セッション・DynamoDB クライアント等の pytest fixtures
  - 環境変数から dev 環境のリソース名を取得

【制約】
- Unit テストは外部依存なし（moto で完結）
- Integration テストは dev 環境の実 AWS リソースを使用
- `make test-unit` / `make test-integration` で個別実行可能
```

---

## ✅STEP 10: ドキュメント・仕上げ

```
GitHub 公開・転職アピール向けのドキュメントを整備してください。

【README.md（日本語メイン・英語サマリー付き）】

構成:
  1. キャッチコピー + バッジ（CI/CD ステータス・coverage）
  2. アーキテクチャ図（Mermaid）
     - イベントフロー全体図
     - エラーハンドリングフロー図
  3. 技術スタック表
     | カテゴリ | 技術 | 採用理由 |
     |---|---|---|
     | IaC | Terraform ~> 1.7 | 宣言的・モジュール再利用 |
     | Runtime | Python 3.12 / arm64 | コスト ~20%削減・パフォーマンス |
     | Observability | Lambda Powertools | 構造化ログ・X-Ray・カスタムメトリクス統合 |
     | Test | pytest + moto + Terratest | Unit/Integration/IaC の3層テスト |
     | CI/CD | GitHub Actions + OIDC | アクセスキーレスの安全なデプロイ |
  4. セットアップ手順（コピペで動くコマンド列）
  5. 各STEP の解説と学習ポイント
  6. コスト見積もり表
  7. 今後の拡張案（Bedrock連携・EventBridge Pipes・Step Functions）

【docs/adr/001-kinesis-vs-sqs.md（ADR例）】

ADR形式:
  - ステータス: Accepted
  - コンテキスト: リアルタイム処理 vs 非同期処理の選択
  - 決定: Kinesis（順序保証が必要な場合）と SQS（独立したタスク処理）を用途で使い分け
  - 結果: Kinesis はシャード単位で順序保証、SQS は並列スケール性に優れる

【docs/runbook.md】

障害対応手順:
  - DLQ にメッセージが蓄積された場合の調査手順
  - Kinesis IteratorAge 遅延の原因調査と対処
  - Lambda エラー率上昇時の Log Insights クエリ手順
  - 手動再処理手順（DLQ から元キューへの転送コマンド）

【最終チェックリスト】
  □ terraform fmt -recursive 完了
  □ tflint エラーなし
  □ checkov 警告対応済み（許容除外は .checkov.yml に明記）
  □ pytest カバレッジ 80% 以上
  □ README の手順を最初から辿れることを確認
  □ 実アカウントID・ARN がコードに含まれていないことを確認
  □ GitHub Actions CI が全ジョブ GREEN であることを確認
  □ CloudWatch ダッシュボードのスクリーンショットを README に追加

【制約】
- Mermaid 図は GitHub でレンダリングされる形式
- ADR は docs/adr/NNN-title.md の番号付き形式
- 実 Account ID は全てマスク（<ACCOUNT_ID> 表記）
```

---

## 学習ポイント・転職アピール早見表

| STEP | 技術 | 面接で刺さる話題 |
|---|---|---|
| 2 | Terraform モジュール設計 | 「再利用可能なモジュールで4種のLambdaを統一管理」 |
| 3 | SQS + Lambda ESM + DLQ | 「bisect_on_function_error でバッチ部分失敗を制御」 |
| 4 | Kinesis + Lambda + チェックポイント | 「IteratorAge 監視でリアルタイム遅延を早期検知」 |
| 5 | DynamoDB Streams + アトミック加算 | 「ADD 式で競合なし集計を実現」 |
| 6 | DLQ 失敗分類・再処理 | 「一時エラーと恒久エラーを自動分類して再処理」 |
| 7 | Lambda Powertools + X-Ray | 「相関IDで分散トレースを1クリックで追跡可能」 |
| 8 | GitHub Actions OIDC + カナリア | 「アクセスキーレスで10%カナリアデプロイ」 |
| 9 | moto + Integration テスト | 「Unit〜E2Eの3層テスト・カバレッジ80%」 |