# 本番移行チェックリスト

mail-infra-handson で構築したメールインフラを本番環境に移行する前の最終確認リスト。
すべての項目にチェックが入ってから `terraform apply` を実施すること。

---

## DNS設定

- [ ] **MXレコード** が正しいSESエンドポイントを向いている
  ```bash
  dig MX your-domain.com
  # 期待値例: 10 inbound-smtp.ap-northeast-1.amazonaws.com
  ```

- [ ] **SPFレコード** に全送信元が含まれ `-all` で締めくくられている
  ```bash
  dig TXT your-domain.com | grep spf
  # 例: "v=spf1 include:amazonses.com -all"
  # ⚠️ ~all（ソフトフェイル）ではなく -all（ハードフェイル）にすること
  ```

- [ ] **DKIMのCNAMEレコード** が3つ設定されている
  ```bash
  # Route 53コンソールで3つのCNAMEが _domainkey サブドメインに存在することを確認
  aws sesv2 get-email-identity \
    --email-identity your-domain.com \
    --region ap-northeast-1 \
    --query 'DkimAttributes.{Status:Status,Tokens:Tokens}'
  # Status: SUCCESS であること
  ```

- [ ] **DMARCポリシー** が `p=reject` になっている
  ```bash
  dig TXT _dmarc.your-domain.com
  # 最終形: "v=DMARC1; p=reject; rua=mailto:dmarc-report@your-domain.com"
  # p=none → p=quarantine → p=reject の段階移行後に確認
  ```

- [ ] **逆引きDNS（PTR）** が設定されている
  ```bash
  dig -x <SMTP_SERVER_IP>
  # EC2使用の場合: AWSサポートに依頼してカスタムPTRを設定する
  ```

---

## SES設定

- [ ] **ドメイン検証** が完了している（VerificationStatus: SUCCESS）
  ```bash
  aws sesv2 get-email-identity \
    --email-identity your-domain.com \
    --region ap-northeast-1 \
    --query 'VerificationStatus'
  ```

- [ ] **Production Access Request** が承認されている（サンドボックス解除）
  ```bash
  aws sesv2 get-account --region ap-northeast-1 \
    --query 'ProductionAccessEnabled'
  # true であること（false = サンドボックス = 検証済みアドレスのみ送信可能）
  ```

- [ ] **Configuration Set** が設定されており、メール送信時に指定している
  ```bash
  aws sesv2 list-configuration-sets --region ap-northeast-1
  # mail-handson-config-set が存在すること
  ```

- [ ] **バウンス・苦情のSNS通知** が設定されている
  ```bash
  aws sesv2 get-configuration-set-event-destinations \
    --configuration-set-name mail-handson-config-set \
    --region ap-northeast-1
  # BOUNCE と COMPLAINT のSNSデスティネーションが存在すること
  ```

---

## セキュリティ

- [ ] **EC2のSecurity Group** がSMTP(587)を必要最小限のIPに制限している
  ```bash
  # 0.0.0.0/0 へのインバウンド587が開いていないことを確認
  aws ec2 describe-security-groups --region ap-northeast-1 \
    --query 'SecurityGroups[?contains(GroupName,`mail-handson`)].IpPermissions'
  ```

- [ ] **VPC Endpoint** が設定されており、SES通信がインターネットに出ない
  ```bash
  aws ec2 describe-vpc-endpoints \
    --filters "Name=service-name,Values=com.amazonaws.ap-northeast-1.email-smtp" \
    --region ap-northeast-1 \
    --query 'VpcEndpoints[*].State'
  # available であること
  ```

- [ ] **Lambda実行ロール** にSES書き込み権限がない（最小権限の原則）
  ```bash
  # spam-handler と suppression-mgr のIAMロールポリシーを確認
  # ses:SendEmail / ses:SendRawEmail が付与されていないこと
  aws iam list-role-policies --role-name mail-handson-spam-handler-role
  ```

