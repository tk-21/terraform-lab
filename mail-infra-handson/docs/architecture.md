# アーキテクチャ解説

mail-infra-handson で構築するメールインフラの全体像と、各フェーズで追加されるコンポーネントを解説する。

---

## 全体アーキテクチャ図

```
【送信フロー】

  アプリケーション
       │
       ▼
  EC2 (Postfix)
       │ SMTP:587（VPC Endpoint経由 / Phase 5）
       ▼
  VPC Endpoint ───► AWS SES ───► 受信者メールサーバー
                       │
                       │ Configuration Set
                       ▼
                  CloudWatch Metrics
                  （Reputation.BounceRate / ComplaintRate）
                       │
                       ▼
                  CloudWatch Alarm ───► SNS Topic ───► 管理者メール

【受信フロー】

  送信者メールサーバー
       │ SMTP
       ▼
  AWS SES (Receipt Rules)
       │
       ├─ [1] with-spam-check ルール（Phase 5）
       │       │
       │       ├─ Lambda: spam_handler
       │       │     ├─ SES組み込みスパム/ウイルス判定
       │       │     ├─ DMARC検証
       │       │     └─ サプレッションリスト確認
       │       │         │
       │       │    SPAM │ CLEAN
       │       │         │
       │  STOP_RULE_SET  │ CONTINUE
       │       │         ▼
       │       │    S3 (inbound-scanned/)
       │       │    DynamoDB: spam-log
       │
       └─ [store-to-s3 は Phase 5 適用後に無効化]

【バウンス・苦情パイプライン】

  AWS SES
       │ イベント通知
       ▼
  SNS (bounce-topic / complaint-topic)
       │
       ▼
  Lambda: bounce_handler
       │
       ▼
  DynamoDB: suppression-list
       │
       │ 毎日AM2時（JST）
       ▼
  Lambda: suppression_manager
       │
       ├─ DynamoDB → SES アカウントレベルサプレッションリスト同期
       └─ TTL切れアドレスの削除
```

---

## フェーズ別コンポーネント

### Phase 1: DNS基盤構築

| リソース | 説明 |
|---|---|
| Route 53 Hosted Zone | ドメインのDNS管理ゾーン |
| MXレコード | メール受信先を SES エンドポイントに向ける |
| SPFレコード（TXT） | 送信元IPを `include:amazonses.com -all` で定義 |
| DMARCレコード（TXT） | `p=none` から段階的に `p=reject` へ移行 |

**なぜ必要か**: DNSはメールシステムの根幹。MXがなければ受信できず、SPF/DMARCがなければスパム判定される。

---

### Phase 2: MTA構築（Postfix on EC2）

| リソース | 説明 |
|---|---|
| EC2 (t4g.micro) | Postfix が動作するメールサーバー |
| Security Group | 送信: 587(SMTP-TLS)のみ開放、SSH: 管理用 |
| IAM Role | EC2 が SES に対してメール送信できる権限 |
| user_data.sh | Postfix インストール・SES中継設定を自動化 |

**なぜ必要か**: SES の SMTP エンドポイントを実際に叩くことで、SMTPプロトコルを手を動かして理解する。

```
【Postfix の中継設定】
relayhost = [email-smtp.ap-northeast-1.amazonaws.com]:587
smtp_tls_security_level = encrypt
smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
```

---

### Phase 3: AWS SES本格構成

| リソース | 説明 |
|---|---|
| SES Email Identity | ドメイン全体の送信権限を取得 |
| DKIM CNAME × 3 | Easy DKIM: SES が秘密鍵を管理して自動署名 |
| S3 Bucket | 受信メールを EML 形式で保存 |
| SNS Topic × 2 | バウンス・苦情イベントを Fan-out で配信 |
| DynamoDB | アプリレベルのサプレッションリスト |
| Lambda: bounce_handler | バウンス・苦情を DynamoDB に記録 |
| SES Configuration Set | メトリクス収集・TLS強制・イベント通知を設定 |
| SES Receipt Rule Set | 受信ルールのコンテナ |

**なぜ必要か**: SES の送受信・バウンス管理・メトリクス収集を一括で設定し、フルマネージドなメール基盤を作る。

---

### Phase 4: DKIM/DMARC完全実装

