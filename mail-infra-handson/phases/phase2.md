# ✅Phase 2: MTA構築（Postfix on EC2）
# 「SMTPサーバーを自分で立ててリレーの仕組みを体感する」
#
# 実行方法: claude < phases/phase2.md
# 所要時間: 3〜4時間
# 前提: Phase 1完了済み（Route 53・ドメイン設定済み）

## Phase 1の完了確認

このフェーズを開始する前に、以下の値がterraform outputから取得できることを確認すること:

```bash
cd terraform/phase1
terraform output hosted_zone_id   # Route 53ホストゾーンID
terraform output domain_name      # ドメイン名
```

---

## このフェーズのゴール

1. PostfixをEC2にインストールしてSMTPサーバーを立てる
2. `telnet localhost 25` でSMTPコマンドを手打ちしてメール配送を体感する
3. メールキューの仕組みを理解する（`mailq` / `postcat` / `postqueue`）
4. SESをスマートホスト（リレー先）として設定し、実際にメールを送信する

---

## 理論解説（実装前に必ず読むこと）

### Postfixのプロセスアーキテクチャ

```
外部からの接続（port 25）
        ↓
   [smtpd]          ← SMTP受信デーモン。接続を受け付ける
        ↓
   [cleanup]        ← メールのヘッダー整形・正規化
        ↓
   [qmgr]           ← キューマネージャー。配送スケジュールを管理
      ↓    ↓
  [smtp]  [local]   ← smtp: 外部配送、local: ローカルユーザーへの配送
```

### メールキューの種類

```
/var/spool/postfix/
├── incoming/    ← 受信直後、cleanup処理前
├── active/      ← 配送中（最大1000件）
├── deferred/    ← 一時エラーで再試行待ち
├── hold/        ← 手動保留
└── corrupt/     ← 壊れたメール

# キュー確認コマンド
mailq              # キューの一覧表示
postqueue -p       # 同上（詳細版）
postcat -q {ID}    # 特定メールの中身を確認
postqueue -f       # deferred キューを即時再送
postsuper -d ALL   # キューを全削除（テスト時）
```

### スマートホスト構成（PostfixからSESへリレー）

```
[Postfix on EC2]
      |
      | SMTP(587) with STARTTLS + SMTP AUTH
      ↓
[AWS SES SMTP Endpoint]
(email-smtp.ap-northeast-1.amazonaws.com)
      |
      | SESが実際の配送を担当
      ↓
[受信者のメールサーバー]

# main.cfでの設定
relayhost = [email-smtp.ap-northeast-1.amazonaws.com]:587
smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_use_tls = yes
```

### SMTP認証（SASL）

```
PostfixからSESへ接続する際に必要:
- ユーザー名: SES SMTPクレデンシャルのユーザー名（IAMから生成）
- パスワード: SES SMTPクレデンシャルのパスワード

/etc/postfix/sasl_passwd の形式:
[email-smtp.ap-northeast-1.amazonaws.com]:587 USERNAME:PASSWORD

# ハッシュ化してPostfixに読み込ませる
postmap /etc/postfix/sasl_passwd
chmod 600 /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.db
```

---

## タスク: 以下のTerraformコードと設定ファイルを生成してください

### 前提条件
- Phase 1の outputs（hosted_zone_id, domain_name）を変数として受け取る
- リージョン: ap-northeast-1（東京）
- 出力先: `terraform/phase2/` 配下

### 生成するファイル一覧

1. `terraform/phase2/main.tf`
2. `terraform/phase2/variables.tf`
3. `terraform/phase2/outputs.tf`
4. `terraform/phase2/terraform.tfvars.example`
5. `terraform/phase2/user_data.sh`
6. `scripts/smtp-test.sh`
7. `scripts/postfix-debug.sh`

---

### main.tf の要件

#### VPCとサブネット
- デフォルトVPCを `data "aws_vpc" "default"` で参照
- デフォルトサブネットを `data "aws_subnets"` で参照
- 日本語コメント: なぜデフォルトVPCを使うか（ハンズオン用の簡略化）

#### Security Group
リソース名: `mail-handson-phase2-sg`

インバウンドルール（日本語コメントで各ポートの役割を説明）:
- port 25 (SMTP): 自分のIPのみ許可（テスト用。本番は制限必要）
- port 587 (Submission): 自分のIPのみ許可
- port 993 (IMAPS): 自分のIPのみ許可（学習用、後で使う）
- port 443 (HTTPS): 0.0.0.0/0（SSM Session Manager用）

