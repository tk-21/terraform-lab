# ✅Phase 1: 理論 × DNS基盤構築
# 「メールの旅路とDNSの役割を理解する」
#
# 実行方法: claude < phases/phase1.md
# 所要時間: 2〜3時間
# 前提: AWSアカウント・Terraform・AWS CLI設定済み

## このフェーズのゴール

1. メール配送フロー（MUA→MSA→MTA→MDA）を理論で理解する
2. DNSがメール配送で果たす役割を実装で理解する
3. Route 53でドメイン取得 + 基本DNSレコードをTerraformで構築する
4. SPFレコードを実際に設定し、仕組みを理解する

---

## 理論解説（実装前に必ず読むこと）

### メール配送の登場人物

```
送信者PC                          受信者PC
[MUA]                              [MUA]
  |                                  ↑
  | SMTP(587)                        | POP3(110)/IMAP(143)
  ↓                                  |
[MSA] ──SMTP(25)──→ [送信MTA] ──SMTP(25)──→ [受信MTA] ──→ [MDA]
 送信サーバー         中継サーバー              受信サーバー    メールボックス
```

- **MUA** (Mail User Agent): Thunderbird, Outlook, Gmailブラウザ
- **MSA** (Mail Submission Agent): 認証済みユーザーからメールを受け付けるサーバー（port 587）
- **MTA** (Mail Transfer Agent): サーバー間でメールを転送（port 25）。Postfixがこれ
- **MDA** (Mail Delivery Agent): 受信MTAがメールボックスに配送。Procmailなど

### DNSがメール配送で使われる場面

```
送信MTAがexample.comへメールを送る場合:

1. example.comのMXレコードを引く
   → 「mail.example.com が受信を担当」とわかる

2. mail.example.comのAレコードを引く
   → IPアドレスが判明

3. そのIPのport 25へSMTP接続して配送
```

### SMTPの会話（手動でやると理解が深まる）

```
$ telnet mail.example.com 25

220 mail.example.com ESMTP Postfix

EHLO myhostname.com          # 自己紹介（EHLOはESMTP拡張版）
250-mail.example.com
250-STARTTLS                 # TLS対応を宣言
250 AUTH LOGIN PLAIN         # 認証方式の一覧

MAIL FROM:<sender@mine.com>  # エンベロープの送信者（Return-Path）
250 Ok

RCPT TO:<receiver@example.com>  # エンベロープの受信者
250 Ok

DATA                         # メール本文の開始
354 End data with <CR><LF>.<CR><LF>

From: sender@mine.com        # ヘッダー（表示上の差出人）
To: receiver@example.com
Subject: テスト

本文です。
.                            # ドット1文字で本文終了
250 Ok: queued as ABC123

QUIT
221 Bye
```

⚠️ **重要**: `MAIL FROM`（エンベロープ）と `From:`（ヘッダー）は別物！
- エンベロープ: 実際の配送に使われる（郵便の封筒）
- ヘッダー: メーラーに表示される（手紙の宛名）
- なりすましメールはヘッダーだけ書き換える

### SPFの仕組み

```
# example.comのSPFレコード（TXTレコード）
"v=spf1 include:amazonses.com ip4:203.0.113.0/24 -all"

受信MTAが行うSPF検証:
1. MAIL FROMドメイン（example.com）のTXTレコードを引く
2. SPFポリシーを取得
3. 送信元IPがポリシーに含まれるか確認
4. 結果をAuthentication-Resultsヘッダーに記録

-all: ポリシー外からの送信を拒否（最も厳格）
~all: ソフトフェイル（受け取るが疑わしいとマーク）
+all: すべてを許可（危険・非推奨）
```

---

## タスク: 以下のTerraformコードを生成してください

### 前提条件
- リージョン: ap-northeast-1（東京）
- プロジェクト名: mail-infra-handson
- フェーズ: phase1
- 出力先: `terraform/phase1/` 配下

### 生成するファイル一覧

1. `terraform/phase1/main.tf`
2. `terraform/phase1/variables.tf`
3. `terraform/phase1/outputs.tf`
4. `terraform/phase1/terraform.tfvars.example`
5. `scripts/check-dns.sh`
6. `docs/protocol-cheatsheet.md`

---

### main.tf の要件

#### Terraformバックエンド設定
```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # S3バックエンド（バケット名はvariablesから取得）
  backend "s3" {}
}
```

#### Route 53ホストゾーン
- `aws_route53_zone` でパブリックホストゾーンを作成
- ドメイン名はvariablesから取得
- 日本語コメントで「ホストゾーンとは何か」を説明

#### MXレコード
- `aws_route53_record` でMXレコードを作成
- 優先度10でAWSのSES受信エンドポイントを指定
  - 東京リージョン: `inbound-smtp.ap-northeast-1.amazonaws.com`
- TTL: 300
- 日本語コメントで「MXレコードの役割」を説明

#### SPFレコード（TXTレコード）
- `aws_route53_record` でSPFレコードを作成
- 値: `"v=spf1 include:amazonses.com ~all"`
  - Phase 3でSESを使うため `include:amazonses.com` を先に入れておく
  - 今は `~all`（ソフトフェイル）でスタート、Phase 4で `-all` に変更
- TTL: 300
- 日本語コメントでSPFの各パラメータ意味を説明

