# Claude Code 実装プロンプト
# serverless-api-platform

> **対象者**: AWS SAP保持者・インフラエンジニア  
> **目標**: API Gateway × Lambda × DynamoDB による本番レベルの REST API 基盤を構築し、転職・案件獲得に使えるポートフォリオに仕上げる  
> **推定工数**: 12〜15時間  
> **月額コスト目安**: ~$3

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
1. CLAUDE.md に従ったディレクトリ構成を全て作成
2. scripts/bootstrap.sh
   - tfstate 用 S3バケット（sap-tfstate-<account_id>）をAWS CLIで作成
   - KMS暗号化・バージョニング・パブリックアクセスブロック有効
   - DynamoDB テーブル（sap-tfstate-lock）を作成
3. terraform/environments/dev/backend.tf・providers.tf・variables.tf
   - variables: environment, project, account_id, alert_email, allowed_ips
4. Makefile
   - make init / plan / apply / destroy / fmt / test / lint / deploy
5. .gitignore（.terraform・tfstate・__pycache__・*.pyc・.env・*.zip）
6. terraform/environments/dev/github-oidc.tf
   - aws_iam_openid_connect_provider（GitHub OIDC）
   - aws_iam_role（sap-dev-github-actions-role）
     * 信頼ポリシー: 自分のGitHub org/repo の main ブランチに限定
     * 権限: Lambda・API Gateway・DynamoDB・Cognito・S3・CloudWatch の操作権限

【制約】
- Terraform ~> 1.7、AWS Provider ~> 5.50
- arm64 Lambda を想定した locals を事前定義（runtime = "python3.12"、architectures = ["arm64"]）
- 日本語コメントで設計意図を説明
```

---

## STEP 2: DynamoDB テーブル設計

```
CLAUDE.md の Single Table Design を Terraform で実装してください。

【モジュール: terraform/modules/dynamodb/】

main.tf で実装する内容:
  1. aws_dynamodb_table（sap-<env>-items）
     - billing_mode: PAY_PER_REQUEST
     - hash_key: PK (String)
     - range_key: SK (String)
     - TTL: expires_at 属性
     - Streams: NEW_AND_OLD_IMAGES
     - point_in_time_recovery: var.enable_pitr（prodのみtrue）
     - server_side_encryption: AWS管理KMSキー

  2. GSI-1（user-index）
     - hash_key: user_id
     - range_key: created_at
     - projection_type: ALL

  3. GSI-2（status-index）
     - hash_key: status
     - range_key: created_at
     - projection_type: INCLUDE（item_id, name, user_id のみ）

  4. aws_appautoscaling_target / aws_appautoscaling_policy
     - PAY_PER_REQUEST なので不要
     ※ コメントで「なぜオンデマンドを選んだか」を説明

outputs.tf:
  - table_name, table_arn, stream_arn を output

【制約】
- GSI の projection_type の選択理由を日本語コメントで説明
- PITR は var.enable_pitr で prod/dev を切り替え
- テーブル名はローカル変数で組み立て（ハードコード禁止）
```

---

## STEP 3: Cognito 認証基盤

```
API の認証基盤として AWS Cognito User Pool を Terraform で実装してください。

【モジュール: terraform/modules/cognito/】

実装内容:
  1. aws_cognito_user_pool（sap-<env>-user-pool）
     - パスワードポリシー: 最小8文字・大文字小文字数字記号必須
     - MFA: OPTIONAL（TOTP対応）
     - 自動検証: email
     - アカウント復旧: email のみ
     - ユーザー属性: email（必須・変更不可）、name（任意）
     - 削除保護: ACTIVE（prodのみ）

  2. aws_cognito_user_pool_client（sap-<env>-api-client）
     - 認証フロー: ALLOW_USER_PASSWORD_AUTH、ALLOW_REFRESH_TOKEN_AUTH
     - アクセストークン有効期限: 1時間
     - リフレッシュトークン有効期限: 30日
     - クライアントシークレット: 不使用（SPAから呼ぶ想定）

  3. aws_cognito_user_pool_domain（sap-<env>-auth）
     - Cognitoのホストされた UI ドメイン

outputs.tf:
  - user_pool_id, user_pool_arn, client_id, issuer_url を output

【制約】
- MFA を OPTIONAL にした理由を日本語コメントで説明
- クライアントシークレットを不使用にした理由（フロントエンド公開リスク）を説明
- issuer_url は API Gateway オーソライザーの設定に使用する前提
```

---

## STEP 4: Lambda 共通モジュール

```
全 Lambda 関数で再利用する Terraform モジュールを作成してください。

