# serverless-api-platform

API Gateway × Lambda × DynamoDB によるプロダクションレベルのサーバーレス REST API 基盤。

認証・バリデーション・エラーハンドリング・CI/CD まで一気通貫で実装した、転職・案件獲得向けポートフォリオプロジェクト。

---

## これを作り終えると何ができるようになるか

### 動くものとして

**認証付きの REST API が AWS 上に立ち上がる。**

Cognito で発行した JWT トークンを Authorization ヘッダーに付けるだけで、以下の操作が HTTPS 経由でできる。

```bash
# アイテムを作成する
curl -X POST https://api.example.com/items \
  -H "Authorization: Bearer <JWT>" \
  -d '{"name": "買い物リスト", "description": "週末用"}'

# 自分のアイテム一覧を取得する（ページネーション対応）
curl https://api.example.com/items \
  -H "Authorization: Bearer <JWT>"

# 特定のアイテムを更新する
curl -X PUT https://api.example.com/items/{id} \
  -H "Authorization: Bearer <JWT>" \
  -d '{"status": "ARCHIVED"}'

# 削除する
curl -X DELETE https://api.example.com/items/{id} \
  -H "Authorization: Bearer <JWT>"
```

裏側では以下がすべて自動で動く:

- **認証**: Cognito が JWT を検証。Lambda には検証済みのユーザー ID だけが渡ってくる
- **認可**: 自分が作ったアイテムしか更新・削除できない（他人のデータは 403）
- **保護**: WAF がレートリミットと IP ブロックで不正アクセスを弾く
- **監査ログ**: DynamoDB の全変更が S3 に自動保存される（誰が・いつ・何を変えたか）
- **自動削除**: ARCHIVED にしたアイテムは 30 日後に DynamoDB から消える（TTL）
- **可観測性**: CloudWatch ダッシュボードでエラー率・スロットリング・レイテンシが一目でわかる

---

### 技術的に証明できること

**「AWS でサーバーレス API を一から設計・構築・運用できる」を具体的なコードで示せる。**

| 証明できること | 具体的な実装 |
|---|---|
| IaC で再現可能な環境を作れる | Terraform モジュール構成。`make apply` 1発で全リソースが揃う |
| 最小権限の IAM 設計ができる | Lambda ごとに専用ロール。`*` リソース指定ゼロ |
| DynamoDB を正しく使える | Single Table Design・GSI での Query（Scan 禁止）・ページネーション |
| セキュアな API 設計ができる | Cognito JWT 検証・WAF・HTTPS 強制・所有者チェック |
| 可観測性を作れる | 構造化ログ・X-Ray トレース・CloudWatch アラーム・ダッシュボード |
| CI/CD を組める | GitHub Actions + OIDC（IAM キーなし）。PR で plan、merge で apply |
| テストを書ける | moto で DynamoDB をモック。ユニットテスト + E2E テスト |
| コストを意識した設計ができる | arm64 Lambda・PAY_PER_REQUEST・dev/prod の機能分離 |

---

### 転職・案件獲得での使い方

このプロジェクト単体で以下の会話ができる:

- **「サーバーレスアーキテクチャの経験はありますか？」**
  → GitHub の URL を出して「これを設計・実装しました」と言える

- **「DynamoDB の設計経験は？」**
  → Single Table Design・GSI の使い分け・Scan を使わない理由を説明できる

- **「セキュリティ設計はどう考えますか？」**
  → Cognito + API Gateway 委譲・最小権限 IAM・WAF・監査ログの構成を説明できる

- **「CI/CD の経験は？」**
  → OIDC による keyless な GitHub Actions パイプラインを見せられる

- **「Terraform を書けますか？」**
  → モジュール分割・`for_each` ループ・`locals` による命名管理のコードを見せられる

---

## アーキテクチャ概要

