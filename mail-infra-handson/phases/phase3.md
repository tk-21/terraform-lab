# ✅Phase 3: AWS SES本格構成
# 「マネージドメールインフラの設計と運用を学ぶ」
#
# 実行方法: claude < phases/phase3.md
# 所要時間: 3〜4時間
# 前提: Phase 1（DNS）・Phase 2（Postfix EC2）完了済み

## Phase 1・2の完了確認

```bash
# Phase 1の値
cd terraform/phase1
terraform output hosted_zone_id
terraform output domain_name

# Phase 2の値
cd ../phase2
terraform output ec2_instance_id
terraform output ec2_elastic_ip
```

---

## このフェーズのゴール

1. SESでドメインを検証し、メール送信権限を取得する
2. SES経由でPostfixからメールを実際に送信する
3. SESの受信ルール（Receipt Rules）でメールをS3に保存する
4. バウンス・苦情の自動処理パイプラインを構築する

---

## 理論解説（実装前に必ず読むこと）

### SESのアーキテクチャ概要

```
【送信フロー】
Postfix on EC2
  → SMTP(587) + STARTTLS
  → SES SMTPエンドポイント (email-smtp.ap-northeast-1.amazonaws.com)
  → SESがSPF/DKIMを付与して外部配送

【受信フロー（SES Inbound）】
外部からのメール
  → MXレコードで inbound-smtp.ap-northeast-1.amazonaws.com へ
  → SES Receipt Rules で振り分け
  → S3保存 / Lambda処理 / SNS通知 / etc.
```

### SES Identity検証の仕組み

```
ドメイン検証プロセス:
1. SESがDNS検証用TXTレコードを生成
2. Route 53に _amazonses.{domain} のTXTレコードを追加
3. SESが定期的にDNSをポーリングして検証完了を確認

DKIMはEasy DKIM（SES管理）を使う:
- SESが3つのCNAMEレコードを生成
- Route 53に追加すると自動的にDKIM署名が有効になる
- Phase 4でこのDKIMレコードを詳しく学ぶ
```

### バウンスと苦情の仕組み

```
【バウンス（Bounce）】
Hard Bounce: 宛先アドレスが存在しない → 永続的エラー
Soft Bounce: メールボックス満杯・サーバー一時停止 → 一時的エラー

バウンス率 > 5% → SESアカウントが停止される

【苦情（Complaint）】
受信者が「迷惑メール」ボタンを押した
苦情率 > 0.1% → SESアカウントが停止される

【処理フロー】
SES
 → SNS Topic（bounce/complaint）
 → Lambda（DynamoDBにサプレッションリストとして記録）
 → 以降そのアドレスへの送信をスキップ
```

### サンドボックスと本番環境

```
初期状態: サンドボックスモード
- 送信先: 検証済みメールアドレスのみ
- 送信制限: 200通/日、1通/秒

本番移行: AWSコンソールから申請（Production Access Request）
- 送信先制限なし
- 送信上限はサービスクォータで管理

※ このハンズオンではサンドボックスのまま学習可能
```

---

## タスク: 以下のTerraformコードとLambdaを生成してください

### 生成するファイル一覧

1. `terraform/phase3/main.tf`
2. `terraform/phase3/variables.tf`
3. `terraform/phase3/outputs.tf`
4. `terraform/phase3/terraform.tfvars.example`
5. `terraform/phase3/lambda/bounce_handler.py`
6. `scripts/send-test-mail.py`
7. `scripts/ses-setup.sh`

---

### main.tf の要件

#### SES Email Identity（ドメイン）
```hcl
resource "aws_sesv2_email_identity" "domain" {
  # ドメイン全体を検証することで、サブドメイン含めて送信可能になる
  email_identity = var.domain_name

  dkim_signing_attributes {
    # Easy DKIMを使用: SESが鍵管理を自動で行う
    # next_signing_key_length: RSA_2048_BIT が推奨（セキュリティと互換性のバランス）
    next_signing_key_length = "RSA_2048_BIT"
  }
}
```

