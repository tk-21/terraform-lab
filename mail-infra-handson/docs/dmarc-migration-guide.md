# DMARC移行ガイド

なりすましメール対策を段階的に強化するための実践ガイドです。
急激なポリシー変更は正規メールの誤拒否リスクがあるため、段階移行を強く推奨します。

---

## 移行ステップ概要

| ステップ | ポリシー | pct | 期間目安 | 確認内容 |
|---------|---------|-----|---------|---------|
| 0 | `p=none` | -（適用なし） | 2週間以上 | レポート収集・送信経路をすべて把握する |
| 1 | `p=quarantine` | `pct=10` | 1週間 | 10%にポリシー適用・影響なしを確認 |
| 2 | `p=quarantine` | `pct=100` | 2週間 | 全量に適用・苦情・配送失敗がないか確認 |
| 3 | `p=reject` | `pct=10` | 1週間 | 最終確認・誤拒否がないか確認 |
| 4 | `p=reject` | `pct=100` | 維持 | 完全保護状態 |

> **Terraform変数での管理**: `dmarc_policy` と `dmarc_pct` 変数を変更して `terraform apply` するだけで段階移行できます。

---

## よくある失敗パターンと対処法

### 1. メーリングリスト経由でDKIMが壊れる

**症状**: メーリングリストを経由したメールで `dkim=fail` になる。

**原因**: メーリングリストサーバーがメール本文にフッターを追加すると、DKIMで署名した本文ハッシュが一致しなくなる。

**対処法**:
- DMARCアライメントを `adkim=r`（relaxed）に設定する（Phase 4のデフォルト）
- relaxedモードではDKIMが失敗してもSPFが通れば DMARC Pass になる
- メーリングリストが多い環境では `p=quarantine` から始めて影響範囲を確認する

```
# DNSで確認（relaxedアライメント）
v=DMARC1; p=quarantine; adkim=r; aspf=r; ...
```

### 2. 第三者送信サービスのSPF追加忘れ

**症状**: Salesforce・Marketo・SendGrid等から送ったメールで `spf=fail` になる。

**原因**: SPFレコードに第三者サービスの `include:` が不足している。

**対処法**:
```
# よく使われるサービスのSPF include
v=spf1 include:amazonses.com
       include:salesforce.com        # Salesforce
       include:sendgrid.net          # SendGrid
       include:_spf.google.com       # Google Workspace
       include:spf.protection.outlook.com  # Microsoft 365
       -all
```

> **注意**: SPFは1回のDNSルックアップで最大10回しかMXやincludeを展開できません（10ルックアップ制限）。超えると `permerror` になります。

### 3. サブドメインのSPF未設定

**症状**: `mail.example.com` や `news.example.com` からの送信でSPF失敗する。

**原因**: SPFレコードはサブドメインに自動継承されません。

**対処法**:
```
# サブドメインごとに個別設定が必要
mail.example.com  TXT  "v=spf1 include:amazonses.com -all"
news.example.com  TXT  "v=spf1 include:sendgrid.net -all"
```

または DMARCの `sp=` パラメータで一括制御:
```
_dmarc.example.com  TXT  "v=DMARC1; p=reject; sp=reject; ..."
# sp=reject: サブドメインからのなりすましも拒否
```

### 4. `-all` への変更で正規メールが拒否される

**症状**: SPFを `~all` から `-all` に変えたら一部メールが届かなくなった。

**原因**: 全送信経路がSPFに含まれていなかった。

**対処法**:
1. `p=none` の期間に届いたDMARCレポートのXMLを解析
2. `<source_ip>` に載っているIPがすべてSPFレコードに含まれているか確認
3. 漏れたIPのサービスを `include:` に追加してから `-all` に変更

---

## DMARCレポートの読み方

DMARCレポートは毎日XML形式でメールに添付されて届きます（`rua=` で指定したアドレスへ）。

### XMLの構造

