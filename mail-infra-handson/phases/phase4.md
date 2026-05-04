# ✅Phase 4: DKIM / DMARC 完全実装
# 「なりすましメールが届く仕組みと、防ぐ方法を実装で理解する」
#
# 実行方法: claude < phases/phase4.md
# 所要時間: 2〜3時間
# 前提: Phase 1〜3完了済み（SESドメイン検証済み）

## このフェーズのゴール

1. DKIM署名の仕組みを実際のメールヘッダーで確認する
2. DMARCポリシーを段階的に強化する（none → quarantine → reject）
3. mail-tester.com でメール認証スコア10/10を目指す
4. DMARCレポートを受信・解析できる環境を作る

---

## 理論解説（実装前に必ず読むこと）

### DKIM（DomainKeys Identified Mail）の仕組み

```
【署名の生成（送信時）】
1. SESが秘密鍵でメール本文・特定ヘッダーのハッシュを生成
2. そのハッシュを電子署名してDKIM-Signatureヘッダーに付与

DKIM-Signature: v=1; a=rsa-sha256; c=relaxed/relaxed;
  d=example.com; s=selector1;
  h=from:to:subject:date;
  b=<base64エンコードされた署名>;

【検証（受信時）】
1. 受信MTAがDKIM-SignatureヘッダーのDNSセレクタを確認
   selector._domainkey.example.com のTXTレコードを引く
2. 公開鍵を取得して署名を検証
3. ハッシュが一致 → 改ざんなし・送信元ドメインが正当
```

### SESのEasy DKIMで3つのCNAMEが必要な理由

```
SESは自動で鍵ローテーションを行う（セキュリティのベストプラクティス）

3つのCNAMEレコード:
  selector1._domainkey.example.com → CNAME → SES管理のDNSレコード
  selector2._domainkey.example.com → CNAME → SES管理のDNSレコード
  selector3._domainkey.example.com → CNAME → SES管理のDNSレコード

現在使われていないセレクタは次のローテーション時に使われる
→ ダウンタイムなしで鍵交換ができる仕組み
```

### SPF・DKIM・DMARCのアライメント（DMARCの核心）

```
【アライメントとは】
From: ヘッダーのドメインと、SPF/DKIMで使われるドメインが一致すること

SPFアライメント:
  From: user@example.com
  SMTP MAIL FROM: bounce@example.com  ← example.com が一致 ✅

DKIMアライメント:
  From: user@example.com
  DKIM-Signature: d=example.com  ← example.com が一致 ✅

【DMARCが判定するロジック】
SPFがPass AND SPFアライメント = OK → DMARC Pass
DKIMがPass AND DKIMアライメント = OK → DMARC Pass
どちらか一方でも OK なら → DMARC Pass

両方NGなら → DMARCポリシーに従って処理

【DMARCポリシー段階】
p=none       → 失敗してもメール配送。レポートのみ収集
p=quarantine → 失敗したメールをスパムフォルダへ
p=reject     → 失敗したメールを拒否（最も厳格）
```

### DMARCレポートの種類

```
【集計レポート（Aggregate Report / RUA）】
毎日送られてくるXMLレポート
- 送信元IP別の認証結果集計
- SPF/DKIM/DMARCの合否率
- どのIPから送っているか把握できる

【フォレンジックレポート（Forensic Report / RUF）】
個別の認証失敗メールの詳細
- プライバシー上の理由で多くのプロバイダが送ってこない
- GDPRの影響でEUドメインは特に少ない

# DMARCレコードの例（完全版）
"v=DMARC1; p=reject; pct=100; rua=mailto:dmarc@example.com; ruf=mailto:forensic@example.com; sp=reject; adkim=s; aspf=s"

# 各パラメータ
v=DMARC1         バージョン
p=reject         ポリシー（none/quarantine/reject）
pct=100          ポリシー適用割合（段階的移行に使う）
rua=mailto:...   集計レポートの送信先
ruf=mailto:...   フォレンジックレポートの送信先
sp=reject        サブドメインへのポリシー
adkim=s          DKIMアライメント（s=strict, r=relaxed）
aspf=s           SPFアライメント（s=strict, r=relaxed）
```

