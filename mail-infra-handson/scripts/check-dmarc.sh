#!/bin/bash
# DMARC・DKIM・SPF設定の総合確認スクリプト
# 使用方法: ./scripts/check-dmarc.sh your-domain.com

set -euo pipefail

DOMAIN="${1:-}"

if [[ -z "$DOMAIN" ]]; then
  echo "使用方法: $0 <ドメイン名>"
  echo "例      : $0 example.com"
  exit 1
fi

# ANSIカラーコード
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

ok()   { echo -e "  ${GREEN}✅ $*${RESET}"; }
warn() { echo -e "  ${YELLOW}⚠️  $*${RESET}"; }
fail() { echo -e "  ${RED}❌ $*${RESET}"; }
info() { echo -e "  ${CYAN}ℹ️  $*${RESET}"; }

header() {
  echo ""
  echo -e "${BOLD}${CYAN}============================================================${RESET}"
  echo -e "${BOLD}${CYAN}  $*${RESET}"
  echo -e "${BOLD}${CYAN}============================================================${RESET}"
}

# dig コマンドが使えるか確認
if ! command -v dig &>/dev/null; then
  echo "エラー: dig コマンドが見つかりません。bind-utils または dnsutils をインストールしてください"
  exit 1
fi

SCORE=0
MAX_SCORE=5

echo ""
echo -e "${BOLD}📧 メール認証設定チェック: ${CYAN}${DOMAIN}${RESET}"
echo -e "   実行日時: $(date '+%Y-%m-%d %H:%M:%S')"

# ============================================================
# 1. SPFレコード確認
# ============================================================
header "1. SPFレコード"

SPF_RECORD=$(dig TXT "$DOMAIN" +short 2>/dev/null | grep "v=spf1" | tr -d '"' || true)

if [[ -z "$SPF_RECORD" ]]; then
  fail "SPFレコードが見つかりません"
  info "追加方法: Route 53で TXT レコード \"v=spf1 include:amazonses.com -all\" を作成"
else
  ok "SPFレコードが存在します"
  echo "     値: ${SPF_RECORD}"

  if echo "$SPF_RECORD" | grep -q "include:amazonses.com"; then
    ok "include:amazonses.com が含まれています（SES送信が許可されている）"
  else
    fail "include:amazonses.com が含まれていません（SES経由メールが失敗する可能性あり）"
  fi

  if echo "$SPF_RECORD" | grep -q "\-all"; then
    ok "ハードフェイル (-all) が設定されています（最も厳格な設定）"
    SCORE=$((SCORE + 1))
  elif echo "$SPF_RECORD" | grep -q "~all"; then
    warn "ソフトフェイル (~all) が設定されています（Phase 4では -all への移行を推奨）"
  elif echo "$SPF_RECORD" | grep -q "?all"; then
    warn "ニュートラル (?all) が設定されています（なりすまし対策として不十分）"
  fi
fi

# ============================================================
# 2. DKIMレコード確認（SES Easy DKIMの3セレクタ）
# ============================================================
header "2. DKIMレコード（SES Easy DKIMセレクタ確認）"

echo "  SESのEasy DKIMではCNAMEレコードが3つ登録されます"
echo "  セレクタは動的に割り当てられるため、CNAMEレコードを検索します"
echo ""

# _domainkey サブドメインのNSレコードを確認してセレクタを特定する方法の代わりに
# 既知パターンでCNAMEを探す（セレクタ名はランダムなため、実際のレコードをlookupする）
DKIM_CNAME_COUNT=0

# dig axfr はDNS転送が必要なため使えない
# 代わりに、Route 53 API または aws cli で確認する方法を案内する
echo "  ⚙️  SES DKIMセレクタはランダムな文字列のため、直接DNS検索が難しいです"
echo "  以下のAWS CLIコマンドで確認してください:"
echo ""
echo -e "  ${CYAN}aws sesv2 get-email-identity \\"
echo -e "    --email-identity ${DOMAIN} \\"
echo -e "    --region ap-northeast-1 \\"
echo -e "    --query 'DkimAttributes.{Status:Status,Tokens:Tokens}' \\"
echo -e "    --output table${RESET}"
echo ""

# AWS CLIが使える場合は実行する
if command -v aws &>/dev/null; then
  DKIM_JSON=$(aws sesv2 get-email-identity \
    --email-identity "$DOMAIN" \
    --region ap-northeast-1 \
    --query 'DkimAttributes' \
    --output json 2>/dev/null || true)

  if [[ -n "$DKIM_JSON" ]]; then
    DKIM_STATUS=$(echo "$DKIM_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Status','UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")
    SIGNING_ENABLED=$(echo "$DKIM_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('SigningEnabled', False))" 2>/dev/null || echo "False")

    if [[ "$DKIM_STATUS" == "SUCCESS" ]]; then
      ok "DKIMステータス: SUCCESS（DNSレコードが正しく設定されています）"
      SCORE=$((SCORE + 1))
    elif [[ "$DKIM_STATUS" == "PENDING" ]]; then
      warn "DKIMステータス: PENDING（DNS伝播中。数分〜数時間かかることがあります）"
    else
      fail "DKIMステータス: ${DKIM_STATUS}"
    fi

    if [[ "$SIGNING_ENABLED" == "True" ]]; then
      ok "DKIM署名が有効です（送信メールに自動で署名が付与されます）"
    else
      fail "DKIM署名が無効です（SES Console で有効化してください）"
    fi

    # セレクタのCNAMEレコードを直接検証
    TOKENS=$(echo "$DKIM_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); [print(t) for t in d.get('Tokens',[])]" 2>/dev/null || true)
    if [[ -n "$TOKENS" ]]; then
      echo ""
      echo "  CNAMEレコードの確認:"
      while IFS= read -r token; do
        CNAME_RECORD=$(dig CNAME "${token}._domainkey.${DOMAIN}" +short 2>/dev/null || true)
        if [[ -n "$CNAME_RECORD" ]]; then
          ok "  ${token}._domainkey.${DOMAIN}"
          echo "       → ${CNAME_RECORD}"
          DKIM_CNAME_COUNT=$((DKIM_CNAME_COUNT + 1))
        else
          fail "  ${token}._domainkey.${DOMAIN} （CNAMEが見つかりません）"
        fi
      done <<< "$TOKENS"
    fi
  fi
