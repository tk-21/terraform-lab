# ✅Phase 5: セキュリティ強化 × 運用監視
# 「本番運用できるレベルのセキュリティと可視化を実装する」
#
# 実行方法: claude < phases/phase5.md
# 所要時間: 3〜4時間
# 前提: Phase 1〜4完了済み

## このフェーズのゴール

1. CloudWatchでSESメトリクスを可視化し、バウンス率・苦情率をアラート監視する
2. VPC Endpointを使ってSES通信をAWSネットワーク内に閉じる
3. メール受信時にLambdaでスパム判定ロジックを実装する
4. SESサプレッションリストを自動管理する仕組みを作る
5. 本番移行チェックリストを完成させる

---

## 理論解説（実装前に必ず読むこと）

### SESのアカウント停止リスクと監視の重要性

```
SESアカウントが停止される条件:
- バウンス率 > 5%（Hard Bounce）
- 苦情率 > 0.1%

【なぜ監視が重要か】
バウンス率が急上昇する典型的な原因:
1. 古い・未検証のメールリストを使った
2. タイポのアドレスを大量送信
3. メールアドレスハーベスティングの被害
4. 存在しないサブドメインへの送信

SESの「アカウントレベルのサプレッションリスト」:
- Hard Bounce / 苦情が発生したアドレスは自動的にサプレッションリスト入り
- 以降、そのアドレスへの送信は自動ブロック
- アカウントレベル（全送信ドメインに影響）

【対応策】
1. CloudWatchアラームで早期検知
2. DynamoDBにアプリレベルのサプレッションリストを維持（Phase 3で実装済み）
3. 定期的なリストクリーニング（ダブルオプトイン等）
```

### VPC Endpoint（PrivateLink）の仕組み

```
【通常のSES SMTP接続】
EC2 → インターネットゲートウェイ → (インターネット) → SESエンドポイント

【VPC Endpoint使用時】
EC2 → VPC Endpoint（Interface型）→ AWSプライベートネットワーク → SES

メリット:
- EC2にElastic IPやNATゲートウェイが不要になる（コスト削減）
- 通信がインターネットに出ない（セキュリティ強化）
- SG/エンドポイントポリシーで詳細なアクセス制御が可能

SESのVPC Endpoint（SMTP用）:
com.amazonaws.ap-northeast-1.email-smtp
→ ポート587でPostfixから直接接続可能
```

### メール受信時のスパム判定パターン

```
SES Receipt Rules で実装できるスパム判定:

1. SES組み込みスパム/ウイルスフィルタ
   enable_spam_scan = true
   enable_virus_scan = true
   → スパム/ウイルスを検出したらメールをドロップ

2. Lambda で独自判定ロジック
   受信メール → Lambda → 判定
   - 特定送信元IPのブロック
   - キーワードフィルタ
   - 添付ファイルサイズ制限
   - ヘッダー整合性チェック

3. S3 + 非同期処理
   受信メールをS3に保存
   → S3イベント → Lambda で非同期処理
   → 判定結果をDynamoDBに記録
```

---

## タスク: 以下のTerraformコードとLambdaを生成してください

### 生成するファイル一覧

1. `terraform/phase5/main.tf`
2. `terraform/phase5/variables.tf`
3. `terraform/phase5/outputs.tf`
4. `terraform/phase5/terraform.tfvars.example`
5. `terraform/phase5/lambda/spam_handler.py`
6. `terraform/phase5/lambda/suppression_manager.py`
7. `docs/troubleshooting.md`
8. `docs/production-checklist.md`

---

### main.tf の要件

#### CloudWatch ダッシュボード
名前: `mail-handson-dashboard`

ウィジェット構成（日本語ラベルで）:
- SES送信数（Send）: 直近24時間
- バウンス数・バウンス率: 直近7日間
- 苦情数・苦情率: 直近7日間
- Lambda実行回数・エラー数（bounce_handler）
- DynamoDBのサプレッションリスト件数

#### CloudWatch アラーム（バウンス率）
```hcl
resource "aws_cloudwatch_metric_alarm" "ses_bounce_rate" {
  alarm_name          = "mail-handson-bounce-rate-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  # SESのバウンス率メトリクス
  # メトリクス: AWS/SES の Reputation.BounceRate
  # 閾値: 0.03（3%。SESの停止基準5%より手前で検知）
  threshold = 0.03
  # アラーム時: SNSに通知
}
```

#### CloudWatch アラーム（苦情率）
```hcl
resource "aws_cloudwatch_metric_alarm" "ses_complaint_rate" {
  # メトリクス: AWS/SES の Reputation.ComplaintRate
  # 閾値: 0.0005（0.05%。SESの停止基準0.1%より手前で検知）
  threshold = 0.0005
}
```

