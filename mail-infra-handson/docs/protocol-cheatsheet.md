# メールプロトコル早見表

## SMTPコマンド早見表

### 基本コマンド

| コマンド | 用途 | 例 |
|--------|------|-----|
| `EHLO` | 自己紹介（ESMTP拡張版）。サーバー対応機能一覧を取得できる | `EHLO myhostname.com` |
| `HELO` | 自己紹介（古いSMTP版）。機能一覧は返ってこない | `HELO myhostname.com` |
| `MAIL FROM` | エンベロープ送信者を宣言（Return-Path、バウンス通知先） | `MAIL FROM:<sender@example.com>` |
| `RCPT TO` | エンベロープ受信者を宣言（実際の配送先） | `RCPT TO:<receiver@example.com>` |
| `DATA` | メール本文の送信開始。`.` 単独行で終了 | `DATA` |
| `QUIT` | セッション終了 | `QUIT` |

### 認証コマンド

| コマンド | 用途 | 備考 |
|--------|------|------|
| `AUTH LOGIN` | Base64エンコードでユーザー名・パスワードを送る | 平文に近い。TLS必須 |
| `AUTH PLAIN` | ユーザー名・パスワードを1回のBase64で送る | TLS必須 |
| `STARTTLS` | 平文接続をTLSにアップグレード | port 587で使用 |

### EHLO vs HELO の違い

```
HELO (RFC 821, 1982年):
  → 古い仕様。サーバー機能の告知なし
  → 現在はほぼ使われない

EHLO (RFC 5321, Extended SMTP):
  → 接続後にサーバーが対応機能を返してくれる
  → 返答例:
    250-STARTTLS
    250-AUTH LOGIN PLAIN
    250-SIZE 10240000
    250 8BITMIME
```

### 手動SMTP接続例（telnet）

```bash
$ telnet mail.example.com 25

220 mail.example.com ESMTP Postfix

EHLO myhostname.com
250-mail.example.com
250-STARTTLS
250 AUTH LOGIN PLAIN

MAIL FROM:<sender@mine.com>
250 Ok

RCPT TO:<receiver@example.com>
250 Ok

DATA
354 End data with <CR><LF>.<CR><LF>

From: sender@mine.com
To: receiver@example.com
Subject: テスト送信

本文です。
.
250 Ok: queued as ABC123

QUIT
221 Bye
```

---

## POP3 vs IMAP 比較表

| 項目 | POP3 (port 110/995) | IMAP (port 143/993) |
|------|---------------------|---------------------|
| 動作 | メールをサーバーからダウンロードして（通常）削除 | サーバー上でメールを管理。クライアントは同期 |
| マルチデバイス | 不向き（1端末でダウンロードすると他から見えなくなる） | 最適（どの端末からも同じ状態を参照） |
| オフライン | ダウンロード済みなので完全オフライン閲覧可 | 基本的にオンライン接続が必要 |
| サーバー負荷 | 低い（配信したら終わり） | 高い（フォルダ・既読状態を常時同期） |
| 使うべきケース | 単一端末・容量節約・シンプルな構成 | スマホ＋PC複数端末・チーム共有メールボックス |

---

## メールヘッダー解析ガイド

### Received ヘッダーの読み方（配送経路の追跡）

```
Received: from mx1.example.com (mx1.example.com [203.0.113.1])
        by mail.recipient.com with ESMTPS id abc123
        for <user@recipient.com>;
        Sat, 1 Jan 2024 12:00:00 +0900 (JST)
```

**ポイント**: Received ヘッダーは**下から上**に読む。最初に経由したサーバーが一番下に書かれる。

```
Received: (最後に受け取ったサーバー ← 最新)
Received: (中継サーバー)
Received: (最初に送信したサーバー ← 最古)
```

### Authentication-Results の見方

```
Authentication-Results: mail.recipient.com;
  spf=pass (sender IP is 54.240.0.1)
    smtp.mailfrom=sender@example.com;
  dkim=pass header.i=@example.com header.s=selector1;
  dmarc=pass (p=REJECT) header.from=example.com
```

| フィールド | 値 | 意味 |
|---------|-----|------|
| `spf=pass` | 送信元IPがSPFポリシーに一致 | 正当な送信元 |
| `spf=fail` | ポリシー外からの送信 | なりすましの疑い |
| `spf=softfail` | `~all` による警告 | 疑わしいがブロックしない |
| `dkim=pass` | 電子署名が正しく検証できた | メール改ざんなし |
| `dkim=fail` | 署名が不正または欠損 | 改ざん・なりすましの疑い |
| `dmarc=pass` | SPF/DKIMが揃ってFromドメインと一致 | 認証完全成功 |
| `dmarc=fail` | アライメント不一致 | DMARCポリシーに従い処理 |

### Return-Path vs From の違い（重要）

```
エンベロープ（郵便の封筒）  ←→  ヘッダー（手紙の宛名書き）

Return-Path: <bounce@sender.com>   # MAIL FROM の値。バウンスメールの返送先
From: display@sender.com           # MUA（メーラー）に表示される差出人

※ この2つが異なっていても技術的には送れる
  → なりすましメールはFromだけを書き換えて正規ドメインに見せかける
  → DMARCはこの不一致を検出する仕組み
```

---

## よく使う dig コマンド

```bash
# MXレコード確認（メール受信サーバーの確認）
dig MX example.com
dig +short MX example.com

# TXTレコード確認（SPF・DMARC・SES検証レコード）
dig TXT example.com
dig +short TXT example.com

# DMARCレコード確認
dig TXT _dmarc.example.com
dig +short TXT _dmarc.example.com

# DKIMレコード確認（セレクタ名が必要）
dig TXT selector1._domainkey.example.com

# Aレコード確認（ホスト名→IPアドレス）
dig A mail.example.com
dig +short A mail.example.com

# PTRレコード確認（逆引き: IPアドレス→ホスト名）
# スパム判定でよく使われる
dig -x 203.0.113.1
dig +short -x 203.0.113.1

# 特定のDNSサーバーに直接問い合わせ（伝播確認に便利）
dig @8.8.8.8 MX example.com       # Google Public DNS
dig @1.1.1.1 TXT example.com      # Cloudflare DNS

# NSレコード確認（ドメインの権威DNSサーバー）
dig NS example.com

# TTL確認（キャッシュ有効期限）
dig +ttl MX example.com
```
