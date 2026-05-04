# mail-infra-handson

AWS × Terraform でメールインフラを一から構築するハンズオン。  
「なんとなく SES を使っていた」から「設計・運用まで説明できる」レベルを目指す。

---

## このハンズオンで身につくこと

メールは「送れた」だけでは不十分です。設定ミスが即サービス障害につながります。

| よくある失敗 | 原因 | このハンズオンで解決する |
|---|---|---|
| メールがスパムフォルダに入る | SPF/DKIM/DMARC 未設定 | Phase 1・4 で認証レコードを実装 |
| SES アカウントが突然停止する | バウンス率 5% 超 / 苦情率 0.1% 超 | Phase 3 でバウンス自動管理を構築 |
| 存在しないアドレスに送り続ける | サプレッションリスト未管理 | Phase 5 で DynamoDB-SES 自動同期 |
| 受信メールがスパムまみれになる | 受信フィルタなし | Phase 5 で Lambda スパム判定を実装 |

---

## 前提条件

- AWS アカウント（管理者権限）
- Terraform v1.5 以上・AWS CLI v2（プロファイル設定済み）
- 独自ドメイン（ハンズオン内で Route 53 取得可）
- 費用の目安: **約 $4/月**（Phase 2 の EC2 は学習後すぐ削除で +$0）

---

## ハンズオンの流れ

```
[Phase 1] DNS基盤 ──► [Phase 2] Postfix ──► [Phase 3] SES移行 ──► [Phase 4] DKIM/DMARC ──► [Phase 5] 監視・強化
 2〜3時間               1〜2時間               3〜4時間               2〜3時間                  3〜4時間
```

> **Phase 2 は学習用の寄り道です。** SMTP の動作を手で体感したら Phase 3 で SES に移行します。EC2 費用（$6/月）がかかるため、Phase 3 に進んだら必ず削除してください。

---

## 事前準備

```bash
# AWS 接続確認
aws sts get-caller-identity

# Terraform バージョン確認（1.5.0 以上）
terraform version

# tfvars を作成（domain_name と admin_email を設定する）
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
vi terraform/terraform.tfvars
```

---

## Phase 1: DNS 基盤を作る

**ゴール**: Route 53 でドメインを管理し、メール受信に必要な MX・SPF レコードを設定する。  
**学ぶこと**: メール配送フロー（MUA → MTA → MDA）、DNS とメールの関係、SPF の仕組み。

> 理論を先に読む → `phases/phase1.md`  
> SMTP コマンドの意味が気になったら → `docs/protocol-cheatsheet.md`

```bash
cd terraform
terraform init
terraform plan -var-file="terraform.tfvars"
# ↑ 問題なければ自分で apply する
terraform apply -var-file="terraform.tfvars"
```

**apply 後にやること**:

```bash
# Route 53 のネームサーバーを確認して、ドメインレジストラの管理画面に設定する
terraform output name_servers

# DNS が浸透したら確認（数分〜数時間かかることがある）
bash scripts/check-dns.sh your-domain.com
```

**完了の目安**: `dig MX your-domain.com` で SES のエンドポイントが返ってくること。

---

## Phase 2: Postfix で SMTP を体感する（学習用）

**ゴール**: SMTP コマンドを手で打ってメール配送の仕組みを体感する。  
**学ぶこと**: EHLO/MAIL FROM/RCPT TO/DATA、Postfix の設定、MTA の役割。

> 理論を先に読む → `phases/phase2.md`  
> SMTP コマンド一覧 → `docs/protocol-cheatsheet.md`

```bash
terraform apply -var-file="terraform.tfvars"

# EC2 に SSH して Postfix の状態を確認
ssh ec2-user@$(terraform output -raw ec2_public_ip)
sudo systemctl status postfix
sudo tail -f /var/log/maillog

# telnet で SMTP を手動操作する
bash scripts/smtp-test.sh $(terraform output -raw ec2_public_ip)
```

**Phase 3 に進む前に EC2 を削除する**:

```bash
# terraform destroy -var-file="terraform.tfvars"  # 自分で実行
```

> **困ったとき** → `docs/troubleshooting.md` の「Postfix が起動しない」を確認する。

---

## Phase 3: AWS SES に移行する

**ゴール**: Postfix を SES に置き換え、バウンス・苦情を自動管理する仕組みを作る。  
**学ぶこと**: SES Configuration Set、SNS によるイベント通知、DynamoDB サプレッションリスト、Lambda でのバウンス処理。

> 理論を先に読む → `phases/phase3.md`

```bash
terraform apply -var-file="terraform.tfvars"
```

**apply 後にやること**:

```bash
# AWS コンソールで SES → Email Identities → ドメインが "Verified" になっているか確認

# テストメールを送信する
python3 scripts/send-test-mail.py --to you@example.com

# SES の SMTP 認証情報をセットアップする（初回のみ）
bash scripts/ses-setup.sh
```