```
[クライアント]
      ↓ HTTPS
[API Gateway（REST API）]
  - WAF（レートリミット・IP ブロック）     ← prod のみ
  - Cognito オーソライザー（JWT 検証）     ← prod のみ（dev は無効）
  - リクエストバリデーション（JSON スキーマ）
      ↓
[Lambda 関数群 / arm64 + Python 3.12]
  - list-items    GET    /items
  - get-item      GET    /items/{id}
  - create-item   POST   /items
  - update-item   PUT    /items/{id}
  - delete-item   DELETE /items/{id}
      ↓
[DynamoDB — Single Table Design]
  - GSI-1: user-index（ユーザー別一覧）
  - GSI-2: status-index（ステータス別一覧）
  - TTL: expires_at（ARCHIVED から 30 日後に自動削除）
  - DynamoDB Accelerator（DAX）← prod のみ
      ↓ Streams
[Lambda: stream-processor]
  - 変更イベントを S3 に監査ログとして保存
      ↓
[S3: audit-logs]
  - STANDARD_IA（30 日後）→ Glacier（90 日後）→ 削除（7 年後）
```

---

## ディレクトリ構成

```
serverless-api-platform/
├── Makefile                        # make init / plan / apply / test / deploy
├── scripts/
│   └── bootstrap.sh                # Terraform バックエンド（S3 + DynamoDB）作成
├── terraform/
│   ├── environments/
│   │   ├── dev/                    # dev 環境（WAF・Cognito・DAX なし）
│   │   │   ├── backend.tf
│   │   │   ├── providers.tf
│   │   │   ├── variables.tf
│   │   │   ├── main.tf
│   │   │   ├── outputs.tf
│   │   │   └── github-oidc.tf      # GitHub Actions OIDC ロール
│   │   └── prod/                   # prod 環境（全機能有効）
│   └── modules/
│       ├── lambda-function/        # Lambda 共通モジュール
│       ├── api-gateway/            # REST API・ステージ・WAF
│       ├── dynamodb/               # テーブル・GSI・Streams・DAX
│       ├── iam/                    # 実行ロール（最小権限）
│       ├── monitoring/             # CloudWatch アラーム・ダッシュボード
│       └── storage/                # S3 監査ログバケット
├── src/
│   ├── shared/                     # 共有ライブラリ
│   │   ├── models.py               # Pydantic データモデル
│   │   ├── repository.py           # DynamoDB アクセス層
│   │   ├── exceptions.py           # カスタム例外クラス
│   │   └── response.py             # API レスポンス共通フォーマット
│   ├── list_items/
│   ├── get_item/
│   ├── create_item/
│   ├── update_item/
│   ├── delete_item/
│   └── stream_processor/
├── tests/
│   ├── unit/                       # moto モック使用
│   └── integration/                # デプロイ済み API に対する E2E テスト
└── .github/
    └── workflows/
        ├── ci.yml                  # PR: lint → test → terraform plan
        └── cd.yml                  # main: apply → smoke test
```

---

## 技術スタック

| カテゴリ | 使用技術 |
|---|---|
| IaC | Terraform ~> 1.7、AWS Provider ~> 5.50 |
| コンピュート | Lambda（arm64 / Python 3.12）|
| API | API Gateway REST API (v1) |
| データベース | DynamoDB（Single Table Design、PAY_PER_REQUEST）|
| キャッシュ | DAX（prod のみ）|
| 認証 | Cognito User Pool + API Gateway オーソライザー |
| セキュリティ | WAF v2（レートリミット・IP 制限）|
| ロギング | AWS Lambda Powertools（構造化 JSON ログ）|
| トレーシング | X-Ray + Powertools Tracer |
| メトリクス | CloudWatch + Powertools Metrics |
| CI/CD | GitHub Actions（OIDC 認証）|
| テスト | pytest + moto（DynamoDB モック）|

---

## 構築進行状況

### 凡例
- ✅ 完了
- 🚧 作業中 / 一部完了
- ⬜ 未着手

---

### Phase 1: プロジェクト基盤 ✅