else
  warn "AWS CLIが見つかりません。手動でSES Consoleから確認してください"
fi

# ============================================================
# 3. DMARCレコード確認
# ============================================================
header "3. DMARCレコード"

DMARC_RECORD=$(dig TXT "_dmarc.${DOMAIN}" +short 2>/dev/null | tr -d '"' || true)

if [[ -z "$DMARC_RECORD" ]]; then
  fail "DMARCレコードが見つかりません"
  info "追加方法: _dmarc.${DOMAIN} に TXT レコードを追加"
  info "例: \"v=DMARC1; p=quarantine; rua=mailto:dmarc-reports@${DOMAIN}\""
else
  ok "DMARCレコードが存在します"
  echo "     値: ${DMARC_RECORD}"
  echo ""

  # ポリシー確認
  POLICY=$(echo "$DMARC_RECORD" | grep -oP '(?<=p=)[^;]+' || true)
  case "$POLICY" in
    "reject")
      ok "ポリシー: reject（最も厳格。なりすましメールを完全拒否）"
      SCORE=$((SCORE + 1))
      ;;
    "quarantine")
      ok "ポリシー: quarantine（疑わしいメールをスパムフォルダへ移動）"
      SCORE=$((SCORE + 1))
      ;;
    "none")
      warn "ポリシー: none（モニタリングのみ。Phase 4では quarantine 以上を推奨）"
      ;;
    *)
      fail "ポリシーが不明または未設定: ${POLICY:-なし}"
      ;;
  esac

  # pct確認
  PCT=$(echo "$DMARC_RECORD" | grep -oP '(?<=pct=)[^;]+' || echo "100")
  if [[ "$PCT" == "100" ]]; then
    ok "適用割合: ${PCT}%（全メールにポリシーを適用）"
  else
    warn "適用割合: ${PCT}%（段階移行中。最終的には100%を推奨）"
  fi

  # rua確認
  RUA=$(echo "$DMARC_RECORD" | grep -oP '(?<=rua=)[^;]+' || true)
  if [[ -n "$RUA" ]]; then
    ok "集計レポート送信先(rua): ${RUA}"
    SCORE=$((SCORE + 1))
  else
    warn "集計レポート送信先(rua)が設定されていません（送信経路の把握に重要）"
  fi

  # ruf確認
  RUF=$(echo "$DMARC_RECORD" | grep -oP '(?<=ruf=)[^;]+' || true)
  if [[ -n "$RUF" ]]; then
    ok "フォレンジックレポート送信先(ruf): ${RUF}"
  else
    info "フォレンジックレポート送信先(ruf)は未設定（任意。プライバシー上の理由で省略可）"
  fi
fi

# ============================================================
# 4. MXレコード確認
# ============================================================
header "4. MXレコード（受信設定）"

MX_RECORDS=$(dig MX "$DOMAIN" +short 2>/dev/null || true)

if [[ -z "$MX_RECORDS" ]]; then
  warn "MXレコードが見つかりません（受信設定がされていません）"
else
  ok "MXレコードが存在します"
  echo "$MX_RECORDS" | while read -r priority server; do
    echo "     優先度 ${priority}: ${server}"
    if echo "$server" | grep -qi "amazonses\|inbound-smtp"; then
      ok "SESインバウンドエンドポイントが設定されています"
    fi
  done
fi

# ============================================================
# 5. 総合評価
# ============================================================
header "総合評価"

echo "  スコア: ${SCORE} / ${MAX_SCORE}"
echo ""

if [[ $SCORE -ge 5 ]]; then
  echo -e "  ${GREEN}${BOLD}🏆 優秀！メール認証が完全に設定されています${RESET}"
elif [[ $SCORE -ge 3 ]]; then
  echo -e "  ${YELLOW}${BOLD}📊 良好。いくつかの項目を改善するとより安全になります${RESET}"
else
  echo -e "  ${RED}${BOLD}⚠️  改善が必要です。上記の ❌ と ⚠️ の項目を確認してください${RESET}"
fi

echo ""
echo "  mail-tester.com での詳細テスト:"
echo -e "  ${CYAN}1. https://www.mail-tester.com/ にアクセス${RESET}"
echo -e "  ${CYAN}2. 表示されたアドレスにSES経由でメールを送信${RESET}"
echo -e "  ${CYAN}3. スコアと詳細レポートを確認（目標: 10/10）${RESET}"
echo ""
