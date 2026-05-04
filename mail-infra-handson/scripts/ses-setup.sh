#!/bin/bash
set -euo pipefail

# SES SMTPクレデンシャルの生成とPostfix設定スクリプト
#
# SES SMTPクレデンシャルはIAMアクセスキーから独自アルゴリズムで変換して生成する
# 通常のIAMアクセスキー（AKIA...）とは異なり、SMTP専用の変換処理が必要
#
# 生成アルゴリズム（AWS公式ドキュメント準拠）:
#   signature = HMAC-SHA256(
#     HMAC-SHA256(
#       HMAC-SHA256(
#         HMAC-SHA256("AWS4" + secret_key, "11111111"),
#         region
#       ),
#       "ses"
#     ),
#     "aws4_request"
#   )
#   smtp_password = Base64(version_byte[0x04] + signature)
#
# 参考: https://docs.aws.amazon.com/ses/latest/dg/smtp-credentials.html
# 注意: aws ses generate-smtp-data-token コマンドは廃止済みのためこのスクリプトを使用する

REGION="${AWS_REGION:-ap-northeast-1}"
SES_SMTP_ENDPOINT="email-smtp.${REGION}.amazonaws.com"
IAM_USER_NAME="mail-handson-ses-smtp-user"
SASL_PASSWD_FILE="/etc/postfix/sasl_passwd"

# --- ログ出力ヘルパー ---
info()  { echo -e "\033[0;36m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[0;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

# --- 前提条件チェック ---
check_prerequisites() {
    info "前提条件を確認中..."

    for cmd in aws python3 postmap postfix; do
        if ! command -v "$cmd" &>/dev/null; then
            error "必須コマンドが見つかりません: ${cmd}"
            exit 1
        fi
    done

    if [[ $EUID -ne 0 ]]; then
        error "このスクリプトはroot権限で実行してください"
        error "  sudo ${0}"
        exit 1
    fi

    # AWS認証情報の確認
    if ! aws sts get-caller-identity &>/dev/null; then
        error "AWS認証情報が設定されていません"
        error "  aws configure または IAMロールを確認してください"
        exit 1
    fi

    ok "前提条件を確認しました"
}

# --- SES送信専用IAMユーザー作成 ---
create_iam_user() {
    info "IAMユーザーを確認: ${IAM_USER_NAME}"

    if aws iam get-user --user-name "$IAM_USER_NAME" &>/dev/null; then
        warn "IAMユーザーは既に存在します（スキップ）: ${IAM_USER_NAME}"
        return
    fi

    aws iam create-user --user-name "$IAM_USER_NAME" --tags Key=Project,Value=mail-infra-handson

    # SES送信専用ポリシー: ses:SendRawEmail のみ付与（最小権限）
    # SendRawEmail は Postfix が使用するメール送信の唯一必要なアクション
    aws iam put-user-policy \
        --user-name "$IAM_USER_NAME" \
        --policy-name "ses-send-raw-email-only" \
        --policy-document '{
            "Version": "2012-10-17",
            "Statement": [{
                "Sid": "AllowSESSendRawEmail",
                "Effect": "Allow",
                "Action": ["ses:SendRawEmail"],
                "Resource": "*"
            }]
        }'

    ok "IAMユーザーを作成しました: ${IAM_USER_NAME}"
}

# --- IAMアクセスキー生成 ---
generate_access_key() {
    info "IAMアクセスキーを生成中..."

    # IAMユーザーのアクセスキーは最大2つまでの制限がある
    # 既存キーが2つある場合は最古のキーを削除してから新規作成する
    KEY_COUNT=$(aws iam list-access-keys \
        --user-name "$IAM_USER_NAME" \
        --query 'length(AccessKeyMetadata)' \
        --output text)

    if [[ $KEY_COUNT -ge 2 ]]; then
        OLDEST_KEY=$(aws iam list-access-keys \
            --user-name "$IAM_USER_NAME" \
            --query 'AccessKeyMetadata | sort_by(@, &CreateDate)[0].AccessKeyId' \
            --output text)
        warn "アクセスキーが上限(2)に達しています。最古のキーを削除: ${OLDEST_KEY}"
        aws iam delete-access-key --user-name "$IAM_USER_NAME" --access-key-id "$OLDEST_KEY"
    fi

    KEY_JSON=$(aws iam create-access-key --user-name "$IAM_USER_NAME")
    ACCESS_KEY_ID=$(echo "$KEY_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessKey']['AccessKeyId'])")
    SECRET_ACCESS_KEY=$(echo "$KEY_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessKey']['SecretAccessKey'])")

    ok "アクセスキーを生成しました: ${ACCESS_KEY_ID}"
}