アウトバウンドルール:
- port 587: 0.0.0.0/0（SES SMTPエンドポイントへの接続）
- port 443: 0.0.0.0/0（SSM + AWS API）
- port 25: 0.0.0.0/0（外部MTAへのSMTP）

#### IAM Role（EC2用）
ロール名: `mail-handson-phase2-ec2-role`（64文字以内）

ポリシー:
- `AmazonSSMManagedInstanceCore`（SSH不要でSession Managerで接続）
- SES SendRawEmail権限（インラインポリシー）:
  ```json
  {
    "Effect": "Allow",
    "Action": ["ses:SendRawEmail", "ses:SendEmail"],
    "Resource": "*"
  }
  ```

日本語コメント: SSM Session Managerを使う理由（port 22不要・監査ログ残る）

#### EC2インスタンス
- AMI: Amazon Linux 2023 の最新（`data "aws_ami"` で取得）
- インスタンスタイプ: `t4g.micro`（arm64・コスト最安）
- IAMインスタンスプロファイル: 上記ロールをアタッチ
- Elastic IP: アタッチ（IPが変わるとDNSの逆引き設定が面倒なため）
- ユーザーデータ: `user_data.sh` を `filebase64()` で渡す
- ルートボリューム: 20GB gp3

#### Route 53 Aレコード
- `mail.{domain_name}` → EC2のElastic IPを向ける
- TTL: 300
- 日本語コメント: MTAのホスト名とDNSの関係

#### Route 53 PTRレコード（逆引き）
⚠️ AWSではElastic IPの逆引きはサポートページから申請が必要。
代わりに以下のコメントをコードに入れること:
```hcl
# 逆引きDNS（PTRレコード）について:
# AWSでは aws_route53_record でPTRは設定不可。
# Elastic IPの逆引きを設定するには、AWSサポートへの申請が必要:
# https://aws.amazon.com/jp/premiumsupport/knowledge-center/route-53-reverse-dns/
# 本番環境では必須（SPAMフィルタで弾かれる原因になる）
```

---

### user_data.sh の要件

Amazon Linux 2023上で以下を実行するスクリプト:

```bash
#!/bin/bash
# EC2起動時に自動実行されるユーザーデータスクリプト
# Postfix + メール関連ツールをインストールして設定する

# 1. パッケージ更新
dnf update -y

# 2. Postfix + ツールインストール
dnf install -y postfix mailx telnet bind-utils

# 3. Postfix基本設定（/etc/postfix/main.cf）
# 以下の設定を書き込む:
# - myhostname = mail.{DOMAIN} (変数展開はTerraformのtemplatefileで)
# - mydomain = {DOMAIN}
# - myorigin = $mydomain
# - inet_interfaces = all
# - inet_protocols = ipv4
# - mydestination = $myhostname, localhost.$mydomain, localhost
# - relayhost = [email-smtp.ap-northeast-1.amazonaws.com]:587
# - smtp_sasl_auth_enable = yes
# - smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
# - smtp_sasl_security_options = noanonymous
# - smtp_use_tls = yes
# - smtp_tls_security_level = encrypt
# - smtp_tls_note_starttls_offer = yes

# 4. sasl_passwdのプレースホルダー作成
# 実際の認証情報はSES設定後に手動で入力（Phase 3で設定）

# 5. Postfix起動・自動起動設定
systemctl enable postfix
systemctl start postfix

# 6. ログ確認コマンドのエイリアス設定
echo "alias maillog='tail -f /var/log/maillog'" >> /etc/bashrc
echo "alias mq='mailq'" >> /etc/bashrc
```

---

### outputs.tf の要件

| output名 | 説明 |
|---------|------|
| `ec2_instance_id` | EC2インスタンスID（SSM接続に使用） |
| `ec2_elastic_ip` | Elastic IP（DNS設定確認用） |
| `ec2_mail_hostname` | mail.{domain_name}（Postfixのmyhostname） |
| `ssm_connect_command` | SSM接続コマンド（コピペで使える形式で出力） |

---

### variables.tf の要件