【モジュール: terraform/modules/lambda-function/】

variables.tf の主要パラメータ:
  - function_name
  - handler（デフォルト: handler.lambda_handler）
  - source_dir（src/<function名> のパス）
  - timeout（デフォルト: 25 ※API GW統合タイムアウト29sより短く設定）
  - memory_size（デフォルト: 256）
  - environment_variables（map(string)）
  - reserved_concurrent_executions（デフォルト: 10）
  - additional_policy_statements（list(object)）

main.tf で実装する内容:
  1. archive_file で src ディレクトリを zip 化
  2. aws_s3_object で zip を Lambda デプロイ用 S3 に保存
  3. aws_lambda_function
     - アーキテクチャ: arm64
     - X-Ray トレーシング: Active
     - 環境変数に自動付与:
       * POWERTOOLS_SERVICE_NAME = var.function_name
       * LOG_LEVEL = var.log_level（デフォルト: INFO）
       * POWERTOOLS_METRICS_NAMESPACE = "ServerlessApiPlatform"
  4. aws_cloudwatch_log_group
     - 保持期間: 14日（dev）/ 90日（prod）
  5. aws_iam_role（最小権限）
     - 基本実行ポリシー
     - X-Ray ポリシー
     - additional_policy_statements でインラインポリシーを追加
  6. aws_lambda_provisioned_concurrency_config（prodのみ、var.provisioned_concurrency > 0）

outputs.tf:
  - function_arn, function_name, invoke_arn, role_arn, role_name

【制約】
- source_code_hash で変更検知（zip が変わった時だけデプロイ）
- タイムアウト 25秒 の理由を日本語コメントで明記
- reserved_concurrent_executions のデフォルト 10 の意図（暴走防止）を説明
```

---

## STEP 5: CRUD Lambda 実装（Python）

```
5つの CRUD Lambda 関数を Python で実装してください。

【shared/ 共通コード】

shared/models.py（Pydantic v2）:
  - ItemCreate: name(str, max=100), description(str, max=1000), expires_days(int, 1-365, optional)
  - ItemUpdate: name(str, optional), description(str, optional), status(Literal["ACTIVE","ARCHIVED"], optional)
  - ItemResponse: item_id, user_id, name, description, status, created_at, updated_at

shared/repository.py（DynamoDB アクセス層）:
  - DynamoDBRepository クラス
    * put_item(item: dict) → None（条件付き書き込み: PK が存在しない場合のみ）
    * get_item(item_id: str) → dict | None
    * update_item(item_id: str, updates: dict) → dict（条件付き: PK が存在する場合のみ）
    * delete_item(item_id: str) → None（論理削除: status = ARCHIVED, expires_at = now + 30days）
    * list_items_by_user(user_id: str, limit: int, cursor: str | None) → tuple[list, str | None]
      - GSI-1（user-index）でクエリ
      - DynamoDB の ExclusiveStartKey を base64 エンコードしてカーソル化

shared/response.py:
  - success_response(data, status_code=200) → dict
  - error_response(code, message, status_code) → dict
  - paginated_response(data, next_cursor, has_more) → dict

shared/exceptions.py:
  - ItemNotFoundError / ItemAlreadyExistsError / ValidationError / ForbiddenError

【各 Lambda handler.py の処理フロー】

create_item（POST /items）:
  1. Cognito JWT から user_id を取得（event["requestContext"]["authorizer"]["claims"]["sub"]）
  2. リクエストボディを ItemCreate でバリデーション
  3. UUID v4 で item_id を生成
  4. DynamoDB PutItem（条件付き: 重複防止）
  5. 201 Created でレスポンス

get_item（GET /items/{id}）:
  1. パスパラメータから item_id を取得
  2. DynamoDB GetItem
  3. 見つからない場合は ItemNotFoundError（→404）
  4. リクエストユーザーの所有物かチェック（ForbiddenError → 403）
  5. 200 OK でレスポンス

list_items（GET /items）:
  1. Cognito JWT から user_id 取得
  2. クエリパラメータから limit（デフォルト20, 最大100）・cursor を取得
  3. DynamoDB Query（GSI-1: user-index）
  4. カーソルベースページネーションで返却

update_item（PUT /items/{id}）:
  1. DynamoDB GetItem で存在確認・所有者確認
  2. ItemUpdate でバリデーション
  3. updated_at を現在時刻で更新
  4. DynamoDB UpdateItem（条件付き: PK存在確認）
  5. 200 OK で更新後アイテムを返却

