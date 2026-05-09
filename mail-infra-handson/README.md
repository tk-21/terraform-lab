# mail-infra-handson

AWS × Terraform でメールインフラを一から構築するハンズオンです。  
「なんとなく SES を使っていた」状態から、「なぜこの構成で安全に運用できるのか」を説明できるレベルを目指します。

---

## このハンズオンで身につくこと

メールは「送れた」で終わりではありません。DNS、認証、レピュテーション、受信対策まで揃ってはじめて運用できます。

| よくある失敗 | 原因 | このハンズオンで学べること |
|---|---|---|
| メールがスパムフォルダに入る | SPF / DKIM / DMARC 未設定 | Phase 1・4 でメール認証を理解する |
| SES アカウントが突然停止する | バウンス率 5% 超 / 苦情率 0.1% 超 | Phase 3・5 で監視と自動対処を入れる |
| 存在しないアドレスに送り続ける | サプレッションリスト未管理 | Phase 3・5 で抑止リストを自動管理する |
| 受信メールがスパムまみれになる | 受信時のフィルタがない | Phase 5 で Lambda による受信判定を入れる |

---

## この README の使い方

この README は「実行手順書」です。先に全体構成を知りたい場合は [ARCHITECTURE.md](/home/takuya/terraform-lab/mail-infra-handson/ARCHITECTURE.md) を読んでください。

各フェーズでは次の順番で進めるのがおすすめです。

1. README の手順を読む
2. 対応する `phases/phaseX.md` を読んで理論背景を理解する
3. `terraform plan` を確認する
4. 問題なければ自分で `terraform apply` を実行する
5. apply 後の確認を行う

重要:

- `terraform apply` / `terraform destroy` / `terraform import` は必ず自分で実行してください
- この README のコマンド例は、基本的にリポジトリルートである `/mail-infra-handson` から実行する前提です

---

## 前提条件

- AWS アカウント（管理者権限）
- Terraform v1.5 以上
- AWS CLI v2
- 独自ドメイン
- Python 3.11 以上

費用の目安:

- 常時運用の最小構成で約 `$4/月`
- Phase 2 の EC2 は学習用です。残すと追加コストがかかるため、学習後は削除してください

---

## ハンズオン全体の流れ

```text
[Phase 1] DNS基盤
    ↓
[Phase 2] Postfix で SMTP を体感
    ↓
[Phase 3] SES 送受信とバウンス管理
    ↓
[Phase 4] DKIM / DMARC 強化
    ↓
[Phase 5] 監視・スパム対策・VPC Endpoint
```

目安時間:

- Phase 1: 2〜3 時間
- Phase 2: 1〜2 時間
- Phase 3: 3〜4 時間
- Phase 4: 2〜3 時間
- Phase 5: 3〜4 時間

補足:

- Phase 2 は学習用の寄り道です
- SMTP の会話を体感したら、主役は Phase 3 以降の SES ベース構成に移ります

---

## 最初のセットアップ

### 1. リポジトリルートへ移動する

```bash
cd /path/to/mail-infra-handson
pwd
```

### 2. Python 仮想環境を作成して有効化する

```bash
python3 -m venv .venv
source .venv/bin/activate
which python
```

`which python` の結果が `.venv/bin/python` なら OK です。

### 3. AWS 接続確認

```bash
aws sts get-caller-identity
aws configure list
```

ここで失敗する場合は、Terraform 実行前に AWS 認証設定を直してください。

### 4. Terraform と Python のバージョン確認

```bash
terraform version
python --version
```