#### Route 53 DKIM CNAMEレコード（3つ）
- SESが生成するDKIMトークンをRoute 53に登録
- `aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens` から取得
- `for_each` でループして3つのCNAMEを作成
- 日本語コメント: DKIMレコードが3つある理由（ローテーション用）

#### Route 53 SES検証TXTレコード
- `_amazonses.{domain}` にTXTレコードを作成
- `aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens` から取得
- 日本語コメント: このレコードがない場合に何が起きるか

#### S3バケット（受信メール保存用）
```hcl
# バケット名: mail-handson-inbound-{ランダムサフィックス}
# バージョニング: 有効
# 暗号化: SSE-S3
# ライフサイクル: 30日後にGlacierへ移行、90日後に削除
# パブリックアクセス: すべてブロック
# バケットポリシー: SESからのPutObject許可のみ
```

SESがS3に書き込むためのバケットポリシー:
```json
{
  "Effect": "Allow",
  "Principal": {"Service": "ses.amazonaws.com"},
  "Action": "s3:PutObject",
  "Resource": "arn:aws:s3:::bucket-name/*",
  "Condition": {
    "StringEquals": {"aws:Referer": "{AWS_ACCOUNT_ID}"}
  }
}
```

#### SNS Topic（バウンス用）
- トピック名: `mail-handson-bounce-topic`
- KMS暗号化: AWSマネージドキーを使用
- 日本語コメント: なぜバウンス通知にSNSを使うか

#### SNS Topic（苦情用）
- トピック名: `mail-handson-complaint-topic`

#### DynamoDB テーブル（サプレッションリスト）
```hcl
# テーブル名: mail-handson-suppression-list
# パーティションキー: email (String)
# ソートキー: reason (String) ← "bounce" or "complaint"
# TTL属性: expires_at（バウンスは90日、苦情は永続）
# 課金モード: PAY_PER_REQUEST
```

#### Lambda（バウンス・苦情ハンドラー）
- 関数名: `mail-handson-bounce-handler`（64文字以内）
- ランタイム: Python 3.12
- アーキテクチャ: arm64
- タイムアウト: 30秒
- メモリ: 128MB
- 環境変数: `DYNAMODB_TABLE_NAME`, `LOG_LEVEL=INFO`
- Lambda Powertools Layer: 使用
- SNSトリガー: bounce + complaint の両トピックをトリガーに設定

#### SES Configuration Set
```hcl
resource "aws_sesv2_configuration_set" "main" {
  configuration_set_name = "mail-handson-config-set"

  # バウンス・苦情のイベント通知設定
  # CloudWatchへのメトリクス送信も有効にする
}
```

#### SES Event Destination（SNS）
- Configuration SetからSNSへバウンス/苦情イベントを送信

#### SES Receipt Rule Set（受信ルール）
```hcl
resource "aws_ses_receipt_rule_set" "main" {
  rule_set_name = "mail-handson-receipt-rules"
}

resource "aws_ses_active_receipt_rule_set" "main" {
  rule_set_name = aws_ses_receipt_rule_set.main.rule_set_name
}

resource "aws_ses_receipt_rule" "store_to_s3" {
  # 受信メールをS3に保存するルール
  # recipients: [] = 全アドレスを対象
  # actions: S3アクション + Lambda通知
}
```

#### IAM Role（Lambda用）
- ロール名: `mail-handson-bounce-lambda-role`（64文字以内）
- 権限:
  - CloudWatch Logs（Lambda基本実行権限）
  - DynamoDB PutItem/GetItem/UpdateItem（サプレッションリストの読み書き）
  - ❌ SES書き込み系は付与しない（Lambda自身がメール送信する必要はない）

---

### lambda/bounce_handler.py の要件

```python
"""
バウンス・苦情ハンドラー Lambda関数

役割:
- SNSからバウンス/苦情イベントを受け取る
- DynamoDBのサプレッションリストに記録する
- 同じアドレスへの重複送信を防ぐ

設計原則:
- Lambda Powertools でログ・トレース
- 冪等性を保証（同じイベントを複数回処理しても結果が変わらない）
- ハードバウンス: TTLなし（永続的に送信停止）
- ソフトバウンス: TTL 30日
- 苦情: TTLなし（永続的に送信停止）
"""

# 以下を実装すること:
# 1. SNSイベントのパース
# 2. メッセージタイプの判定（Bounce / Complaint）
# 3. バウンスタイプの判定（Hard / Soft）
# 4. DynamoDBへの記録（条件付きPutItem）
# 5. Lambda Powertoolsでの構造化ログ出力
# 6. エラーハンドリングとリトライ考慮
```

