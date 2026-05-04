# メールインフラ トラブルシューティングガイド

このガイドでは mail-infra-handson で構築したメールインフラで発生しやすい問題と対処法を解説する。

---

## 1. メールが届かない

### 症状
送信したはずのメールが受信箱に届かない、または送信エラーになる。

### 確認手順

**① Postfixのキューを確認する**

```bash
# EC2にSSHしてキューの滞留を確認
sudo mailq
# または
sudo postqueue -p

# キュー内のメールをすべて再送
sudo postqueue -f

# 特定のキューIDを確認
sudo postcat -vq <QUEUE_ID>
```

**② Postfixのログを確認する**

```bash
# メインログ
sudo tail -f /var/log/maillog
# または Amazon Linux 2023
sudo journalctl -u postfix -f

# 特定の送信先に関するログを絞り込む
sudo grep "recipient@example.com" /var/log/maillog | tail -50
```

**③ SES送信制限を確認する**

```bash
# 送信クォータと現在の送信数を確認
aws sesv2 get-account --region ap-northeast-1 \
  --query '{QuotaMax:SendQuota.Max24HourSend,QuotaUsed:SendQuota.SentLast24Hours,RateMax:SendQuota.MaxSendRate}'

# サンドボックス状態の確認（サンドボックス中は検証済みアドレスにしか送信できない）
aws sesv2 get-account --region ap-northeast-1 --query 'ProductionAccessEnabled'
```

**④ サプレッションリストに入っていないか確認する**

```bash
# SESアカウントレベルのサプレッションリストを確認
aws sesv2 list-suppressed-destinations --region ap-northeast-1

# 特定アドレスの確認
aws sesv2 get-suppressed-destination \
  --email-address recipient@example.com \
  --region ap-northeast-1

# DynamoDBのアプリレベルリストを確認
aws dynamodb get-item \
  --table-name mail-handson-suppression-list \
  --key '{"email":{"S":"recipient@example.com"},"reason":{"S":"bounce"}}' \
  --region ap-northeast-1
```

**⑤ SESのメッセージ送信履歴を確認する**

```bash
# CloudWatch Logsでエラーを確認
aws logs filter-log-events \
  --log-group-name /aws/lambda/mail-handson-bounce-handler \
  --filter-pattern "ERROR" \
  --start-time $(($(date +%s) - 3600))000 \
  --region ap-northeast-1
```

---

## 2. SPAMフォルダに入る

### 症状
メールは届いているが、受信者のSPAMフォルダに分類される。

### 確認手順

**① SPF/DKIM/DMARCの設定を確認する**

```bash
# SPFレコードの確認
dig TXT your-domain.com | grep spf

# DKIMレコードの確認（3つあるはず）
dig CNAME xxxxxx._domainkey.your-domain.com

# DMARCレコードの確認
dig TXT _dmarc.your-domain.com

# SESでの認証状態を確認
aws sesv2 get-email-identity \
  --email-identity your-domain.com \
  --region ap-northeast-1 \
  --query '{DkimStatus:DkimAttributes.Status,VerificationStatus:VerificationStatus}'
```

**② mail-tester.comでスコアを確認する**

1. `https://www.mail-tester.com/` にアクセス
2. 表示された一時アドレスにテストメールを送信
3. 「Check your score」でスコアと改善点を確認
4. **目標スコア: 8/10以上**

**③ バウンス率・苦情率を確認する**

```bash
# CloudWatchでレピュテーションメトリクスを取得
aws cloudwatch get-metric-statistics \
  --namespace AWS/SES \
  --metric-name Reputation.BounceRate \
  --start-time $(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 86400 \
  --statistics Average \
  --region ap-northeast-1
```

**④ 逆引きDNS（PTR）の確認**

```bash
# EC2のパブリックIPの逆引きを確認
# AWSデフォルトのPTRレコード: ec2-x-x-x-x.ap-northeast-1.compute.amazonaws.com
# カスタムPTRが必要な場合はAWSサポートに依頼
dig -x <EC2_PUBLIC_IP>
```

---

## 3. SESのドメイン検証が完了しない

### 症状
`VerificationStatus` が `PENDING` のまま変わらない。

### 確認手順

**① DNS伝播を待機する**

DNS変更の反映には通常5分〜数時間、最大72時間かかることがある。