- [ ] **S3バケット** がパブリックアクセスブロックされている
  ```bash
  aws s3api get-public-access-block \
    --bucket <INBOUND_MAIL_BUCKET_NAME> \
    --region ap-northeast-1
  # 全項目が true であること
  ```

- [ ] **S3バケット** のサーバーサイド暗号化が有効になっている
  ```bash
  aws s3api get-bucket-encryption \
    --bucket <INBOUND_MAIL_BUCKET_NAME> \
    --region ap-northeast-1
  ```

---

## 監視

- [ ] **バウンス率アラーム** が設定されている（閾値3%）
  ```bash
  aws cloudwatch describe-alarms \
    --alarm-names mail-handson-bounce-rate-high \
    --region ap-northeast-1 \
    --query 'MetricAlarms[*].{Name:AlarmName,State:StateValue,Threshold:Threshold}'
  ```

- [ ] **苦情率アラーム** が設定されている（閾値0.05%）
  ```bash
  aws cloudwatch describe-alarms \
    --alarm-names mail-handson-complaint-rate-high \
    --region ap-northeast-1 \
    --query 'MetricAlarms[*].{Name:AlarmName,State:StateValue,Threshold:Threshold}'
  ```

- [ ] **CloudWatchダッシュボード** が作成されている
  ```bash
  aws cloudwatch list-dashboards --region ap-northeast-1 \
    --query 'DashboardEntries[?contains(DashboardName,`mail-handson`)].DashboardName'
  ```

- [ ] **アラーム通知先（SNS）** が設定されており、メールSubscriptionが確認済み
  ```bash
  aws sns list-subscriptions-by-topic \
    --topic-arn <ALARM_TOPIC_ARN> \
    --region ap-northeast-1 \
    --query 'Subscriptions[*].{Protocol:Protocol,Endpoint:Endpoint,Status:SubscriptionArn}'
  # SubscriptionArn が "PendingConfirmation" でないこと（確認メールをクリック済みであること）
  ```

---

## 運用

- [ ] **サプレッションリストの管理フロー** が確立されている
  - バウンス発生 → DynamoDB → 毎日のLambdaでSES同期
  - 手動追加方法を運用チームに周知している

- [ ] **定期的なメールリストクリーニング** の手順が文書化されている
  - 6ヶ月以上未開封のアドレスを除去する
  - ダブルオプトイン（メール確認）を実装している
  - 購読解除（unsubscribe）リンクを全メールに含めている

- [ ] **インシデント対応手順書** が存在する
  - バウンス率急上昇時の送信停止手順
  - SESアカウント停止時のAWSサポート連絡先
  - エスカレーションフローと担当者

---

## 最終確認コマンド

```bash
# すべての確認を一括実行（ap-northeast-1）

echo "=== SES Account Status ==="
aws sesv2 get-account --region ap-northeast-1 \
  --query '{ProductionAccess:ProductionAccessEnabled,BounceRate:EnforcementStatus}'

echo "=== SES Identity Verification ==="
aws sesv2 list-email-identities --region ap-northeast-1 \
  --query 'EmailIdentities[*].{Identity:IdentityName,Status:VerificationStatus}'

echo "=== CloudWatch Alarms ==="
aws cloudwatch describe-alarms \
  --alarm-name-prefix mail-handson \
  --region ap-northeast-1 \
  --query 'MetricAlarms[*].{Name:AlarmName,State:StateValue}'

echo "=== VPC Endpoints ==="
aws ec2 describe-vpc-endpoints \
  --filters "Name=service-name,Values=com.amazonaws.ap-northeast-1.email-smtp" \
  --region ap-northeast-1 \
  --query 'VpcEndpoints[*].{Id:VpcEndpointId,State:State}'

echo "=== Lambda Functions ==="
aws lambda list-functions --region ap-northeast-1 \
  --query 'Functions[?starts_with(FunctionName,`mail-handson`)].{Name:FunctionName,State:State}'
```