### 5. `terraform.tfvars` を作成する

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
vi terraform/terraform.tfvars
```

最低限、次の値を設定します。

```hcl
domain_name = "example.com"
admin_email = "your-name@example.com"
```

設定の意味:

- `domain_name`: 構築対象ドメイン
- `admin_email`: SES / CloudWatch / SNS の通知先

### 6. 読み始める順番

- 全体像を先に知りたい: `ARCHITECTURE.md`
- DNS の理論から入りたい: `phases/phase1.md`
- SMTP コマンドを見ながら進めたい: `docs/protocol-cheatsheet.md`

---

## Terraform 実行の基本形

各フェーズで Terraform を実行するときの基本形です。

```bash
cd terraform
terraform init
terraform plan -var-file="terraform.tfvars"
terraform apply -var-file="terraform.tfvars"
```

補足:

- 初回だけ `terraform init` が必要です
- `plan` で何が増えるか、消えるか、更新されるかを見てから `apply` してください
- 実際のインフラ変更は `apply` で発生します

---

## Phase 1: DNS 基盤を作る

ゴール:

- Route 53 でドメインを管理する
- メール受信に必要な MX レコードを作る
- SPF / DMARC の最初の設定を入れる

学ぶこと:

- メール配送フロー
- DNS とメールの関係
- SPF / DMARC の役割

先に読む資料:

- `phases/phase1.md`
- `docs/protocol-cheatsheet.md`

### 実行手順

```bash
cd terraform
terraform init
terraform plan -var-file="terraform.tfvars"
terraform apply -var-file="terraform.tfvars"
```

### apply 後に必ずやること

まず、Route 53 のネームサーバーを確認します。

```bash
terraform output name_servers
```

出力されたネームサーバーを、ドメインレジストラの管理画面に設定してください。これをやらないと、Route 53 にレコードが作られていても外部公開されません。

その後、DNS 伝播を待って確認します。

```bash
bash ../scripts/check-dns.sh your-domain.com
dig NS your-domain.com
dig MX your-domain.com
dig TXT your-domain.com
dig TXT _dmarc.your-domain.com
```

### 完了の目安

- `dig NS` で Route 53 の NS が返る
- `dig MX` で SES の inbound エンドポイントが返る
- `dig TXT your-domain.com` で SPF が返る
- `dig TXT _dmarc.your-domain.com` で DMARC が返る

### 詰まりやすいポイント

- NS をレジストラに反映していない
- DNS 伝播前に確認している
- `domain_name` を誤って設定している

---

## Phase 2: Postfix で SMTP を体感する

ゴール:

- Postfix を動かして SMTP の流れを体感する
- `EHLO` / `MAIL FROM` / `RCPT TO` / `DATA` を理解する

学ぶこと:

- MTA の役割
- SMTP セッションの流れ
- メール配送ログの見方

先に読む資料:

- `phases/phase2.md`
- `docs/protocol-cheatsheet.md`

### 実行手順

```bash
cd terraform
terraform plan -var-file="terraform.tfvars"
terraform apply -var-file="terraform.tfvars"
terraform output -raw ec2_public_ip
```

EC2 に接続して Postfix の状態を確認します。

```bash
ssh ec2-user@$(terraform output -raw ec2_public_ip)
sudo systemctl status postfix
sudo tail -f /var/log/maillog
exit
```

次に、SMTP を手動で試します。

```bash
bash ../scripts/smtp-test.sh $(terraform output -raw ec2_public_ip)
```

### 完了の目安

- Postfix が `active (running)` になっている
- SMTP コマンドの流れを説明できる
- ログで配送処理の痕跡が見える

### Phase 3 に進む前に

Phase 2 の EC2 は学習用です。不要になったら必ず削除してください。

```bash
# 自分で実行
# cd terraform
# terraform destroy -var-file="terraform.tfvars"
```

### 困ったとき

- `docs/troubleshooting.md` の「Postfix が起動しない」を確認する

---

## Phase 3: AWS SES に移行する

ゴール:

- SES でドメイン Identity を作る
- バウンス / 苦情を自動管理する
- 受信メールを S3 に保存できるようにする

学ぶこと:

- SES Configuration Set
- SNS によるイベント通知
- DynamoDB サプレッションリスト
- Lambda によるバウンス処理

先に読む資料:

- `phases/phase3.md`

### 実行手順

```bash
cd terraform
terraform plan -var-file="terraform.tfvars"
terraform apply -var-file="terraform.tfvars"
```

### apply 後にやること

まず、SES の検証状態を確認します。

```bash
terraform output ses_verification_status
```

`SUCCESS` でない場合は、DNS 伝播待ちか NS 未切り替えの可能性があります。必要に応じて AWS コンソールの `SES > Email Identities` でも確認してください。

次に、テストメールを送信します。

```bash
source ../.venv/bin/activate
python3 ../scripts/send-test-mail.py --to you@example.com
```

Postfix から SES SMTP を使う場合は、SMTP 認証情報の設定も行います。

```bash
bash ../scripts/ses-setup.sh
```

### 追加確認

バウンス/苦情パイプラインの保存先確認:

```bash
aws dynamodb scan \
  --table-name mail-handson-suppression-list \
  --region ap-northeast-1
