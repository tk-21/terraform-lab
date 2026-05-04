#!/bin/bash
# メール関連DNSレコードの確認スクリプト
# 使用方法: ./scripts/check-dns.sh example.com

set -euo pipefail

DOMAIN="${1:-}"

if [[ -z "${DOMAIN}" ]]; then
  echo "使用方法: $0 <ドメイン名>"
  echo "例: $0 mail-handson-2024.com"
  exit 1
fi

# 色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo ""
echo -e "${BLUE}=====================================================${NC}"
echo -e "${BLUE}  メール関連DNSレコード確認: ${DOMAIN}${NC}"
echo -e "${BLUE}=====================================================${NC}"

# ----------------------------------------
# 1. MXレコード確認
# ----------------------------------------
echo ""
echo -e "${YELLOW}[1] MXレコード確認${NC}"
echo "    → メール受信を担当するサーバーを確認します"
echo ""

MX_RESULT=$(dig +short MX "${DOMAIN}" 2>/dev/null)

if [[ -z "${MX_RESULT}" ]]; then
  echo -e "    ${RED}⚠️  警告: MXレコードが見つかりません${NC}"
  echo "    → ドメインレジストラのNSサーバー設定が反映されていない可能性があります"
  echo "    → terraform apply 後、DNS伝播に最大48時間かかる場合があります"
else
  echo -e "    ${GREEN}✅ MXレコード:${NC}"
  echo "${MX_RESULT}" | while read -r line; do
    echo "    ${line}"
    # SES受信エンドポイントの存在チェック
    if echo "${line}" | grep -q "inbound-smtp.ap-northeast-1.amazonaws.com"; then
      echo -e "    ${GREEN}   → Phase1のSES受信エンドポイントが正しく設定されています${NC}"
    fi
  done
fi

# ----------------------------------------
# 2. SPFレコード確認（TXTレコード）
# ----------------------------------------
echo ""
echo -e "${YELLOW}[2] SPFレコード確認${NC}"
echo "    → 送信許可IPリストをDNSで宣言するSPFポリシーを確認します"
echo ""

SPF_RESULT=$(dig +short TXT "${DOMAIN}" 2>/dev/null | grep "v=spf1" || true)

if [[ -z "${SPF_RESULT}" ]]; then
  echo -e "    ${RED}⚠️  警告: SPFレコードが見つかりません${NC}"
  echo "    → terraform apply が完了しているか確認してください"
else
  echo -e "    ${GREEN}✅ SPFレコード:${NC}"
  echo "    ${SPF_RESULT}"

  # SPFポリシー解析
  if echo "${SPF_RESULT}" | grep -q "include:amazonses.com"; then
    echo -e "    ${GREEN}   → amazonses.com が許可リストに含まれています（Phase3のSES送信に対応済み）${NC}"
  fi
  if echo "${SPF_RESULT}" | grep -q "~all"; then
    echo -e "    ${YELLOW}   → ソフトフェイル(~all)設定中。Phase4完了後に -all へ変更を推奨します${NC}"
  elif echo "${SPF_RESULT}" | grep -q "\-all"; then
    echo -e "    ${GREEN}   → ハードフェイル(-all)設定済み。最も厳格なSPFポリシーです${NC}"
  fi
fi

# ----------------------------------------
# 3. DMARCレコード確認
# ----------------------------------------
echo ""
echo -e "${YELLOW}[3] DMARCレコード確認${NC}"
echo "    → SPF/DKIMの結果をポリシーとして宣言するDMARCレコードを確認します"
echo ""

DMARC_RESULT=$(dig +short TXT "_dmarc.${DOMAIN}" 2>/dev/null | grep "v=DMARC1" || true)

if [[ -z "${DMARC_RESULT}" ]]; then
  echo -e "    ${RED}⚠️  警告: DMARCレコードが見つかりません (_dmarc.${DOMAIN})${NC}"
  echo "    → terraform apply が完了しているか確認してください"
else
  echo -e "    ${GREEN}✅ DMARCレコード:${NC}"
  echo "    ${DMARC_RESULT}"

  # DMARCポリシー解析
  if echo "${DMARC_RESULT}" | grep -q "p=none"; then
    echo -e "    ${YELLOW}   → ポリシー: none（モニタリングモード）。認証失敗しても配送は止まりません${NC}"
    echo -e "    ${YELLOW}   → Phase4で quarantine → reject へ段階的に強化します${NC}"
  elif echo "${DMARC_RESULT}" | grep -q "p=quarantine"; then
    echo -e "    ${YELLOW}   → ポリシー: quarantine（迷惑メールフォルダへ振り分け）${NC}"
  elif echo "${DMARC_RESULT}" | grep -q "p=reject"; then
    echo -e "    ${GREEN}   → ポリシー: reject（最も厳格。認証失敗メールを拒否）${NC}"
  fi

  if echo "${DMARC_RESULT}" | grep -q "rua="; then
    RUA=$(echo "${DMARC_RESULT}" | grep -oP 'rua=\K[^;]+')
    echo -e "    ${GREEN}   → 集計レポート送信先: ${RUA}${NC}"
  fi
fi

# ----------------------------------------
# 4. 全体サマリー
# ----------------------------------------
echo ""
echo -e "${BLUE}=====================================================${NC}"
echo -e "${BLUE}  確認完了サマリー${NC}"
echo -e "${BLUE}=====================================================${NC}"

ALL_OK=true

[[ -z "${MX_RESULT}" ]] && ALL_OK=false
[[ -z "${SPF_RESULT}" ]] && ALL_OK=false
[[ -z "${DMARC_RESULT}" ]] && ALL_OK=false

if "${ALL_OK}"; then
  echo -e "${GREEN}✅ Phase1の全DNSレコードが確認できました！${NC}"
  echo ""
  echo "次のステップ:"
  echo "  1. terraform output hosted_zone_name_servers でNSサーバーを確認"
  echo "  2. ドメインレジストラのNSレコードをRoute53のものに変更"
  echo "  3. Phase2へ進む（EC2・Postfix構築）"
else
  echo -e "${RED}⚠️  一部のレコードが見つかりませんでした${NC}"
  echo ""
  echo "トラブルシューティング:"
  echo "  1. terraform apply が正常に完了しているか確認"
  echo "  2. ドメインレジストラのNSレコードがRoute53のものか確認"
  echo "  3. DNS伝播待ち（最大48時間）の可能性あり"
  echo "  4. dig @8.8.8.8 MX ${DOMAIN} でGoogle DNSから直接確認"
fi

echo ""
