# terraform/modules/cognito/main.tf
#
# API 認証基盤として Cognito User Pool を実装する。
# API Gateway オーソライザーが JWT を検証する構成のため、
# Cognito はトークン発行（IdP）に徹し、アプリ側での検証は行わない。

locals {
  # 命名規則: sap-<env>-user-pool / sap-<env>-api-client / sap-<env>-auth
  user_pool_name   = "${var.prefix}-user-pool"
  app_client_name  = "${var.prefix}-api-client"
  domain_prefix    = "${var.prefix}-auth"
}

# ============================================================
# Cognito User Pool
# ============================================================
resource "aws_cognito_user_pool" "this" {
  name = local.user_pool_name

  # ============================================================
  # パスワードポリシー
  # ============================================================
  # NIST SP 800-63B に準拠した最低限のポリシー。
  # 大文字・小文字・数字・記号をすべて要求することで
  # 辞書攻撃・ブルートフォース攻撃への耐性を高める。
  password_policy {
    minimum_length                   = 8
    require_uppercase                = true
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
  }

  # ============================================================
  # MFA 設定
  # ============================================================
  # OPTIONAL を選択した理由:
  # OFF にするとセキュリティリスクが高く、REQUIRED にすると
  # 初期ユーザー登録のハードルが上がり離脱率が増加する。
  # OPTIONAL にすることで、セキュリティ意識の高いユーザーは MFA を
  # 有効化でき、それ以外のユーザーも摩擦なく利用できる。
  # ポートフォリオ用途では「MFA 対応済み」をアピールしつつ、
  # テスト・デモの利便性も確保する。
  # prod 運用フェーズでセキュリティ要件が厳しくなった場合は
  # REQUIRED への変更を検討すること。
  mfa_configuration = "OPTIONAL"

  software_token_mfa_configuration {
    # TOTP（Google Authenticator 等）による MFA を有効化。
    # SMS MFA より安価で SIM スワップ攻撃に強い。
    enabled = true
  }

  # ============================================================
  # ユーザー属性スキーマ
  # ============================================================
  # email: 認証フロー（パスワードリセット・検証）に必須。
  #        mutable = false にして変更を禁止することで
  #        アカウント乗っ取りリスクを低減する。
  schema {
    name                     = "email"
    attribute_data_type      = "String"
    required                 = true
    mutable                  = false

    string_attribute_constraints {
      min_length = 5
      max_length = 256
    }
  }

  # name: 表示名として任意で登録する。
  #       mutable = true でプロフィール更新を許可する。
  schema {
    name                     = "name"
    attribute_data_type      = "String"
    required                 = false
    mutable                  = true

    string_attribute_constraints {
      min_length = 1
      max_length = 256
    }
  }

  # ============================================================
  # 自動検証・ユーザー名属性
  # ============================================================
  # email をユーザー名として使用し、登録時に検証コードを送信する。
  # これにより使い捨てアドレスや誤入力を抑制できる。
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  username_configuration {
    # 大文字小文字を区別しない（User@example.com == user@example.com）
    case_sensitive = false
  }

  # ============================================================
  # アカウント復旧設定
  # ============================================================
  # email のみをアカウント復旧手段として設定。
  # SMS は SIM スワップ攻撃のリスクがあるため除外する。
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email_only"
      priority = 1
    }
  }

  # ============================================================
  # メール送信設定
  # ============================================================
  # dev では Cognito デフォルトの SES（1日50通制限）を使用。
  # prod では SES の送信元ドメインを設定することを推奨。
  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  # ============================================================
  # 削除保護
  # ============================================================
  # prod では ACTIVE にして誤削除を防止する（var.enable_deletion_protection）。
  # dev では INACTIVE にして terraform destroy を容易にする。
  deletion_protection = var.enable_deletion_protection ? "ACTIVE" : "INACTIVE"

  tags = var.tags
}

# ============================================================
# Cognito User Pool App Client
# ============================================================
resource "aws_cognito_user_pool_client" "api" {
  name         = local.app_client_name
  user_pool_id = aws_cognito_user_pool.this.id

  # ============================================================
  # クライアントシークレット: 不使用
  # ============================================================
  # generate_secret = false（デフォルト）を明示。
  # SPA（React 等）やモバイルアプリはソースコードが公開されるため、
  # クライアントシークレットを埋め込むと漏洩リスクが生じる。
  # Public Client（シークレットなし）として構成し、
  # PKCE（Proof Key for Code Exchange）フローを利用する設計とする。
  # クライアントシークレットが必要な場合はサーバーサイドの
  # 別クライアントを作成すること。
  generate_secret = false

  # ============================================================
  # 認証フロー
  # ============================================================
  # ALLOW_USER_PASSWORD_AUTH:
  #   email + パスワードによる直接認証。
  #   API テスト・デモ用途で利用する。
  #   prod では ALLOW_USER_SRP_AUTH に切り替えることを推奨
  #   （SRP はパスワードをネットワーク上に流さないため安全）。
  # ALLOW_REFRESH_TOKEN_AUTH:
  #   アクセストークン失効後にリフレッシュトークンで再取得する。
  #   ユーザーが再ログインしなくて済むよう必須で有効化する。
  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  # ============================================================
  # トークン有効期限
  # ============================================================
  # アクセストークン: 1時間（短め設定でトークン漏洩リスクを低減）
  # リフレッシュトークン: 30日（UX と安全性のバランス）
  # IDトークン: アクセストークンと合わせる
  access_token_validity  = 1   # 単位: hours
  refresh_token_validity = 30  # 単位: days
  id_token_validity      = 1   # 単位: hours

  token_validity_units {
    access_token  = "hours"
    refresh_token = "days"
    id_token      = "hours"
  }

  # ============================================================
  # 読み取り・書き込み属性
  # ============================================================
  # Lambda や API Gateway がトークンから参照できる属性を明示する。
  read_attributes  = ["email", "name", "email_verified"]
  write_attributes = ["email", "name"]

  # ============================================================
  # OAuth 設定（将来の Hosted UI 対応用）
  # ============================================================
  # 現在は直接認証フローのみ使用するが、
  # ソーシャルログイン追加時に備えて oauth_flows を定義しておく。
  supported_identity_providers = ["COGNITO"]

  # prevent_user_existence_errors:
  # ENABLED にすると存在しないユーザーへの認証試行に対して
  # 「ユーザーが見つかりません」ではなく汎用エラーを返す。
  # ユーザー列挙攻撃（User Enumeration Attack）を防止する。
  prevent_user_existence_errors = "ENABLED"
}

# ============================================================
# Cognito User Pool Domain（ホストされた UI）
# ============================================================
# Cognito が提供するホスト済み認証 UI（ログイン・登録・パスワードリセット）を
# 使用するためのドメインプレフィックスを設定する。
# URL 形式: https://<prefix>.auth.<region>.amazoncognito.com
# カスタムドメインが必要な場合は aws_cognito_user_pool_domain の
# domain に ACM 証明書 ARN を追加すること。
resource "aws_cognito_user_pool_domain" "this" {
  domain       = local.domain_prefix
  user_pool_id = aws_cognito_user_pool.this.id
}