```

### 完了の目安

- SES Identity が `Verified` になっている
- DKIM CNAME が 3 本作成されている
- テストメールが届く
- ヘッダーで `amazonses.com` 経由送信を確認できる

### 困ったとき

- `docs/troubleshooting.md` の「SES 送信エラー」を確認する

---

## Phase 4: DKIM と DMARC を実装する

ゴール:

- メール認証を実運用レベルで理解する
- DKIM / DMARC が本当に効いていることを確認する

学ぶこと:

- DKIM の署名と検証
- DMARC ポリシーの意味
- 段階的移行の考え方

先に読む資料:

- `phases/phase4.md`
- `docs/dmarc-migration-guide.md`

### 実行手順

```bash
cd terraform
terraform plan -var-file="terraform.tfvars"
terraform apply -var-file="terraform.tfvars"
```

DNS を確認します。

```bash
bash ../scripts/check-dmarc.sh your-domain.com
dig TXT _dmarc.your-domain.com
```

次に、実際のメールヘッダーを解析します。

```bash
source ../.venv/bin/activate
python3 ../scripts/analyze-mail-header.py --file ~/Downloads/test-mail.eml
```

### 完了の目安

- `Authentication-Results:` に `dkim=pass` がある
- `Authentication-Results:` に `dmarc=pass` がある
- DKIM CNAME が DNS 上で見える
- DMARC レコードが想定どおりのポリシーで引ける

### DMARC の進め方

いきなり `p=reject` にするのではなく、次の順番がおすすめです。

1. `p=none` で監視
2. `p=quarantine` に変更
3. 問題がないことを確認して `p=reject` に変更

詳しくは `docs/dmarc-migration-guide.md` を参照してください。

---

## Phase 5: 監視・スパムフィルタ・VPC Endpoint を追加する

ゴール:

- CloudWatch で SES を監視する
- スパム判定を受信パイプラインに入れる
- SES SMTP を PrivateLink 化する
- suppression list の定期同期を有効にする

学ぶこと:

- CloudWatch アラーム設計
- Lambda によるスパム受信判定
- VPC Endpoint の考え方
- EventBridge Scheduler による定期実行

先に読む資料:

- `phases/phase5.md`

### 実行手順

```bash
cd terraform
terraform plan -var-file="terraform.tfvars"
terraform apply -var-file="terraform.tfvars"
```

### apply 後にやること

まず、SNS 通知を有効化します。`admin_email` に確認メールが届いているので、`Confirm subscription` をクリックしてください。

その後、次を確認します。

```bash
aws ses describe-active-receipt-rule-set
```

AWS コンソール側でも確認します。

- `CloudWatch > Dashboards > mail-handson-dashboard`
- `SES > Receipt rule sets`

VPC Endpoint の状態も見ておくと安心です。

```bash
aws ec2 describe-vpc-endpoints \
  --filters "Name=service-name,Values=com.amazonaws.ap-northeast-1.email-smtp" \
  --region ap-northeast-1
```

### 完了の目安

- CloudWatch ダッシュボードに SES の送信数・バウンス率・苦情率が表示される
- `with-spam-check` が Receipt Rule の先頭にある
- SNS サブスクリプションが Confirm 済み
- VPC Endpoint が `available` になっている

### 困ったとき

- `docs/troubleshooting.md` を確認する

---

## どのフェーズでも使う確認コマンド

```bash
# Terraform の出力確認
cd terraform
terraform output

# SES のドメイン検証状態
aws sesv2 get-email-identity \
  --email-identity your-domain.com \
  --region ap-northeast-1

# Receipt Rule Set の確認
aws ses describe-active-receipt-rule-set

# suppression list の確認
aws dynamodb scan \
  --table-name mail-handson-suppression-list \
  --region ap-northeast-1

# DNS の確認
dig MX your-domain.com
dig TXT your-domain.com
dig TXT _dmarc.your-domain.com
```

---

## 最短で進めたい人向けの実行順まとめ

1. `.venv` を作って有効化する
2. `terraform/terraform.tfvars` に `domain_name` と `admin_email` を設定する
3. Phase 1 を実行し、NS をレジストラに設定する
4. DNS 伝播後、Phase 3 を実行して SES Identity を Verified にする
5. テストメールを送って動作確認する
6. Phase 4 で DKIM / DMARC を確認する
7. Phase 5 で監視・スパム判定・VPC Endpoint を有効化する
8. `docs/production-checklist.md` で本番前確認を行う

---

## 全フェーズ完了後：本番移行前チェック

本番運用に切り替える前に必ず確認してください。  
`docs/production-checklist.md` を開いて、すべての項目にチェックを入れます。

主な確認項目:

- [ ] Route 53 のネームサーバーをドメインレジストラに設定済み
- [ ] SES ドメインが Verified になっている
- [ ] SNS アラーム通知のサブスクリプションが有効化済み
- [ ] DMARC ポリシーを `p=reject` に移行済み
- [ ] SES サンドボックス解除申請済み
- [ ] バウンス率が 2% 以下・苦情率が 0.04% 以下

---

## 完成したシステムの全体像

全フェーズ完了後に動いているものの全体図です。  
詳しいコンポーネント解説は `ARCHITECTURE.md` を参照してください。

```text
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
| `ARCHITECTURE.md` | 全体像を把握したいとき・コードレビュー時 |
| `docs/protocol-cheatsheet.md` | Phase 2 で SMTP コマンドに詰まったとき |
| `docs/troubleshooting.md` | エラー調査をしたいとき |
| `docs/dmarc-migration-guide.md` | DMARC を `p=reject` へ移行するとき |
| `docs/production-checklist.md` | 本番移行前の確認をするとき |