delete_item（DELETE /items/{id}）:
  1. 存在確認・所有者確認
  2. 論理削除（status = ARCHIVED、expires_at = 30日後）
  3. 204 No Content

【全 Lambda 共通要件】
- AWS Lambda Powertools: Logger・Tracer・Metrics を全て使用
- APIGatewayRestResolver で app.resolve(event, context) を使用
- カスタムメトリクス: 各エンドポイントの成功・失敗件数、レイテンシ
- エラーは全て error_response() で統一フォーマット
- 日本語コメントで処理の意図を説明
```

---

## STEP 6: API Gateway（REST API + Cognito オーソライザー）

```
API Gateway REST API と Cognito 統合を Terraform で実装してください。

【モジュール: terraform/modules/api-gateway/】

実装内容:
  1. aws_api_gateway_rest_api（sap-<env>-api）
     - エンドポイント: REGIONAL
     - OpenAPI 仕様をインラインで定義（body = jsonencode(...)）
       またはリソース・メソッドを個別 Terraform リソースで管理

  2. Cognito オーソライザー（aws_api_gateway_authorizer）
     - type: COGNITO_USER_POOLS
     - identity_source: method.request.header.Authorization
     - provider_arns: Cognito User Pool ARN
     - TTL: 300秒

  3. リソース・メソッド定義（全エンドポイント）
     /items
       GET    → list_items Lambda（Cognito認証必須）
       POST   → create_item Lambda（Cognito認証必須）
     /items/{id}
       GET    → get_item Lambda（Cognito認証必須）
       PUT    → update_item Lambda（Cognito認証必須）
       DELETE → delete_item Lambda（Cognito認証必須）

  4. リクエストバリデーション（aws_api_gateway_request_validator）
     - POST /items: リクエストボディの JSONスキーマ検証
       * name は必須・文字列
       * expires_days は整数・1-365
     - PUT /items/{id}: 同様

  5. ステージ設定（aws_api_gateway_stage）
     - ステージ名: var.environment
     - アクセスログ: CloudWatch Logs（/aws/apigateway/sap-<env>-api）
     - X-Ray: 有効
     - スロットリング: 1000 req/s (burst: 500)

  6. Lambda パーミッション（aws_lambda_permission）
     - 全 Lambda に API GW からの invoke 権限を付与

  7. CloudWatch ロール（API GW がログを書き込むための IAM ロール）

outputs.tf:
  - api_endpoint（ベース URL）, execution_arn

【制約】
- CORS 設定を OPTIONS メソッドで実装（Access-Control-Allow-Origin: *）
- カスタムドメインは STEP 10 で追加予定のためプレースホルダーコメントを残す
- スロットリング設定の意図（DDoS対策・コスト上限）を日本語コメントで説明
```

---

## STEP 7: DynamoDB Streams → stream-processor Lambda（監査ログ）

```
DynamoDB Streams をトリガーに変更履歴を S3 に保存する監査ログ Lambda を実装してください。

【Terraform】

インフラ構成:
  1. S3 バケット（sap-<env>-audit-logs-<account_id>）
     - KMS 暗号化
     - バージョニング有効
     - ライフサイクル: 90日後 STANDARD_IA → 365日後 GLACIER
     - パブリックアクセス完全ブロック
  2. Lambda（sap-<env>-stream-processor）
     - トリガー: DynamoDB Streams（sap-<env>-items テーブル）
       * バッチサイズ: 100
       * 開始位置: TRIM_HORIZON
       * bisect_on_function_error: true
     - IAM: DynamoDB Streams 読み取り、S3 PutObject（sap-<env>-audit-logs のみ）

【Python: src/stream_processor/handler.py】

処理フロー:
  1. DynamoDB Streams イベントから INSERT / MODIFY / REMOVE を取得
  2. 各イベントタイプに応じた監査ログを構築:
     {
       "event_type": "ITEM_CREATED" | "ITEM_UPDATED" | "ITEM_DELETED",
       "item_id": "...",
       "user_id": "...",
       "changed_at": "ISO8601",
       "changes": {
         "before": { ... },  # MODIFY/REMOVEのみ
         "after":  { ... }   # INSERT/MODIFYのみ
       }
     }
  3. S3 に JSON Lines 形式で保存
     - パス: audit-logs/<year>/<month>/<day>/<item_id>-<timestamp>.jsonl
  4. カスタムメトリクス: AuditEventsProcessed（イベントタイプ別）