| リソース | 説明 |
|---|---|
| SPFレコード更新 | `~all` → `-all`（ハードフェイル）へ強化 |
| DMARC更新 | `p=none` → `p=quarantine` → `p=reject` へ段階移行 |
| SES DMARC Policy | `REJECT` ポリシーでなりすまし送信をブロック |
| SES Receipt Rule 更新 | DKIM 署名付きメール受信の確認 |

**なぜ必要か**: DKIM + SPF + DMARC の3つが揃って初めて「なりすまし対策」が完成する。`p=reject` により自ドメインを騙るメールを受信側で拒否させる。

```
【メール認証の連携】

送信者: sender@your-domain.com
           │
           ▼ DKIM署名（SESが自動付与）
  受信MTAが検証:
    SPF:  IPアドレスが include:amazonses.com に含まれるか → PASS
    DKIM: 署名が._domainkey.your-domain.comの公開鍵と一致するか → PASS
    DMARC: SPF/DKIMがPASSかつFromドメインと一致するか → PASS
           → p=reject のため FAIL時は受信拒否
```

---

### Phase 5: セキュリティ強化 × 運用監視

| リソース | 説明 |
|---|---|
| CloudWatch Dashboard | バウンス率・苦情率・Lambda実行数を一覧表示 |
| CloudWatch Alarm × 2 | バウンス率3%超・苦情率0.05%超でSNS通知 |
| SNS Topic（アラーム用）| 管理者メールへのアラーム通知 |
| VPC Endpoint（Interface型） | EC2→SES通信をプライベートネットワークに閉じる |
| Lambda: spam_handler | 受信メールのスパム判定（Lambda Receipt Action）|
| Lambda: suppression_mgr | DynamoDB⇔SESサプレッションリストの日次同期 |
| EventBridge Schedule | 毎日AM2時に suppression_mgr を自動実行 |
| DynamoDB: spam-log | スパム判定ログ（30日TTL）|

**なぜ必要か**: SES はバウンス率5%・苦情率0.1% を超えるとアカウントを自動停止する。早期検知と自動対処なしには本番運用は不可能。

---

## コスト構造

```
Phase 1のみ稼働:
  Route 53 Hosted Zone: $0.50/月
  Route 53 クエリ:      $0.40/月（100万クエリ）
  合計: ~$1/月

Phase 1〜3稼働:
  + EC2 t4g.micro:    $6.13/月（On-Demand）
  + SES 送信:          $0.10/1000通
  + S3（受信保存）:    $0.025/GB
  + Lambda:            ほぼ無料（100万リクエスト/月まで無料枠）
  + DynamoDB:          無料枠内
  合計: ~$8/月

Phase 5追加後:
  + CloudWatch Dashboard: $3/月
  + VPC Endpoint:          $0.01/時間 = $7.3/月
  + EventBridge:           ほぼ無料
  合計: ~$18/月

⚠️ 学習完了後は EC2 と VPC Endpoint を削除してコストを削減すること
   EC2 + VPC Endpoint だけで月 ~$14 かかる
```

---

## セキュリティ設計の原則

### 最小権限の徹底

| Lambda | 付与した権限 | 付与していない権限 |
|---|---|---|
| bounce_handler | DynamoDB PutItem/GetItem/UpdateItem | SES送信・S3読み書き |
| spam_handler | DynamoDB PutItem・CloudWatch PutMetricData | SES送信・IAM操作 |
| suppression_mgr | DynamoDB Scan/Delete・SES List/Put/Delete | SES送信・S3操作 |

### 通信経路の保護

```
【VPC Endpoint導入前後の比較】

Before:
EC2 → NAT Gateway → Internet Gateway → (インターネット) → SES
コスト: NAT Gateway $0.045/時間 + データ転送料
セキュリティ: 通信がインターネットを経由する

After (Phase 5):
EC2 → VPC Endpoint → AWSプライベートネットワーク → SES
コスト: VPC Endpoint $0.01/時間（NATより安価）
セキュリティ: 通信がAWSネットワーク内に閉じる
```

### データ保護

- S3バケット: パブリックアクセス全面ブロック + AES-256 サーバーサイド暗号化
- SNS Topic: AWS管理KMSキー（`alias/aws/sns`）で暗号化
- DynamoDB: TTL による自動データ削除（ハードバウンスは永続、ソフトバウンスは30日）
