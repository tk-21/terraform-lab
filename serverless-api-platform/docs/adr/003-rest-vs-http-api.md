# ADR-003: API Gateway REST API (v1) vs HTTP API (v2) の選択

- **ステータス**: 採用済み
- **決定日**: 2024-01-15
- **決定者**: platform-team

---

## 背景

Amazon API Gateway には 2 つの主要なフレーバーが存在する。

1. **REST API (v1)**: 旧来の API Gateway。機能が豊富だがコストが高い
2. **HTTP API (v2)**: 2019年にリリースされた新世代。REST API より ~70% 安価で低レイテンシ

本プロジェクトでどちらを採用するかを検討した。

---

## 決定

**REST API (v1) を採用する。**

---

## 採用理由

### 1. API Gateway ネイティブのリクエストバリデーション

REST API は JSON スキーマによるリクエストボディのバリデーションを API Gateway 側で実行できる。

```hcl
resource "aws_api_gateway_request_validator" "body" {
  validate_request_body = true
}

resource "aws_api_gateway_model" "create_item" {
  schema = jsonencode({
    type     = "object"
    required = ["name"]
    properties = {
      name = { type = "string", minLength = 1, maxLength = 100 }
    }
  })
}
```

**メリット**: 不正なリクエストが Lambda まで到達しないため、Lambda の起動コストを削減できる。

HTTP API (v2) はこの機能を持たない。すべてのバリデーションを Lambda 側で行う必要がある。

### 2. Cognito Authorizer の TTL 設定

REST API の Cognito Authorizer は検証結果をキャッシュできる（`authorizer_result_ttl_in_seconds`）。
同一トークンの繰り返し検証をスキップするため、レイテンシとコストを削減できる。

```hcl
resource "aws_api_gateway_authorizer" "cognito" {
  type = "COGNITO_USER_POOLS"
  # 検証結果を5分間キャッシュ
  authorizer_result_ttl_in_seconds = 300
}
```

HTTP API (v2) の JWT Authorizer にはキャッシュ機能がない（毎リクエスト検証が走る）。

### 3. 詳細なアクセスログとメトリクス

REST API はメソッドレベルの詳細なメトリクス（Latency・Count・4xx・5xx）を CloudWatch に記録できる。

```hcl
resource "aws_api_gateway_method_settings" "all" {
  settings {
    logging_level          = "INFO"
    metrics_enabled        = true
    data_trace_enabled     = false  # PII 保護のため false
    throttling_rate_limit  = 1000
    throttling_burst_limit = 500
  }
}
```

HTTP API (v2) のメトリクスはステージレベルのみで、メソッドレベルの細かい分析ができない。

### 4. メソッドレベルのスロットリング設定

REST API はメソッドごとに異なるスロットリング設定（rate_limit・burst_limit）を適用できる。
本プロジェクトでは全メソッド同一設定だが、将来的に `POST /items` だけレート制限を強化するなど
の細かいチューニングが可能になる。

HTTP API (v2) はステージレベルのスロットリングのみ。

---

## コスト比較

| 項目 | REST API (v1) | HTTP API (v2) |
|---|---|---|
| リクエスト料金 (最初の 3 億件) | $3.50 / 100 万リクエスト | $1.00 / 100 万リクエスト |
| データ転送 | 別途 | 別途 |
| Cognito Authorizer キャッシュ | あり（コスト削減可） | なし |
| Lambda バリデーション不要 | あり（コスト削減可） | なし |

**月 100 万リクエスト時のコスト差**: 約 $2.50/月。

本プロジェクトの想定トラフィックでは誤差範囲。機能面の優位性を優先する。

---

## 却下した代替案

### HTTP API (v2)

```hcl
resource "aws_apigatewayv2_api" "this" {
  protocol_type = "HTTP"
}
```

**却下理由**:
- リクエストボディのバリデーションを Lambda 側で実装する必要があり、コードが複雑になる
- Cognito JWT の検証結果がキャッシュされず、毎リクエスト検証コストが発生する
- メソッドレベルのメトリクスが取れず、可観測性が低下する
- 月 $2.50 程度のコスト差は、機能面のデメリットを上回らない

---

## 将来の見直し条件

以下の条件が揃った場合は HTTP API (v2) への移行を再検討する。

1. トラフィックが月 1,000 万リクエストを超え、コスト差が無視できなくなった場合
2. HTTP API (v2) がリクエストバリデーション機能を提供した場合
3. WAF を前段に置き、API Gateway のバリデーション機能が不要になった場合

---

## 参考

- [Choosing between REST APIs and HTTP APIs](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-vs-rest.html)
- [Amazon API Gateway pricing](https://aws.amazon.com/api-gateway/pricing/)