---

### scripts/send-test-mail.py の要件

```python
#!/usr/bin/env python3
"""
SES経由でテストメールを送信するスクリプト
boto3のSES APIを直接使用（SMTPを使わない方法の確認）

使用方法:
  python3 scripts/send-test-mail.py \\
    --from sender@your-domain.com \\
    --to recipient@example.com \\
    --region ap-northeast-1

確認できること:
- SES API経由での送信（Postfix不要）
- 送信レスポンス（MessageId）
- メールヘッダーの確認方法
"""

# 実装内容:
# 1. argparseで引数処理
# 2. boto3でSESクライアント作成
# 3. send_email()でHTMLメール送信
# 4. ConfigurationSet名を指定（トラッキング有効化）
# 5. 送信結果（MessageId）を表示
# 6. 「次の確認ポイント」を日本語でprint
```

---

### scripts/ses-setup.sh の要件

SES SMTPクレデンシャルを生成してPostfixに設定するスクリプト:

```bash
#!/bin/bash
# SES SMTPクレデンシャルの生成とPostfix設定
#
# SES SMTPクレデンシャルはIAMユーザーのアクセスキーから変換して生成される
# 通常のIAMアクセスキーとは異なるフォーマット（SMTP専用の変換が必要）
#
# 手順:
# 1. IAMユーザー作成（SES送信権限のみ）
# 2. アクセスキー生成
# 3. SES SMTPパスワードへの変換（AWS提供のアルゴリズムで変換）
# 4. /etc/postfix/sasl_passwd に書き込み
# 5. postmap でハッシュ化
# 6. postfix reload
#
# 参考: aws ses generate-smtp-data-token は廃止済み
# 現在は IAM アクセスキーを SigV4 で変換してSMTPパスワードを生成
```

---

## 生成後の実行手順（コメントとして出力すること）

```bash
# 1. Terraform実行
cd terraform/phase3
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=...
terraform plan -var-file="terraform.tfvars"
terraform apply -var-file="terraform.tfvars"

# 2. SESドメイン検証の確認（数分かかる場合あり）
aws sesv2 get-email-identity \
  --email-identity your-domain.com \
  --region ap-northeast-1 \
  --query 'VerificationStatus'

# 3. SES SMTPクレデンシャルをPostfixに設定
./scripts/ses-setup.sh

# 4. テストメール送信（SES APIから）
python3 scripts/send-test-mail.py \
  --from sender@your-domain.com \
  --to verified-recipient@example.com

# 5. バウンスイベントのテスト
# SESのテスト用バウンスアドレスを使用
# bounce@simulator.amazonses.com

# 6. DynamoDBでサプレッションリストを確認
aws dynamodb scan \
  --table-name mail-handson-suppression-list \
  --region ap-northeast-1
```

## Phase 3完了の確認チェックリスト（コメントとして出力すること）

- [ ] SESドメイン検証が完了している（VerificationStatus: SUCCESS）
- [ ] DKIM CNAMEレコードが3つRoute 53に登録されている
- [ ] テストメールが送信できる
- [ ] バウンス通知がSNS → Lambda → DynamoDBへ流れる
- [ ] S3に受信メールが保存される
- [ ] CloudWatchにSESメトリクスが出ている

## Phase 4への引き継ぎ情報（コメントとして出力すること）

```
Phase 4では:
- DKIM署名の仕組みを詳しく理解する（公開鍵・秘密鍵・署名検証）
- DMARCポリシーを p=none → p=quarantine → p=reject へ段階移行
- mail-tester.com で認証スコアを計測
- 実際のメールヘッダーを解析してSPF/DKIM/DMARCの結果を確認
```