---

## タスク: 以下のTerraformコードと分析ツールを生成してください

### 生成するファイル一覧

1. `terraform/phase4/main.tf`
2. `terraform/phase4/variables.tf`
3. `terraform/phase4/outputs.tf`
4. `terraform/phase4/terraform.tfvars.example`
5. `scripts/analyze-mail-header.py`
6. `scripts/check-dmarc.sh`
7. `docs/dmarc-migration-guide.md`

---

### main.tf の要件

#### DMARCレコードの更新（段階的強化）
Phase 1で設定した `p=none` のDMARCレコードを `p=quarantine` に更新:

```hcl
resource "aws_route53_record" "dmarc" {
  # DMARCレコードの段階的強化
  # Phase 1: p=none（モニタリングのみ）
  # Phase 4: p=quarantine（疑わしいメールをスパムフォルダへ）
  # 本番移行時: p=reject（拒否）
  #
  # pct=10 から始めて徐々に100に上げる段階移行も可能
  zone_id = var.hosted_zone_id
  name    = "_dmarc.${var.domain_name}"
  type    = "TXT"
  ttl     = 300
  records = [
    "v=DMARC1; p=quarantine; pct=100; rua=mailto:dmarc-reports@${var.domain_name}; ruf=mailto:dmarc-forensic@${var.domain_name}; sp=quarantine; adkim=r; aspf=r"
  ]
}
```

#### SPFレコードの強化
Phase 1の `~all` を `-all` に変更（ソフトフェイル → ハードフェイル）:

```hcl
resource "aws_route53_record" "spf" {
  # SPFポリシーの強化
  # Phase 1: ~all（ソフトフェイル: 受信するが疑わしいとマーク）
  # Phase 4: -all（ハードフェイル: ポリシー外からの送信を拒否）
  # ※ -allに変更する前に全送信経路がSPFに含まれているか確認必須
}
```

#### SES DKIM設定の確認・出力
- Phase 3で設定したDKIM CNAMEが正しく伝播しているか確認
- `aws_sesv2_email_identity` のdataソースで現在の状態を取得
- DKIM状態をoutputで出力

#### DMARCレポート受信用のSESルール
- `dmarc-reports@{domain}` 宛のメールをS3に保存するSES Receipt Rule
- Phase 3のS3バケット（または専用バケット）に保存
- 日本語コメント: DMARCレポートがXML形式で届くことを説明

---

### outputs.tf の要件

| output名 | 説明 |
|---------|------|
| `dmarc_record` | 設定したDMARCレコードの値 |
| `spf_record_updated` | 更新後のSPFレコード（-all） |
| `dkim_status` | SESのDKIM署名ステータス |
| `mail_tester_checklist` | mail-tester.comで確認すべき項目リスト |

---

### scripts/analyze-mail-header.py の要件

```python
#!/usr/bin/env python3
"""
メールヘッダー解析スクリプト

Gmailなどで「メッセージのソースを表示」して取得したヘッダーを
わかりやすく解析・表示する学習ツール。

使用方法:
  # ヘッダーをファイルに保存してから
  python3 scripts/analyze-mail-header.py --file email-header.txt

解析する項目:
1. Received ヘッダーの配送経路（時系列で表示）
2. Authentication-Results（SPF/DKIM/DMARC各結果）
3. DKIM-Signature（セレクタ・署名アルゴリズム）
4. Return-Path vs From の比較
5. X-SES-* ヘッダー（SES固有情報）
6. 各項目に日本語で解説を付与
"""

# 実装内容:
# 1. email.parser でヘッダーをパース
# 2. Receivedヘッダーを逆順（最古→最新）で表示
# 3. Authentication-Resultsを構造化して表示
#    SPF: pass/fail/softfail + ソースIP
#    DKIM: pass/fail + セレクタ + ドメイン
#    DMARC: pass/fail + ポリシー適用結果
# 4. アライメントの合否判定をわかりやすく表示
# 5. 問題点があれば改善提案を日本語で出力
```