| タスク | 状態 | 備考 |
|---|---|---|
| ディレクトリ構成・プロジェクト骨格 | ✅ | CLAUDE.md に従った構成 |
| `.gitignore` | ✅ | Terraform / Python / Lambda zip |
| `Makefile` | ✅ | 8 ターゲット（bootstrap / init / plan / apply / destroy / fmt / lint / test / deploy）|
| `scripts/bootstrap.sh` | ✅ | S3（KMS・バージョニング・HTTPS 強制）+ DynamoDB 作成 |
| `terraform/environments/dev/backend.tf` | ✅ | S3 リモートステート + DynamoDB ロック |
| `terraform/environments/dev/providers.tf` | ✅ | `default_tags` で全リソースに共通タグ付与 |
| `terraform/environments/dev/variables.tf` | ✅ | environment / project / account_id / alert_email / allowed_ips |
| `terraform/environments/dev/github-oidc.tf` | ✅ | OIDC プロバイダ + IAM ロール（main ブランチ限定）|
| `terraform/environments/prod/` | ✅ | dev と同構成・変数のみ差異 |

---

### Phase 2: Terraform モジュール ✅

| モジュール | 状態 | 備考 |
|---|---|---|
| `modules/dynamodb` | ✅ | Single Table Design・GSI×2・Streams・TTL・PITR・DAX（prod のみ）|
| `modules/iam` | ✅ | 関数ごとの最小権限ロール（`*` リソース指定なし）|
| `modules/storage` | ✅ | 監査ログ S3（ライフサイクル・暗号化・パブリックアクセスブロック）|
| `modules/lambda-function` | ✅ | arm64・X-Ray・JSON ログ・イベントソースマッピング |
| `modules/api-gateway` | ✅ | REST API・ステージ・Cognito オーソライザー（オプション）|
| `modules/monitoring` | ✅ | SNS アラーム（Errors / Throttles / 5xx）・CloudWatch ダッシュボード |
| `environments/dev/main.tf` | ✅ | 全モジュールを結合 |
| `modules/cognito` | ⬜ | User Pool・App Client（未作成） |

---

### Phase 3: Lambda ソースコード ✅

| 関数 | 状態 | 備考 |
|---|---|---|
| `src/shared/models.py` | ✅ | Pydantic v2・CreateItemRequest / UpdateItemRequest / Item |
| `src/shared/repository.py` | ✅ | CRUD・GSI Query（Scan 禁止）・ページネーション |
| `src/shared/exceptions.py` | ✅ | ItemNotFoundError / ForbiddenError / ValidationError など |
| `src/shared/response.py` | ✅ | success / paginated / error の共通フォーマット |
| `src/list_items/handler.py` | ✅ | GSI-1 (user-index) Query・カーソルページネーション |
| `src/get_item/handler.py` | ✅ | GetItem・所有者チェック |
| `src/create_item/handler.py` | ✅ | PutItem・条件式で重複防止 |
| `src/update_item/handler.py` | ✅ | UpdateItem・部分更新・所有者チェック |
| `src/delete_item/handler.py` | ✅ | DeleteItem・所有者チェック |
| `src/stream_processor/handler.py` | ✅ | ReportBatchItemFailures・S3 監査ログ保存 |

