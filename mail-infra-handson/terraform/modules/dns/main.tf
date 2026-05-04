locals {
  tags = merge(var.tags, { Module = "dns" })
}

# ============================================================
# Route 53 Hosted Zone
# ============================================================

resource "aws_route53_zone" "main" {
  # ホストゾーン: このドメインのDNSレコードをすべて管理するコンテナ
  # 作成後にNSレコードをドメインレジストラに設定することで有効になる
  name = var.domain_name
  tags = local.tags
}

# ============================================================
# MX レコード（メール受信先）
# ============================================================

resource "aws_route53_record" "mx" {
  # MXレコード: メール受信時に接続先MTAを指定するDNSレコード
  # 優先度(priority)が低いほど優先して使われる（10が20より優先）
  # SESの受信エンドポイントに向けることで、SES経由でメールを受信できる
  zone_id = aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = "MX"
  ttl     = 300
  records = ["10 inbound-smtp.${var.aws_region}.amazonaws.com"]
}

# ============================================================
# SPF レコード（送信元IP認証）
# ============================================================

resource "aws_route53_record" "spf" {
  # SPFレコード: このドメインから送信を許可するIPアドレスを宣言する
  # include:amazonses.com → SESのIPアドレス範囲をすべて許可
  # var.spf_policy:
  #   ~all（ソフトフェイル）: リスト外IPも受信するが疑わしいとマーク（移行初期）
  #   -all（ハードフェイル）: リスト外IPからの送信を完全拒否（本番推奨）
  zone_id = aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = "TXT"
  ttl     = 300
  records = ["v=spf1 include:amazonses.com ${var.spf_policy}"]
}

# ============================================================
# DMARC レコード（認証ポリシー）
# ============================================================

resource "aws_route53_record" "dmarc" {
  # DMARCレコード: SPF/DKIMの検証失敗時に受信側MTAが取るべき行動を宣言する
  #
  # p=none:       ポリシーなし（失敗しても配送。モニタリング専用）
  # p=quarantine: 認証失敗メールをスパムフォルダへ移動
  # p=reject:     認証失敗メールを完全拒否（最もセキュア）
  #
  # rua: 集計レポート(XML)の送信先。毎日届くため受信用メールアドレスが必要
  # ruf: フォレンジックレポートの送信先（個別の失敗メールの詳細）
  # sp:  サブドメインへのポリシー（var.dmarc_policyと同じ値を適用）
  # adkim/aspf=r: relaxedアライメント（サブドメインも許容）
  zone_id = aws_route53_zone.main.zone_id
  name    = "_dmarc.${var.domain_name}"
  type    = "TXT"
  ttl     = 300
  records = [
    "v=DMARC1; p=${var.dmarc_policy}; pct=${var.dmarc_pct}; rua=mailto:dmarc-reports@${var.domain_name}; ruf=mailto:dmarc-forensic@${var.domain_name}; sp=${var.dmarc_policy}; adkim=r; aspf=r"
  ]
}