```bash
# DKIMトークンの確認（Terraformのoutputに出力される）
aws sesv2 get-email-identity \
  --email-identity your-domain.com \
  --region ap-northeast-1 \
  --query 'DkimAttributes.Tokens'

# 各CNAMEが解決できるか確認
for token in token1 token2 token3; do
  echo "=== ${token}._domainkey.your-domain.com ==="
  dig CNAME ${token}._domainkey.your-domain.com
done
```

**② Route 53のNSレコードが正しいか確認する**

```bash
# ドメインのNSレコードを確認
dig NS your-domain.com

# Route 53のホストゾーンに設定されているNSと一致するか確認
aws route53 get-hosted-zone \
  --id YOUR_HOSTED_ZONE_ID \
  --query 'DelegationSet.NameServers'
```

ドメインレジストラ側のNSレコードとRoute 53のNSが一致していない場合、DNSが機能しない。
→ レジストラのコントロールパネルでNSレコードをRoute 53のNSに更新する。

---

## 4. バウンス率が急上昇した

### 症状
CloudWatchアラームが発火し、バウンス率が3%を超えた通知が届く。

### 緊急対応手順

**① まず送信を停止する**

```bash
# Configuration Setの送信を無効化
aws sesv2 put-configuration-set-sending-options \
  --configuration-set-name mail-handson-config-set \
  --sending-enabled \
  --region ap-northeast-1

# ※ sending-enabled フラグを false にして停止
```

**② サプレッションリストを確認する**

```bash
# バウンスが多いアドレスのパターンを確認
aws dynamodb scan \
  --table-name mail-handson-suppression-list \
  --filter-expression "reason = :r" \
  --expression-attribute-values '{":r":{"S":"bounce"}}' \
  --region ap-northeast-1 | jq '.Items[] | .email.S'
```

**③ 送信リストのクリーニング手順**

1. バウンスアドレスをすべてリストから除去する
2. ダブルオプトイン（メール確認）なしのアドレスを除去する
3. 6ヶ月以上未開封のアドレスをリストから除去する
4. スペルミスのアドレス（typo）を修正または除去する

**④ SESサポートへの連絡**

バウンス率が5%を超えてアカウントが停止された場合:

1. AWSコンソール → Support → Create case
2. "Service limit increase" を選択
3. Limit type: "SES Sending Limits"
4. 停止の原因と再発防止策を英語で記載して申請する

---

## 5. VPC EndpointでSES接続できない

### 症状
EC2上のPostfixがSES SMTPに接続できない（タイムアウト・接続拒否）。

### 確認手順

**① VPC Endpointのステータスを確認する**

```bash
aws ec2 describe-vpc-endpoints \
  --filters "Name=service-name,Values=com.amazonaws.ap-northeast-1.email-smtp" \
  --region ap-northeast-1 \
  --query 'VpcEndpoints[*].{Id:VpcEndpointId,State:State,DNS:DnsEntries[0].DnsName}'

# State が "available" であることを確認
```

**② Private DNS有効化の確認**

```bash
aws ec2 describe-vpc-endpoints \
  --filters "Name=service-name,Values=com.amazonaws.ap-northeast-1.email-smtp" \
  --region ap-northeast-1 \
  --query 'VpcEndpoints[*].PrivateDnsEnabled'

# true でない場合はTerraformで private_dns_enabled = true に修正して再適用
```

**③ Security Groupのルール確認**

```bash
# VPC Endpointに設定されたSGのインバウンドルールを確認
aws ec2 describe-security-groups \
  --group-ids <ENDPOINT_SG_ID> \
  --region ap-northeast-1 \
  --query 'SecurityGroups[*].IpPermissions'

# ポート587 (TCP) がEC2のVPC CIDRから許可されているか確認
# 例: 172.31.0.0/16 からの587が許可されていること
```

**④ EC2からSMTP接続テスト**

```bash
# EC2上でSMTP接続テスト（VPC Endpoint経由）
telnet email-smtp.ap-northeast-1.amazonaws.com 587

# 応答例:
# 220 email-smtp.ap-northeast-1.amazonaws.com ESMTP SimpleEmailService
# → 接続成功

# タイムアウトする場合:
# 1. SGの587ポート許可を確認
# 2. EC2のアウトバウンドSGが587を許可しているか確認
# 3. VPC Endpointが同じVPCにあるか確認
```

**⑤ Postfixのリレー設定を確認する**

```bash
# Postfixの設定確認
sudo postconf relayhost
# 期待値: [email-smtp.ap-northeast-1.amazonaws.com]:587

sudo postconf smtp_tls_security_level
# 期待値: encrypt
```