---

### scripts/check-dmarc.sh の要件

```bash
#!/bin/bash
# DMARC・DKIM・SPF設定の総合確認スクリプト
# 使用方法: ./scripts/check-dmarc.sh your-domain.com

DOMAIN=$1

# 確認内容:
# 1. SPFレコード確認と解析
#    - v=spf1 が含まれているか
#    - include:amazonses.com があるか
#    - -all または ~all の種類を表示
#
# 2. DKIMレコード確認（SESの3セレクタ）
#    - CNAMEレコードが存在するか
#    - 解決先を表示
#
# 3. DMARCレコード確認と解析
#    - p= の値を表示（none/quarantine/reject）
#    - rua= の送信先を表示
#    - pct= の適用割合を表示
#
# 4. MXレコード確認
#    - SESのインバウンドエンドポイントを向いているか
#
# 5. 総合評価を表示
#    ✅ or ⚠️ or ❌ で各項目の状態を表示
```

---

### docs/dmarc-migration-guide.md の要件

以下の内容を含む移行ガイド:

1. **移行ステップ概要**（表形式）

| ステップ | ポリシー | pct | 期間目安 | 確認内容 |
|---------|---------|-----|---------|---------|
| 0 | p=none | - | 2週間 | レポート収集・送信経路把握 |
| 1 | p=quarantine | pct=10 | 1週間 | 10%にポリシー適用・影響確認 |
| 2 | p=quarantine | pct=100 | 2週間 | 全量に適用・苦情がないか確認 |
| 3 | p=reject | pct=10 | 1週間 | 最終確認 |
| 4 | p=reject | pct=100 | 維持 | 完全保護状態 |

2. **よくある失敗パターンと対処法**
   - メーリングリスト経由でDKIMが壊れる問題
   - 第三者送信サービス（Salesforce, SendGrid等）のSPF追加忘れ
   - サブドメインのSPF未設定

3. **DMARCレポートの読み方**
   - XMLの構造を日本語で解説
   - 問題のある送信元の見つけ方

4. **mail-tester.com での確認手順**
   - テスト用メールアドレスへの送信方法
   - スコア10/10を達成するためのチェックリスト

---

## 生成後の実行手順（コメントとして出力すること）

```bash
# 1. Terraform実行（SPF・DMARCレコードの更新）
cd terraform/phase4
terraform apply -var-file="terraform.tfvars"

# 2. DNS伝播の確認（変更後5〜10分待つ）
./scripts/check-dmarc.sh your-domain.com

# 3. mail-tester.comでテスト
# → https://www.mail-tester.com/ でテスト用アドレスを取得
# → そのアドレスにSES経由でメールを送信
python3 scripts/send-test-mail.py \
  --from sender@your-domain.com \
  --to test-xxxxxx@mail-tester.com

# 4. メールヘッダーを解析
# Gmailで「その他 → メッセージのソースを表示」
# ヘッダーをheader.txtに保存して:
python3 scripts/analyze-mail-header.py --file header.txt

# 5. DMARCレポートを待つ（翌日にdmarc-reports@your-domain.comに届く）
```

## Phase 4完了の確認チェックリスト（コメントとして出力すること）

- [ ] DMARCポリシーが `p=quarantine` になっている
- [ ] SPFが `-all` になっている
- [ ] DKIMのCNAMEが3つとも正しく設定されている
- [ ] mail-tester.comで8点以上（理想は10点）
- [ ] メールヘッダーで Authentication-Results: dmarc=pass を確認
- [ ] DMARCレポートが翌日届く（dmarc-reports@your-domain.com）

## Phase 5への引き継ぎ情報（コメントとして出力すること）

```
Phase 5では:
- CloudWatchでバウンス率・苦情率を継続監視
- VPC Endpointを使ってSES通信をAWSネットワーク内に閉じる
- メール受信時のウイルス・スパムスキャン（Lambda）
- SESサプレッションリストの自動管理
- 本番移行チェックリストの作成
```