【制約】
- 監査ログはユーザーが削除できない設計（S3バケットポリシーで明示）
- DynamoDB の型変換（{"S": "xxx"} → "xxx"）を boto3 の TypeDeserializer で処理
- 日本語コメントで監査ログの保持設計を説明
```

---

## STEP 8: CI/CD パイプライン（GitHub Actions）

```
本番レベルの CI/CD パイプラインを GitHub Actions で実装してください。

【.github/workflows/ci.yml（PRトリガー）】

ジョブ:
  1. lint-python（並列）
     - ruff check src/ tests/
     - black --check src/ tests/
     - mypy src/ --ignore-missing-imports

  2. test-unit（並列）
     - pytest tests/unit/ -v --cov=src --cov-report=xml --cov-fail-under=80
     - Codecov にカバレッジをアップロード

  3. lint-terraform（並列）
     - terraform fmt -check -recursive terraform/
     - tflint --recursive terraform/
     - checkov -d terraform/ --framework terraform --soft-fail（結果をコメント投稿）

  4. terraform-plan（lint-terraform 完了後）
     - OIDC 認証（secrets.AWS_ACCOUNT_ID のみ使用）
     - terraform plan -out=tfplan
     - tfplan の変更内容を PR コメントに投稿（追加/変更/削除リソース数）
     - plan ファイルを artifacts にアップロード

【.github/workflows/cd.yml（main ブランチ push トリガー）】

ジョブ:
  1. terraform-apply
     - OIDC 認証
     - ci.yml の artifacts から tfplan を取得して apply
     - apply 結果を GitHub Step Summary に記録

  2. deploy-lambda（terraform-apply 完了後、並列）
     - 各 Lambda の zip を作成して S3 にアップロード
     - aws lambda update-function-code で更新
     - aws lambda wait function-updated で完了を待機

  3. smoke-test（deploy-lambda 完了後）
     - Cognito でテストユーザーの JWT を取得
     - curl で各エンドポイントに 1リクエストずつ送信
     - 全て 2xx であることを確認
     - 失敗時は SNS でアラート送信

  4. notify（常に実行）
     - デプロイ成功・失敗を Slack Webhook（または SNS Email）に通知

【Makefile の deploy ターゲット】

```makefile
# ローカルから手動デプロイする場合
deploy: build
    @for fn in ingestor get_item create_item update_item delete_item stream_processor; do \
        aws lambda update-function-code \
            --function-name sap-$(ENV)-$$fn \
            --s3-bucket sap-$(ENV)-lambda-$(ACCOUNT_ID) \
            --s3-key $$fn.zip; \
    done
```

【制約】
- GitHub Secrets は AWS_ACCOUNT_ID のみ（アクセスキー保存禁止）
- CI ジョブは最大並列化（余計な depends_on を入れない）
- PR コメントは github-script action で投稿
- 日本語コメントで各ジョブの役割を説明
```

---

## STEP 9: テスト実装（Unit + Integration）

```
本番品質のテストを実装してください。

【Unit テスト: tests/unit/】

test_repository.py:
  - @mock_aws（moto v4）でDynamoDBをモック
  - put_item: 正常系・重複エラー（ConditionalCheckFailedException）
  - get_item: 存在する場合・存在しない場合（None返却）
  - update_item: 正常系・対象なしエラー
  - delete_item: 論理削除の確認（status=ARCHIVED、expires_at設定）
  - list_items_by_user: ページネーション（cursor の base64 エンコード）

test_create_item.py:
  - バリデーション正常系・異常系（name欠損・長すぎる値）
  - user_id が JWT から正しく取得されること
  - DynamoDB に正しいスキーマで書き込まれること
  - 重複アイテムで 409 Conflict が返ること

test_list_items.py:
  - 空リスト・複数件・ページネーション有りの各ケース
  - limit パラメータの境界値テスト（1・100・101で400）
  - cursor が不正な場合のエラー処理

test_update_item.py:
  - 正常更新・一部フィールドのみ更新
  - 他ユーザーのアイテムへの更新で 403 Forbidden
  - 存在しないアイテムへの更新で 404 Not Found

【Integration テスト: tests/integration/test_api_e2e.py】

実際のAWSリソースを使った E2E テスト:
  1. Cognito でテストユーザーを作成・JWT 取得
  2. POST /items → アイテム作成
  3. GET /items/{id} → 作成したアイテムを取得・内容検証
  4. GET /items → 一覧取得・ページネーション確認
  5. PUT /items/{id} → 更新・更新内容確認
  6. DELETE /items/{id} → 削除（論理削除）
  7. GET /items/{id} → 削除後に ARCHIVED になっていることを確認
  8. 認証なしリクエスト → 401 Unauthorized を確認
  9. テスト後クリーンアップ（Cognito テストユーザー削除）