| 変数名 | 型 | 説明 |
|-------|-----|------|
| `domain_name` | string | Phase 1で取得したドメイン名 |
| `hosted_zone_id` | string | Phase 1のRoute 53ホストゾーンID |
| `aws_region` | string | AWSリージョン（デフォルト: ap-northeast-1） |
| `my_ip` | string | 自分のIPアドレス（CIDR形式: x.x.x.x/32） |
| `tfstate_bucket` | string | Terraformステート保存用S3バケット名 |
| `tfstate_dynamodb_table` | string | Terraformロック用DynamoDBテーブル名 |

---

### scripts/smtp-test.sh の要件

```bash
#!/bin/bash
# Postfixへtelnetで手動SMTPテストを行うスクリプト
# 使用方法: ./scripts/smtp-test.sh {EC2_IP} {SENDER} {RECIPIENT}
#
# このスクリプトはSMTPの会話を「見える化」するための学習ツール
# 実際にはexpectを使って自動化するが、手順を理解するために使う

# 1. 接続確認
# 2. SMTPコマンドの実行順序を表示
# 3. 実際にtelnetで接続してメールを送信（expectが必要な場合は手順表示）
# 4. メールキューを確認するコマンドを表示
# 5. Postfixログをリアルタイム確認するコマンドを表示
```

---

### scripts/postfix-debug.sh の要件

Postfixの状態確認・デバッグに使うスクリプト:

```bash
#!/bin/bash
# Postfixデバッグスクリプト
# SSMセッション内で実行する
#
# 以下の情報を収集・表示:
# 1. Postfixステータス (systemctl status postfix)
# 2. 現在のキュー状況 (mailq)
# 3. main.cfの設定確認 (postconf -n)
# 4. 最新のメールログ50行 (tail -50 /var/log/maillog)
# 5. Postfixプロセス一覧 (ps aux | grep postfix)
# 6. ポートのリスン確認 (ss -tlnp | grep -E "25|587")
```

---

## 生成後の実行手順（コメントとして出力すること）

```bash
# 1. terraform.tfvarsを準備（Phase 1の出力値を使用）
cd terraform/phase1
HOSTED_ZONE_ID=$(terraform output -raw hosted_zone_id)
DOMAIN=$(terraform output -raw domain_name)

cd ../phase2
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvarsにhosted_zone_id, domain_nameを設定

# 自分のIPを確認
MY_IP=$(curl -s https://checkip.amazonaws.com)/32
echo "my_ip = \"$MY_IP\"" >> terraform.tfvars

# 2. Terraform実行
terraform init \
  -backend-config="bucket=your-tfstate-bucket" \
  -backend-config="key=mail-handson/phase2/terraform.tfstate" \
  -backend-config="region=ap-northeast-1" \
  -backend-config="dynamodb_table=terraform-lock"

terraform plan -var-file="terraform.tfvars"
terraform apply -var-file="terraform.tfvars"

# 3. SSMで接続
INSTANCE_ID=$(terraform output -raw ec2_instance_id)
aws ssm start-session --target $INSTANCE_ID --region ap-northeast-1

# 4. EC2内でPostfixの状態確認
sudo systemctl status postfix
sudo mailq
sudo postconf -n

# 5. telnetでSMTP手打ちテスト（EC2内から）
telnet localhost 25
# → EHLO / MAIL FROM / RCPT TO / DATA を手打ちしてみる

# ⚠️ Phase 3（SES設定）完了後に実際のメール送信が可能になる
```

## Phase 2完了の確認チェックリスト（コメントとして出力すること）

- [ ] EC2が起動している（SSMで接続できる）
- [ ] Postfixが起動している（`systemctl status postfix` がactive）
- [ ] port 25がリスンしている（`ss -tlnp | grep 25`）
- [ ] `telnet localhost 25` でSMTP会話ができる
- [ ] `mail.{ドメイン}` のAレコードがElastic IPを向いている
- [ ] メールキューを確認できる（`mailq`）

## Phase 3への引き継ぎ情報（コメントとして出力すること）

```
Phase 3で必要な情報:
- ec2_instance_id: $(terraform output -raw ec2_instance_id)
- ec2_elastic_ip: $(terraform output -raw ec2_elastic_ip)
- hosted_zone_id: {Phase 1の値}
- domain_name: {Phase 1の値}

Phase 3では:
- SESでドメイン検証（DKIM含む）
- SES SMTPクレデンシャルを生成してPostfixに設定
- バウンス・苦情処理のパイプラインを構築
- 実際にメールを送信して全フローを確認
```