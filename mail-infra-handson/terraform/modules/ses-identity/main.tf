locals {
  tags = merge(var.tags, { Module = "ses-identity" })
}

# ============================================================
# SES Email Identity（ドメイン検証）
# ============================================================

resource "aws_sesv2_email_identity" "domain" {
  # ドメイン全体を検証することで、任意のアドレス（no-reply@, support@等）から送信可能になる
  # Easy DKIM: SESが秘密鍵を管理し、送信メールに自動でDKIM署名を付与する
  email_identity = var.domain_name

  dkim_signing_attributes {
    # RSA_2048_BIT: セキュリティ強度と古いMTA（Exchange等）との互換性のバランスが良い選択
    next_signing_key_length = "RSA_2048_BIT"
  }

  tags = local.tags
}

# ============================================================
# Route 53 DKIM CNAME レコード（3つ）
# ============================================================

resource "aws_route53_record" "dkim_cname" {
  # DKIMレコードが3つある理由:
  # SESはキーローテーション（定期的な鍵更新）をサポートするために3つを同時登録する
  # ローテーション時は新旧の鍵が並存し、受信側のキャッシュが切れるまで両方が有効になる
  for_each = toset(aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens)

  zone_id = var.hosted_zone_id
  name    = "${each.value}._domainkey.${var.domain_name}"
  type    = "CNAME"
  ttl     = 300
  records = ["${each.value}.dkim.amazonses.com"]
}

# ============================================================
# Route 53 SES検証TXTレコード
# ============================================================

resource "aws_route53_record" "ses_verification" {
  # _amazonses.{domain} のTXTレコードはドメイン所有権の補助的な証明
  # SESv2 + Easy DKIMではDKIM CNAMEだけで検証完了するが、
  # SESv1互換APIや外部検証ツールが警告を出す場合があるため設定する
  zone_id = var.hosted_zone_id
  name    = "_amazonses.${var.domain_name}"
  type    = "TXT"
  ttl     = 300
  records = [aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens[0]]
}