# --- SMTPパスワード変換 ---
# IAMシークレットアクセスキーをSES SMTPパスワードに変換する
# AWS公式アルゴリズム（HMAC-SHA256 SigV4ベース）を使用
convert_to_smtp_password() {
    info "SMTPパスワードに変換中..."

    SMTP_PASSWORD=$(python3 - <<'PYEOF'
import hmac
import hashlib
import base64
import os
import sys

def sign(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()

def generate_smtp_password(secret_access_key: str, region: str) -> str:
    # AWS SES SMTP パスワード生成アルゴリズム（Version 4）
    # 参考: https://docs.aws.amazon.com/ses/latest/dg/smtp-credentials.html
    DATE     = "11111111"
    SERVICE  = "ses"
    TERMINAL = "aws4_request"
    MESSAGE  = "SendRawEmail"
    VERSION  = 0x04  # SMTPパスワードのバージョンバイト

    signature = sign(
        sign(
            sign(
                sign(
                    ("AWS4" + secret_access_key).encode("utf-8"),
                    DATE,
                ),
                region,
            ),
            SERVICE,
        ),
        TERMINAL,
    )

    # バージョンバイト(0x04) + 署名 を Base64エンコードしてSMTPパスワードとする
    smtp_password = base64.b64encode(bytes([VERSION]) + signature).decode("utf-8")
    return smtp_password

secret = os.environ.get("_SES_SECRET_KEY", "")
region = os.environ.get("_SES_REGION", "ap-northeast-1")

if not secret:
    print("ERROR: _SES_SECRET_KEY が設定されていません", file=sys.stderr)
    sys.exit(1)

print(generate_smtp_password(secret, region))
PYEOF
)

    ok "SMTPパスワードを生成しました"
}

# --- Postfix設定 ---
configure_postfix() {
    info "Postfix SASL認証設定を更新: ${SASL_PASSWD_FILE}"

    # sasl_passwd: Postfixがリレーホストへの認証に使う認証情報ファイル
    # 形式: [ホスト名]:ポート ユーザー名:パスワード
    cat > "$SASL_PASSWD_FILE" << EOF
[${SES_SMTP_ENDPOINT}]:587 ${ACCESS_KEY_ID}:${SMTP_PASSWORD}
EOF

    # postmap: sasl_passwd をBerkeleyDBハッシュファイル（.db）に変換する
    # Postfixは .db ファイルを読み込むため、ファイル更新後は必ず実行する
    postmap "$SASL_PASSWD_FILE"

    # 認証情報ファイルのパーミッションを制限（rootのみ読み書き可能）
    chmod 600 "$SASL_PASSWD_FILE" "${SASL_PASSWD_FILE}.db"
    chown root:root "$SASL_PASSWD_FILE" "${SASL_PASSWD_FILE}.db"

    # Postfix main.cf にSESリレー設定を追加（未設定の場合のみ）
    if grep -q "relayhost.*${SES_SMTP_ENDPOINT}" /etc/postfix/main.cf 2>/dev/null; then
        warn "Postfix main.cf のリレー設定は既に存在します（スキップ）"
        warn "手動で確認してください: grep relayhost /etc/postfix/main.cf"
    else
        info "Postfix main.cf にSESリレー設定を追加"
        cat >> /etc/postfix/main.cf << EOF

# SES SMTP Relay設定 (mail-infra-handson Phase 3)
# PostfixをSMTPクライアントとしてSESにリレーする設定
relayhost = [${SES_SMTP_ENDPOINT}]:587
smtp_sasl_auth_enable = yes
smtp_sasl_security_options = noanonymous
smtp_sasl_password_maps = hash:${SASL_PASSWD_FILE}
smtp_use_tls = yes
smtp_tls_security_level = encrypt
smtp_tls_note_starttls_offer = yes
EOF
    fi

    info "Postfixを再起動"
    postfix reload

    ok "Postfix設定を完了しました"
}

# --- メイン処理 ---
main() {
    info "=== SES SMTPクレデンシャルセットアップ開始 ==="
    info "リージョン:       ${REGION}"
    info "SMTPエンドポイント: ${SES_SMTP_ENDPOINT}"
    info "IAMユーザー:      ${IAM_USER_NAME}"
    echo ""

    check_prerequisites
    create_iam_user
    generate_access_key

    # 環境変数経由でPythonスクリプトに秘密鍵を渡す（引数渡しはps auxで見えるため避ける）
    export _SES_SECRET_KEY="$SECRET_ACCESS_KEY"
    export _SES_REGION="$REGION"
    convert_to_smtp_password
    # 変換後は即座に環境変数を削除してメモリから除去
    unset _SES_SECRET_KEY _SES_REGION SECRET_ACCESS_KEY

    configure_postfix

    echo ""
    ok "=== セットアップ完了 ==="
    echo ""
    echo "【次の確認ステップ】"
    echo ""
    echo "1. Postfixからテストメール送信:"
    echo "   echo 'Test from Postfix via SES' | mail -s 'Phase3 Postfix-SES Test' your@email.com"
    echo ""
    echo "2. Postfixのメールログを確認:"
    echo "   tail -f /var/log/maillog"
    echo "   # または: journalctl -u postfix -f"
    echo "   # 成功時: status=sent (250 Ok xxxxxxxxxx)"
    echo ""
    echo "3. SES送信クォータを確認:"
    echo "   aws sesv2 get-account --region ${REGION} --query '{Sending: SendingEnabled, Daily: SendQuota.Max24HourSend}'"
    echo ""
    echo "4. IAMアクセスキーID（Postfix認証情報として使用）:"
    echo "   ${ACCESS_KEY_ID}"
}

main "$@"