【制約】
- Unit テストは moto で完結（外部AWS通信なし）
- Integration テストは dev 環境の実リソースを使用
- pytest fixtures を conftest.py に集約
- `make test-unit` / `make test-integration` で個別実行可能
- カバレッジ目標: Unit 80% 以上
```

---

## STEP 10: ドキュメント・仕上げ

```
GitHub 公開・転職アピール向けのドキュメントを整備してください。

【docs/api-spec.yaml（OpenAPI 3.0）】

全エンドポイントを定義:
- components/schemas に ItemCreate・ItemUpdate・ItemResponse・ErrorResponse・PaginatedResponse
- components/securitySchemes に BearerAuth（JWT）
- 各エンドポイントのリクエスト・レスポンス例を記載

【README.md（日本語メイン）】

構成:
  1. バッジ（CI: GitHub Actions・Coverage・License）
  2. キャッチコピー: 「認証・バリデーション・監査ログ・CI/CDまで完備のサーバーレスAPI基盤」
  3. アーキテクチャ図（Mermaid）
     - システム全体図
     - DynamoDB Single Table Design の ER図
     - CI/CD フロー図
  4. 技術スタック表
     | カテゴリ | 技術 | 採用理由 |
     |---|---|---|
     | API | API Gateway REST API | リクエストバリデーション・Cognitoネイティブ統合 |
     | 認証 | Cognito User Pool | JWT発行・MFA・ユーザー管理を委譲 |
     | Runtime | Python 3.12 / arm64 | コスト削減・高パフォーマンス |
     | ORM代替 | Pydantic v2 | 型安全なバリデーション |
     | Observability | Lambda Powertools | 構造化ログ・X-Ray・メトリクス統合 |
     | IaC | Terraform ~> 1.7 | モジュール化・再利用性 |
     | CI/CD | GitHub Actions + OIDC | アクセスキーレスの安全なデプロイ |
  5. セットアップ手順（コピペで動くコマンド）
  6. API 使用例（curl コマンド付き）
     - 認証トークン取得
     - 各 CRUD 操作
  7. コスト見積もり表
  8. 今後の拡張案（WAF・カスタムドメイン・DAX・GraphQL化）

【docs/adr/001-single-table-design.md】
- なぜマルチテーブルではなく Single Table Design を選んだか
- アクセスパターン一覧と対応するGSI設計

【docs/adr/002-cognito-vs-custom-auth.md】
- なぜ自前JWT検証ではなくCognito+API Gateway Authorizerを選んだか

【docs/runbook.md】
- 5xx エラー急増時の調査手順（CloudWatch Logs Insights クエリ付き）
- DynamoDB CapacityUnits 超過時の対処
- Lambda Throttle 発生時の対処

【最終チェックリスト】
  □ terraform fmt -recursive 完了
  □ tflint エラー 0件
  □ pytest カバレッジ 80% 以上
  □ GitHub Actions CI が全ジョブ GREEN
  □ curl で全エンドポイントが期待通りのレスポンスを返すことを確認
  □ README の手順を最初から辿れることを確認
  □ 実 Account ID・ARN がコードに含まれていないことを確認（grep で確認）
  □ OpenAPI spec が実装と一致していることを確認
```

---

## 学習ポイント・転職アピール早見表

| STEP | 技術 | 面接で刺さる話題 |
|---|---|---|
| 2 | DynamoDB Single Table Design | 「GSI設計でフルスキャンをゼロに」 |
| 3 | Cognito User Pool | 「JWT検証をAPI GWに委譲・MFA対応」 |
| 4 | Terraform モジュール | 「6関数を共通モジュールで統一管理」 |
| 5 | Pydantic v2 + Powertools | 「型安全なバリデーションと構造化ログ」 |
| 6 | API GW リクエストバリデーション | 「Lambda到達前にバッドリクエストを排除」 |
| 7 | DynamoDB Streams + 監査ログ | 「全変更履歴をS3に自動保存・GLACIER管理」 |
| 8 | GitHub Actions OIDC | 「アクセスキーレス・smoke testで品質担保」 |
| 9 | moto + E2E テスト | 「Unit〜E2E 2層・カバレッジ80%」 |
| 10 | OpenAPI spec + ADR + Runbook | 「採用担当・現場エンジニア両方に刺さる資料」 |