#### SNS Topic（アラーム通知用）
- トピック名: `mail-handson-alarm-topic`
- メール通知: 管理者メールアドレスへSubscription
  （メールアドレスはvariablesから取得）

#### VPC Endpoint（SES SMTP用）
```hcl
resource "aws_vpc_endpoint" "ses_smtp" {
  # SES SMTPのVPC Endpoint
  # Interface型エンドポイント（PrivateLink）
  # サービス名: com.amazonaws.{region}.email-smtp
  #
  # このエンドポイントを使うことで:
  # 1. EC2からSESへの通信がインターネットに出ない
  # 2. NATゲートウェイが不要になる
  # 3. エンドポイントポリシーで送信元を制限できる
  vpc_id            = data.aws_vpc.default.id
  service_name      = "com.amazonaws.${var.aws_region}.email-smtp"
  vpc_endpoint_type = "Interface"
  # Private DNS: 有効化でPostfixの設定変更不要
  private_dns_enabled = true
}
```

#### VPC Endpoint Policy
- EC2のIAMロールからのみSES SendRawEmailを許可
- それ以外を拒否

#### Lambda（スパムハンドラー）
- 関数名: `mail-handson-spam-handler`（64文字以内）
- ランタイム: Python 3.12
- アーキテクチャ: arm64
- SES Receipt RuleのLambdaアクションとして設定
- トリガー: SES Receipt Rule（メール受信時）

#### Lambda（サプレッション管理）
- 関数名: `mail-handson-suppression-mgr`（64文字以内）
- ランタイム: Python 3.12
- アーキテクチャ: arm64
- EventBridgeスケジュール: 毎日AM2時（JST）に実行
- 役割: DynamoDBのサプレッションリストと
  SESアカウントレベルのサプレッションリストを同期

#### SES Receipt Rule（スパムフィルタ付き）
Phase 3のReceipt Ruleを更新:
```hcl
resource "aws_ses_receipt_rule" "with_spam_check" {
  # スパム・ウイルスチェックを有効化
  # スキャン後にLambdaで追加判定
  # 最終的にS3に保存
  scan_enabled = true  # SES組み込みスパム/ウイルスチェック
  # アクション順序:
  # 1. Lambda（独自スパム判定）
  # 2. S3（メール保存）
}
```

---

### lambda/spam_handler.py の要件

```python
"""
メール受信時スパム判定Lambda

SES Receipt RuleのLambdaアクションとして呼び出される。
受信メールを解析してスパム判定を行い、
結果をDynamoDBに記録してS3への保存アクションの
続行/停止を決定する。

判定ロジック:
1. SESのspamVerdict/virusVerdictを確認（SES組み込みチェック結果）
2. Authentication-Resultsを確認（SPF/DKIM/DMARC）
   → DMARCがfailのメールは疑わしいとマーク
3. 送信元IPのブロックリスト確認（DynamoDBから）
4. 件名・本文のキーワードチェック（S3から本文を取得）
5. 判定結果をDynamoDBに記録

戻り値:
- {"disposition": "CONTINUE"} → 次のアクションへ
- {"disposition": "STOP_RULE"} → このルールの残りアクションをスキップ
"""

# 実装すること:
# 1. SESイベントの構造をパース
# 2. spamVerdict/virusVerdictの確認
# 3. DMARCアライメントの確認
# 4. 判定結果のDynamoDB記録（mail-handson-spam-log テーブル）
# 5. Lambda Powertoolsで構造化ログ
# 6. メトリクスをCloudWatchへPush（スパム判定数）
```

---

### lambda/suppression_manager.py の要件

```python
"""
サプレッションリスト同期Lambda

DynamoDB（アプリレベル）のサプレッションリストと
SESアカウントレベルのサプレッションリストを同期する。

処理フロー:
1. DynamoDBから全サプレッションリストを取得
2. SESのアカウントレベルサプレッションリストを取得
3. DynamoDBにあってSESにないものをSESに追加
4. TTL切れのアドレスをDynamoDBから削除
5. 統計情報をCloudWatchへPush

boto3 SES APIの使用:
- ses.list_suppressed_destinations()
- ses.put_suppressed_destination()
- ses.delete_suppressed_destination()
"""
```

---

### docs/troubleshooting.md の要件

以下のトラブルシューティングケースを日本語で解説:

1. **メールが届かない**
   - キューを確認（mailq）
   - ログを確認（/var/log/maillog）
   - SES送信制限の確認
   - サプレッションリストに入っていないか確認