#### DMARCレコード（TXTレコード）
- サブドメイン `_dmarc.{ドメイン名}` にTXTレコードを作成
- 値: `"v=DMARC1; p=none; rua=mailto:dmarc-reports@{ドメイン名}"`
  - `p=none` はモニタリングモード（Phase 4で `p=quarantine` → `p=reject` へ移行）
- 日本語コメントでDMARCのポリシー段階を説明

#### ローカル変数
```hcl
locals {
  # 共通タグ（全リソースに付与）
  common_tags = {
    Project   = "mail-infra-handson"
    Phase     = "phase1"
    ManagedBy = "terraform"
  }
}
```

---

### variables.tf の要件

以下の変数を定義すること（日本語descriptionで）:

| 変数名 | 型 | 説明 |
|-------|-----|------|
| `domain_name` | string | 取得するドメイン名（例: mail-handson-2024.com） |
| `aws_region` | string | AWSリージョン（デフォルト: ap-northeast-1） |
| `tfstate_bucket` | string | Terraformステート保存用S3バケット名 |
| `tfstate_dynamodb_table` | string | Terraformロック用DynamoDBテーブル名 |

---

### outputs.tf の要件

Phase 2以降で使う値を出力すること:

| output名 | 説明 |
|---------|------|
| `hosted_zone_id` | Route 53ホストゾーンID（Phase 3のSES検証で使用） |
| `hosted_zone_name_servers` | NSレコード（ドメインレジストラへの設定確認用） |
| `domain_name` | ドメイン名（後続フェーズで参照） |
| `mx_record` | 設定したMXレコードの値 |
| `spf_record` | 設定したSPFレコードの値 |

---

### terraform.tfvars.example の要件

```hcl
# terraform.tfvars.example
# このファイルをterraform.tfvarsにコピーして値を埋めて使用する

domain_name            = "your-mail-handson-domain.com"  # 取得するドメイン名
aws_region             = "ap-northeast-1"
tfstate_bucket         = "your-tfstate-bucket-name"
tfstate_dynamodb_table = "terraform-lock"
```

---

### scripts/check-dns.sh の要件

以下の確認を順番に行うbashスクリプト:

```bash
#!/bin/bash
# メール関連DNSレコードの確認スクリプト
# 使用方法: ./scripts/check-dns.sh example.com

DOMAIN=$1

# 確認項目:
# 1. MXレコード確認 (dig MX)
# 2. SPFレコード確認 (dig TXT)
# 3. DMARCレコード確認 (dig TXT _dmarc.DOMAIN)
# 4. 各結果に日本語で解説コメントを表示
# 5. 問題があれば警告メッセージを表示
```

---

### docs/protocol-cheatsheet.md の要件

以下の内容を含むMarkdownファイル:

1. **SMTPコマンド早見表**
   - EHLO / HELO の違い
   - MAIL FROM / RCPT TO / DATA / QUIT
   - AUTH LOGIN / AUTH PLAIN

2. **POP3 vs IMAP 比較表**
   - 動作の違い（POP3: ダウンロード削除、IMAP: サーバー同期）
   - 使うべきケース

3. **メールヘッダー解析ガイド**
   - Received ヘッダーの読み方（配送経路の追跡）
   - Authentication-Results の見方（SPF/DKIM/DMARC結果）
   - Return-Path vs From の違い

4. **よく使うdigコマンド**
   - MX / TXT / A / PTR レコードの確認方法

---

## 生成後の実行手順（コメントとして出力すること）

```bash
# 1. S3バックエンド用バケットを事前に作成（初回のみ）
aws s3 mb s3://your-tfstate-bucket-name --region ap-northeast-1
aws dynamodb create-table \
  --table-name terraform-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-northeast-1

# 2. tfvarsを準備
cp terraform/phase1/terraform.tfvars.example terraform/phase1/terraform.tfvars
# → terraform.tfvarsを編集してドメイン名等を設定

# 3. Terraform実行
cd terraform/phase1
terraform init \
  -backend-config="bucket=your-tfstate-bucket-name" \
  -backend-config="key=mail-handson/phase1/terraform.tfstate" \
  -backend-config="region=ap-northeast-1" \
  -backend-config="dynamodb_table=terraform-lock"

terraform plan -var-file="terraform.tfvars"
terraform apply -var-file="terraform.tfvars"

# 4. DNS確認
cd ../../
./scripts/check-dns.sh your-domain.com

# 5. NSレコードをドメインレジストラに設定
# terraform output hosted_zone_name_servers
# → 出力された4つのNSサーバーをRoute 53のNSレコードとして設定
```

## Phase 1完了の確認チェックリスト（コメントとして出力すること）

- [ ] Route 53ホストゾーンが作成されている
- [ ] MXレコードが `inbound-smtp.ap-northeast-1.amazonaws.com` を向いている
- [ ] `dig MX your-domain.com` でMXレコードが返る
- [ ] `dig TXT your-domain.com` でSPFレコードが返る
- [ ] `dig TXT _dmarc.your-domain.com` でDMARCレコードが返る
- [ ] `./scripts/check-dns.sh your-domain.com` がエラーなく完了する

## Phase 2への引き継ぎ情報（コメントとして出力すること）

```
Phase 2で必要な情報:
- hosted_zone_id: $(terraform output -raw hosted_zone_id)
- domain_name: $(terraform output -raw domain_name)

Phase 2では:
- EC2にPostfixをインストールしてMTAを構築
- SESをスマートホストとして設定
- telnetでSMTPコマンドを手打ちして配送フローを体感
```