**完了の目安**: テストメールが届き、ヘッダーに `via amazonses.com` が含まれること。

> **困ったとき** → `docs/troubleshooting.md` の「SES 送信エラー」を確認する。

---

## Phase 4: DKIM と DMARC を実装する

**ゴール**: メール認証を完全実装して、なりすましメール扱いされないようにする。  
**学ぶこと**: DKIM 署名の仕組み（公開鍵/秘密鍵）、DMARC ポリシーの意味、段階的移行の考え方。

> 理論を先に読む → `phases/phase4.md`

```bash
terraform apply -var-file="terraform.tfvars"

# DMARC と DKIM レコードを確認する
bash scripts/check-dmarc.sh your-domain.com
dig TXT _dmarc.your-domain.com
```

**apply 後にやること**:

```bash
# テストメールのヘッダーを解析して dkim=pass / dmarc=pass を確認する
python3 scripts/analyze-mail-header.py --file ~/Downloads/test-mail.eml
```

`Authentication-Results:` に `dkim=pass` と `dmarc=pass` が含まれれば成功。

**DMARC ポリシーの段階的強化**:  
初期設定は `p=none`（監視のみ）です。数週間〜1ヶ月かけて `p=quarantine` → `p=reject` に移行します。  
→ 手順は **`docs/dmarc-migration-guide.md`** を参照してください。

---

## Phase 5: 監視・スパムフィルタ・VPC Endpoint を追加する

**ゴール**: 本番運用できるレベルの監視と防御を実装する。  
**学ぶこと**: CloudWatch アラーム設計（バウンス率 3% / 苦情率 0.05%）、Lambda によるスパム受信判定、VPC Endpoint（PrivateLink）の仕組み、EventBridge Scheduler。

> 理論を先に読む → `phases/phase5.md`

```bash
terraform apply -var-file="terraform.tfvars"
```

**apply 後にやること**:

```bash
# SNS 通知の確認メールが届いているので「Confirm subscription」リンクをクリックする
# （クリックしないとアラームが届かない）

# CloudWatch ダッシュボードを確認する
# AWS コンソール → CloudWatch → Dashboards → mail-handson-dashboard

# SES Receipt Rules の順序を確認する（with-spam-check が先頭にあること）
aws ses describe-active-receipt-rule-set
```

**完了の目安**:
- CloudWatch ダッシュボードに SES の送信数・バウンス率・苦情率が表示されること
- SES Receipt Rules で `with-spam-check` ルールが先頭にあること

> **困ったとき** → `docs/troubleshooting.md` を確認する。

---

## 全フェーズ完了後：本番移行前チェック

本番運用に切り替える前に必ず確認してください。  
→ **`docs/production-checklist.md`** を開いてすべての項目にチェックを入れる。

主な確認項目:

- [ ] Route 53 のネームサーバーをドメインレジストラに設定済み
- [ ] SES ドメインが Verified になっている
- [ ] SNS アラーム通知のサブスクリプションが有効化済み
- [ ] DMARC ポリシーを `p=reject` に移行済み（`docs/dmarc-migration-guide.md` 参照）
- [ ] SES サンドボックスの解除申請済み（本番メール送信には必須）
- [ ] バウンス率が 2% 以下・苦情率が 0.04% 以下

---

## 完成したシステムの全体像

全フェーズ完了後に動いているものの全体図です。  
詳しいコンポーネント解説は **`docs/architecture.md`** を参照してください。

```
あなたのアプリ / EC2
      │ SMTP（VPC Endpoint 経由・AWS 内で完結）
      ▼
  AWS SES ──────────────────────────────────────► 受信者へ配送
      │
      │ バウンス/苦情が発生したとき
      ▼
  SNS → Lambda(bounce_handler) → DynamoDB(サプレッションリスト)
                                       │
                                       │ 毎日 AM2:00（JST）に自動同期
                                       ▼
                              SES アカウントレベルサプレッションリスト
                              （同じアドレスへの再送を自動ブロック）

  バウンス率 3% 超 or 苦情率 0.05% 超
      → CloudWatch Alarm → SNS → あなたのメールへ通知

  外部からのメール受信
      → SES Receipt Rules
          → Lambda(spam_handler) でスパム判定
              SPAM: 破棄（S3 に保存しない）
              正常: S3 に保存 → 後続処理へ
```

---

## ドキュメント一覧

| ドキュメント | いつ使うか |
|---|---|
| `docs/architecture.md` | 全体像を把握したいとき・コードレビュー時 |
| `docs/protocol-cheatsheet.md` | Phase 2 で SMTP コマンドに詰まったとき |
| `docs/troubleshooting.md` | なにかエラーが出たとき |
| `docs/dmarc-migration-guide.md` | Phase 4 完了後、DMARC を `p=reject` へ移行するとき |
| `docs/production-checklist.md` | 全フェーズ完了後、本番移行する前 |