2. **SPAMフォルダに入る**
   - SPF/DKIM/DMARCの設定確認
   - バウンス率・苦情率の確認
   - 逆引きDNS（PTR）の確認
   - mail-tester.comでスコア確認

3. **SESのドメイン検証が完了しない**
   - DNS伝播の待機（最大72時間）
   - digコマンドで確認
   - Route 53のNSレコードが正しいか

4. **バウンス率が急上昇した**
   - サプレッションリストの確認
   - 送信リストのクリーニング手順
   - SESサポートへの連絡方法

5. **VPC EndpointでSES接続できない**
   - エンドポイントのステータス確認
   - Private DNS有効化の確認
   - Security Groupのルール確認

---

### docs/production-checklist.md の要件

本番移行前の最終チェックリスト:

**DNS設定**
- [ ] MXレコードが正しいSESエンドポイントを向いている
- [ ] SPFレコードに全送信元が含まれている（`-all`）
- [ ] DKIMのCNAMEが3つ設定されている
- [ ] DMARCが `p=reject` になっている
- [ ] 逆引きDNS（PTR）が設定されている

**SES設定**
- [ ] ドメイン検証が完了している
- [ ] Production Access Requestが承認されている（サンドボックス解除）
- [ ] Configuration Setが設定されている
- [ ] バウンス・苦情のSNS通知が設定されている

**セキュリティ**
- [ ] EC2のSecurity GroupがMTP(25)を必要最小限のIPに制限
- [ ] VPC Endpointが設定されている
- [ ] Lambda実行ロールにSES書き込み権限がない（最小権限）
- [ ] S3バケットがパブリックアクセスブロックされている

**監視**
- [ ] バウンス率アラームが設定されている（閾値3%）
- [ ] 苦情率アラームが設定されている（閾値0.05%）
- [ ] CloudWatchダッシュボードが作成されている
- [ ] アラーム通知先（SNS）が設定されている

**運用**
- [ ] サプレッションリストの管理フロー
- [ ] 定期的なメールリストクリーニング手順
- [ ] インシデント対応手順書

---

## 生成後の実行手順（コメントとして出力すること）

```bash
# 1. Terraform実行
cd terraform/phase5
terraform apply -var-file="terraform.tfvars"

# 2. CloudWatchダッシュボードの確認
# AWSコンソール → CloudWatch → ダッシュボード → mail-handson-dashboard

# 3. アラームのテスト（SESのシミュレーターを使用）
# bounce@simulator.amazonses.com にメールを送信
# → バウンスイベントが発生 → SNS → Lambda → DynamoDB

# 4. VPC Endpointの確認
aws ec2 describe-vpc-endpoints \
  --filters "Name=service-name,Values=com.amazonaws.ap-northeast-1.email-smtp" \
  --region ap-northeast-1

# 5. サプレッション管理Lambdaの手動実行
aws lambda invoke \
  --function-name mail-handson-suppression-mgr \
  --region ap-northeast-1 \
  output.json
cat output.json

# 6. 本番チェックリストの確認
cat docs/production-checklist.md
```

## 全フェーズ完了の総合チェックリスト（コメントとして出力すること）

**Phase 1 ✅**
- [ ] Route 53ホストゾーン・MXレコード・SPFレコード・DMARCレコード設定済み

**Phase 2 ✅**
- [ ] PostfixがEC2上で動作
- [ ] telnetでSMTP手打ちテスト完了

**Phase 3 ✅**
- [ ] SESドメイン検証完了
- [ ] メール送受信の実動作確認
- [ ] バウンス・苦情パイプライン動作確認

**Phase 4 ✅**
- [ ] DKIM CNAMEレコード3つ設定済み
- [ ] DMARC p=quarantine に移行済み
- [ ] mail-tester.com スコア8点以上

**Phase 5 ✅**
- [ ] CloudWatchダッシュボード・アラーム設定済み
- [ ] VPC Endpoint設定済み
- [ ] スパムハンドラーLambda動作確認
- [ ] 本番移行チェックリスト確認済み

## ハンズオン完了後の次のステップ

```
1. ドメインを使い続ける場合:
   - EC2は削除（Phase 2: terraform destroy）
   - SES + Route 53のみ維持（月額$2程度）

2. ポートフォリオとして公開:
   - GitHubにpush
   - Zennに解説記事を書く（プロトコル理論 + 実装を組み合わせた記事は希少）

3. 次の発展テーマ:
   - SES + WorkMail でフルマネージドなメールサーバー
   - Amazon SES Dedicated IP でIPレピュテーション管理
   - メールテンプレート管理（SES Templates API）
   - Bedrockでスパム判定をAI化（ルールベース → ML）
```