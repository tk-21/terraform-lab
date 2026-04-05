# ADR-002: 認証に Amazon Cognito + API Gateway Authorizer を採用

- **ステータス**: 採用済み
- **決定日**: 2024-01-15
- **決定者**: platform-team

---

## 背景

REST API の認証方式として以下の 3 つを検討した。

1. **Amazon Cognito + API Gateway Cognito Authorizer**（JWT 検証を AWS インフラに委譲）
2. **カスタム Lambda Authorizer**（Lambda で JWT を自前検証）
3. **API Key 認証**（API Gateway の API Key 機能を使用）

---

## 決定

**Amazon Cognito + API Gateway Cognito Authorizer を採用する。**

---

## 採用理由

### 1. JWT 検証ロジックをアプリケーションから分離できる

Cognito Authorizer を使うと、API Gateway が Lambda を呼び出す前に JWT の
有効性（署名・有効期限・issuer）を検証する。

Lambda 関数はすでに検証済みのクレームを `requestContext.authorizer.claims` として受け取るだけでよい。

```python
# Lambda 側の認証処理はこれだけ
def _get_user_id(event: dict) -> str:
    claims = event.get("requestContext", {}).get("authorizer", {}).get("claims", {})
    user_id = claims.get("sub")
    if not user_id:
        raise UnauthorizedError("認証が必要です")
    return user_id
```

### 2. セキュリティリスクの低減

自前で JWT 検証を実装すると、以下のようなミスが発生しやすい。

- `alg: none` 攻撃（アルゴリズムを none に変更した JWT を受け入れてしまう）
- 有効期限（`exp` クレーム）の検証漏れ
- 発行者（`iss` クレーム）の不一致を見落とす

Cognito Authorizer はこれらをすべて AWS マネージドで処理するため、
アプリケーションレベルの脆弱性リスクが大幅に低下する。

### 3. ユーザー管理機能が付属する

Cognito は JWT 認証だけでなく、以下の機能を追加コストなしで提供する。

| 機能 | 詳細 |
|---|---|
| ユーザー登録・メール確認 | AdminCreateUser / SignUp フロー |
| パスワードポリシー | 最小長・複雑度を Terraform で定義 |
| MFA | TOTP・SMS（オプション） |
| トークンリフレッシュ | Refresh Token で自動更新 |
| グループ管理 | Admin / Regular User などのロール分離 |

これらを自前実装するコストは非常に高い。

### 4. Cognito の無料枠が十分

dev 環境では MAU 50,000 ユーザーまで無料。
本プロジェクトの規模では実質コストゼロ。

---

## 認証フロー

```
クライアント
  │
  ├─ 1. Cognito に USER_PASSWORD_AUTH でログイン
  │      → ID Token（JWT）を取得
  │
  ├─ 2. API Gateway に Bearer JWT でリクエスト
  │      Authorization: Bearer <ID Token>
  │
  ├─ 3. API Gateway の Cognito Authorizer が JWT を検証
  │      - 署名検証（Cognito の JWKS エンドポイントを使用）
  │      - 有効期限確認
  │      - issuer / audience 確認
  │      - 検証失敗 → 401 Unauthorized（Lambda まで到達しない）
  │
  └─ 4. 検証成功 → Lambda に claims を付与して呼び出し
         event.requestContext.authorizer.claims.sub = ユーザーID
```

---

## ID Token vs Access Token

本プロジェクトでは **ID Token** を使用する。

| トークン種別 | 用途 | 使用理由 |
|---|---|---|
| ID Token | ユーザー情報（sub, email 等）を含む JWT | API Gateway Cognito Authorizer のデフォルト |
| Access Token | スコープベースの認可 | Lambda Authorizer が必要（複雑度が増す） |
| Refresh Token | ID/Access Token の再発行 | クライアント側で管理 |

Cognito Authorizer は ID Token の `sub` を `requestContext.authorizer.claims.sub` として
Lambda に渡す。Lambda は `sub` を `user_id` として DynamoDB のオーナーシップ確認に使用する。

---

## ユーザーとアイテムの所有権チェック

認証とは別に、アイテムの所有権チェックも実装している。

```python
# get_item / update_item / delete_item ハンドラー共通パターン
item = repository.get(item_id)        # DynamoDB から取得
if item.user_id != user_id:           # 所有者チェック
    raise ForbiddenError(...)         # → 403 Forbidden
```

**設計上の注意点**: アイテムが存在しない場合は 404、
存在するが他ユーザーのものの場合は 403 を返す（404 で統一しない）。
403 を返すことで「アイテムは存在するが権限がない」ことを明示し、
デバッグ時の問題特定を容易にする。

---

## トレードオフ・注意点

### デメリット

| 項目 | 内容 |
|---|---|
| Cognito 依存 | AWS 以外のクラウドへの移行コストが増える |
| カスタム属性の制限 | Cognito のユーザー属性はスキーマ変更が不可（追加は可） |
| トークン有効期限 | ID Token のデフォルト有効期限は 1 時間（変更可能） |

### 緩和策

- Cognito への依存は Lambda 内の `_get_user_id()` 関数に局所化されている
- 将来的に認証プロバイダを変更する場合は、この関数を差し替えるだけでよい

---

## 却下した代替案

### カスタム Lambda Authorizer

```
API Gateway → Lambda Authorizer → Lambda 本体
```

**却下理由**:
- JWT 検証ロジックの自前実装はセキュリティリスクが高い（前述）
- Lambda Authorizer の実行コスト（追加の Lambda 呼び出し）が発生する
- キャッシュ設定を誤るとセキュリティホールになる
- 本プロジェクトの要件（シンプルな JWT 検証）に対してオーバーエンジニアリング

### API Key 認証

**却下理由**:
- ユーザーごとの認証・認可ができない（全ユーザーが同じキーを使う）
- ユーザー識別情報を Lambda に渡す仕組みがない
- アイテムのオーナーシップ管理が実現できない

---

## 参考

- [Amazon Cognito - API Gateway との統合](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-integrate-with-cognito.html)
- [JWT セキュリティベストプラクティス (RFC 8725)](https://datatracker.ietf.org/doc/html/rfc8725)