全 Lambda に [AWS Lambda Powertools](https://docs.powertools.aws.dev/lambda/python/latest/) を適用済み:
- `@logger.inject_lambda_context` — 構造化 JSON ログ + correlation_id
- `@tracer.capture_lambda_handler` — X-Ray トレーシング
- `@metrics.log_metrics` — コールドスタートメトリクス自動計測

---

### Phase 4: テスト ✅

| テスト | 状態 | 備考 |
|---|---|---|
| `tests/unit/test_create_item.py` | ✅ | 正常系・バリデーションエラー・認証エラー |
| `tests/unit/test_list_items.py` | ✅ | 一覧取得・空リスト・limit パラメータ |
| `tests/unit/test_update_item.py` | ✅ | 更新・404・403・空ボディ |
| `tests/unit/test_repository.py` | ✅ | CRUD・GSI クエリ・所有者分離 |
| `tests/integration/test_api_e2e.py` | ✅ | CRUD フロー全体（`API_ENDPOINT` 未設定時はスキップ）|
| `tests/unit/test_delete_item.py` | ⬜ | 未作成 |

---

### Phase 5: CI/CD ✅

| ファイル | 状態 | 備考 |
|---|---|---|
| `.github/workflows/ci.yml` | ✅ | PR: ruff lint → pytest（カバレッジ 80% 以上）→ terraform plan → PR コメント |
| `.github/workflows/cd.yml` | ✅ | main push: terraform apply → smoke test |
| GitHub Secrets 設定 | ⬜ | `AWS_ROLE_ARN` / `TF_VAR_account_id` / `TF_VAR_alert_email` の登録が必要 |

---

### Phase 6: 残作業 ⬜

| タスク | 優先度 | 備考 |
|---|---|---|
| `modules/cognito` の作成 | 高 | User Pool・App Client・`dev/main.tf` への組み込み |
| `modules/api-gateway` に WAF 実装を追加 | 高 | WAF v2 WebACL・レートリミット・IP 許可リスト |
| `tests/unit/test_delete_item.py` の追加 | 中 | |
| `docs/architecture.md` | 中 | Mermaid アーキテクチャ図 |
| `docs/api-spec.yaml` | 中 | OpenAPI 3.0 仕様書 |
| `docs/adr/` | 低 | ADR-001〜003（設計上の意思決定の記録）|
| `docs/runbook.md` | 低 | 障害対応手順書 |
| カスタムドメイン（Route53 + ACM）| 低 | prod のみ |
| GitHub Secrets の登録 | 高 | CI/CD の実行に必要 |
| `terraform/environments/dev/backend.tf` の `<account_id>` を実際の値に更新 | 高 | 初回 `make init` 前に必須 |
| `github-oidc.tf` の `github_org` を実際の org 名に更新 | 高 | OIDC 設定 |

---

## クイックスタート

### 前提条件

- Terraform >= 1.7
- AWS CLI v2（`aws configure` 設定済み）
- Python 3.12
- `make` コマンド

### 1. リポジトリのクローン

```bash
git clone https://github.com/<your-org>/serverless-api-platform.git
cd serverless-api-platform
```

### 2. 初期設定

```bash
# backend.tf の <account_id> を実際のアカウント ID に置き換える
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
sed -i "s/<account_id>/${ACCOUNT_ID}/g" \
  terraform/environments/dev/backend.tf \
  terraform/environments/prod/backend.tf

# github-oidc.tf の github_org / github_repo を編集する
vi terraform/environments/dev/github-oidc.tf
```

### 3. Terraform バックエンドの作成（初回のみ）

```bash
make bootstrap
```

### 4. デプロイ

```bash
make init ENV=dev
make plan ENV=dev
make apply ENV=dev
```

### 5. API エンドポイントの確認

```bash
cd terraform/environments/dev
terraform output api_endpoint
# => https://xxxxxxxxxx.execute-api.ap-northeast-1.amazonaws.com/dev
```

### 6. 動作確認（dev 環境は Cognito 認証なし）

```bash
API=$(cd terraform/environments/dev && terraform output -raw api_endpoint)

# アイテム作成
curl -X POST "${API}/items?user_id=test-user" \
  -H "Content-Type: application/json" \
  -d '{"name": "テストアイテム", "description": "説明"}'

# 一覧取得
curl "${API}/items?user_id=test-user"
```

### 7. ユニットテストの実行

```bash
make test
```

---

## 環境差異（dev vs prod）

| 機能 | dev | prod |
|---|---|---|
| Cognito 認証 | 無効（`?user_id=` パラメータで代替）| 有効 |
| WAF | 無効 | 有効（レートリミット・IP 制限）|
| DAX | 無効 | 有効（DynamoDB インメモリキャッシュ）|
| PITR | 無効 | 有効（ポイントインタイムリカバリ）|
| ログ保持期間 | 14 日 | 90 日 |
| 月額コスト目安 | ~$1 | ~$20〜 |

---

## API 仕様

### エンドポイント

| メソッド | パス | 説明 |
|---|---|---|
| GET | `/items` | アイテム一覧（ページネーション対応）|
| GET | `/items/{id}` | アイテム取得 |
| POST | `/items` | アイテム作成 |
| PUT | `/items/{id}` | アイテム更新（部分更新）|
| DELETE | `/items/{id}` | アイテム削除 |

### レスポンスフォーマット

```json
// 成功
{
  "success": true,
  "data": { "item_id": "...", "name": "...", "status": "ACTIVE", ... },
  "meta": { "request_id": "...", "timestamp": "2024-01-15T12:00:00Z" }
}

// エラー
{
  "success": false,
  "error": { "code": "ITEM_NOT_FOUND", "message": "...", "request_id": "..." }
}

// 一覧（ページネーション）
{
  "success": true,
  "data": [ ... ],
  "pagination": { "next_cursor": "base64==", "has_more": true, "count": 20 }
}
```

### エラーコード

| コード | HTTP | 説明 |
|---|---|---|
| `ITEM_NOT_FOUND` | 404 | 指定した ID のアイテムが存在しない |
| `VALIDATION_ERROR` | 400 | リクエストボディのバリデーションエラー |
| `UNAUTHORIZED` | 401 | 認証情報が不正または未指定 |
| `FORBIDDEN` | 403 | 他ユーザーのアイテムへのアクセス |
| `INTERNAL_ERROR` | 500 | サーバー内部エラー |

---

## DynamoDB テーブル設計

**Single Table Design** を採用。複数エンティティを1テーブルに集約し、GSI で各アクセスパターンに対応する。

```
テーブル名: sap-<env>-items

PK: ITEM#<item_id>
SK: ITEM#<item_id>

GSI-1 (user-index):  user_id → created_at（ユーザー別一覧、降順）
GSI-2 (status-index): status → created_at（ステータス別一覧、管理用）

TTL: expires_at（ARCHIVED から 30 日後に自動削除）
Streams: NEW_AND_OLD_IMAGES（監査ログ用）
```

> **注意**: DynamoDB の `Scan` API は使用禁止。一覧取得は必ず GSI を使った `Query` で行う（フルスキャンによるコスト増大を防ぐため）。

---

## CI/CD パイプライン

```
PR オープン
  → ci.yml
      ├── Python: ruff lint + pytest（カバレッジ 80% 以上）
      ├── Terraform: fmt check + tflint
      └── Terraform: plan → PR にコメント投稿

main マージ
  → cd.yml
      ├── Terraform: apply（dev 環境）
      └── 統合テスト（smoke test）
```

GitHub Actions は OIDC 認証で AWS にアクセスする（長期的な IAM アクセスキー不要）。
認証ロールは `main` ブランチからのリクエストのみに制限されている。

---

## コスト管理

| リソース | 月額目安（dev）|
|---|---|
| Lambda（arm64）| ~$0（無料枠内）|
| API Gateway | ~$0（無料枠内）|
| DynamoDB（PAY_PER_REQUEST）| ~$0（無料枠内）|
| S3（監査ログ）| ~$0.01 |
| CloudWatch Logs | ~$0.50 |
| **合計** | **~$1 以下** |

- arm64 アーキテクチャで x86_64 より約 20% コスト削減
- dev 環境では DAX・WAF を無効化してコストを最小化

---

## 設計上の意思決定（ADR）

| # | タイトル | 決定 |
|---|---|---|
| 001 | Single Table Design vs Multi Table | Single Table を採用（アクセスパターンが明確なため）|
| 002 | Cognito vs カスタム認証 | Cognito を採用（Lambda 側でのトークン検証を排除）|
| 003 | REST API vs HTTP API | REST API (v1) を採用（リクエストバリデーション機能が必要なため）|

詳細は `docs/adr/` を参照（未作成）。