```xml
<?xml version="1.0" encoding="UTF-8"?>
<feedback>
  <!-- レポート送信者の情報 -->
  <report_metadata>
    <org_name>Google Inc.</org_name>
    <email>noreply-dmarc-support@google.com</email>
    <date_range>
      <begin>1704067200</begin>  <!-- 集計期間（UNIXタイムスタンプ） -->
      <end>1704153599</end>
    </date_range>
  </report_metadata>

  <!-- 自分のDMARCレコードの内容 -->
  <policy_published>
    <domain>example.com</domain>
    <p>quarantine</p>    <!-- 適用したポリシー -->
    <pct>100</pct>
  </policy_published>

  <!-- 送信元IP別の集計データ -->
  <record>
    <row>
      <source_ip>199.255.192.1</source_ip>   <!-- SESのIPアドレス -->
      <count>42</count>                        <!-- この期間に送ったメール数 -->
      <policy_evaluated>
        <disposition>none</disposition>        <!-- 実際の処理（none=通過） -->
        <dkim>pass</dkim>                      <!-- DKIMアライメント結果 -->
        <spf>pass</spf>                        <!-- SPFアライメント結果 -->
      </policy_evaluated>
    </row>
    <auth_results>
      <dkim>
        <domain>example.com</domain>
        <result>pass</result>
        <selector>selector1</selector>
      </dkim>
      <spf>
        <domain>example.com</domain>
        <result>pass</result>
      </spf>
    </auth_results>
  </record>
</feedback>
```

### 問題のある送信元の見つけ方

1. **`<disposition>` が `quarantine` または `reject` のレコードを探す**
   → DMARCポリシーが実際に適用された証拠

2. **`<dkim>fail` または `<spf>fail` のレコードを探す**
   → `<source_ip>` を確認してどのサービスが失敗しているか特定

3. **見慣れないIPアドレスのレコードを探す**
   → なりすましの可能性。whois で確認する

```bash
# DMARCレポートXMLの簡易解析（S3から取得した場合）
# レポートはgzip圧縮されていることが多い
gunzip < dmarc-report.xml.gz | python3 -c "
import sys, xml.etree.ElementTree as ET
tree = ET.parse(sys.stdin)
for record in tree.findall('.//record'):
    ip = record.findtext('.//source_ip')
    count = record.findtext('.//count')
    dkim = record.findtext('.//policy_evaluated/dkim')
    spf = record.findtext('.//policy_evaluated/spf')
    disp = record.findtext('.//policy_evaluated/disposition')
    status = '✅' if dkim == 'pass' or spf == 'pass' else '❌'
    print(f'{status} IP: {ip:20s} count: {count:5s} dkim: {dkim:5s} spf: {spf:5s} disposition: {disp}')
"
```

---

## mail-tester.com での確認手順

### ステップ 1: テスト用アドレスの取得

1. [mail-tester.com](https://www.mail-tester.com/) にアクセス
2. 表示されたワンタイムアドレス（例: `test-abc123@mail-tester.com`）をコピー

### ステップ 2: SES経由でテストメールを送信

```bash
# Phase 3で作成した送信スクリプトを使用
python3 scripts/send-test-mail.py \
  --from sender@your-domain.com \
  --to test-abc123@mail-tester.com \
  --subject "DMARC Test $(date +%Y%m%d)" \
  --body "このメールはDMARC設定テスト用です。"
```

### ステップ 3: スコアと詳細を確認

mail-tester.comのサイトに戻り「Check your score」をクリックします。

### スコア10/10を達成するためのチェックリスト

| 項目 | 確認内容 | 対処法 |
|------|---------|--------|
| SPF | `spf=pass` になっている | `include:amazonses.com -all` を確認 |
| DKIM | `dkim=pass` になっている | SES DKIMステータスが SUCCESS か確認 |
| DMARC | `dmarc=pass` になっている | `p=quarantine` 以上・アライメント確認 |
| PTR | 逆引きDNSが設定されている | SES使用時は自動設定済み（対応不要） |
| HTML/TEXT | テキストパートが含まれる | HTMLのみでなくテキストパートも付与 |
| List-Unsubscribe | 購読解除ヘッダーがある | マーケティングメールには必須 |
| スパムワード | 件名・本文に含まれていない | 大文字多用・感嘆符連続を避ける |
| リンク | ブラックリストのURLがない | 短縮URLや不審なドメインを避ける |
| HTMLバランス | テキスト対比でHTMLが多すぎない | 画像だけのメールを避ける |
| エンコーディング | 文字化けがない | UTF-8を使用 |

---

## 移行タイムライン例

```
Week 1-2:  p=none でレポート収集
           → DMARCレポートのIPリストと送信経路が一致するか確認

Week 3:    p=quarantine; pct=10 に変更 (terraform apply)
           → mail-tester.com でスコアを計測

Week 4:    p=quarantine; pct=100 に変更
           → 1週間様子を見て苦情がないか確認

Week 5:    p=reject; pct=10 に変更

Week 6:    p=reject; pct=100 に変更（完全保護）
```

> **本番環境での注意点**: ECサイトや金融系など重要なメールを扱うドメインは、
> 各ステップを最低2週間維持し、DMARCレポートで問題がないことを確認してから次へ進むこと。
