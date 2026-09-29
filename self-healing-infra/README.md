# 自己修復インフラ ハンズオン

Security Group に `0.0.0.0/0 -> tcp/22` の穴が開けられたら、20 秒前後で自動修復してメールで知らせる仕組みを作ります。

設計の背景は [ARCHITECTURE.md](ARCHITECTURE.md) にあります。この README は「上から順に実行するだけ」の手順書です。

- 所要時間: 30〜45 分
- 課金: AWS Config は放置すると課金が続きます。**最後に必ず Step 9 で片付けてください**

---

## 何が起きる仕組みか

```text
SG に不正ルールが追加される
  -> AWS Config が検知 -> Config Rule が NON_COMPLIANT と判定
  -> EventBridge が Lambda を起動
  -> Lambda が SG を全リセットして正しい SSH ルール (10.0.0.0/8) だけ再適用
  -> SNS 経由でメール通知
```

Ansible は自動修復には関わりません。手元の PC から同じ修復を手動で実行するための補助です。

---

## 進め方の全体像

| Step | やること | 実行場所 |
|---|---|---|
| 0 | 準備（ツール・AWS 認証・メールアドレス） | ルート |
| 1 | Terraform でインフラ作成 | `terraform/` |
| 2 | 購読確認メールを承認 | メールソフト |
| 3 | 動作確認（リソースが生きているか） | どこでも |
| 4 | Ansible dry-run | ルート |
| 5 | 違反を作って自動修復を見る | ルート |
| 6 | 修復結果を確認 | ルート |
| 7 | Ansible で手動修復 | ルート |
| 8 | 困ったとき | - |
| 9 | 後片付け | `terraform/` |

> 以降、コマンドは断りがなければ **プロジェクトルート** (`self-healing-infra/`) で実行します。

---

## Step 0. 準備

### 0-1. ルートに移動して venv を有効化

```bash
cd /home/takuya/terraform-lab/self-healing-infra
source .venv/bin/activate
which ansible-playbook   # .venv/bin/ansible-playbook が出れば OK
```

### 0-2. AWS 認証とリージョンを確認

```bash
aws sts get-caller-identity   # 成功すれば OK
aws configure get region      # ap-northeast-1 であること
```

違う場合: `aws configure set region ap-northeast-1`

### 0-3. Ansible のコレクションを入れる

Ansible の手動修復（Step 4・7）で使います。

```bash
ansible-galaxy collection install amazon.aws community.aws
```

### 0-4. 通知先メールアドレスを環境変数に入れる

```bash
export NOTIFICATION_EMAIL="you@example.com"
echo "$NOTIFICATION_EMAIL"
```

> ターミナルを開き直すと消えます。開き直したら再度 export してください。

**必要な AWS 権限:** VPC / SG / IAM / Lambda / Config / EventBridge / S3 / SNS の作成、CloudWatch Logs の参照

---

## Step 1. Terraform でインフラを作る

```bash
cd terraform
terraform init
terraform plan  -var="notification_email=$NOTIFICATION_EMAIL"
terraform apply -var="notification_email=$NOTIFICATION_EMAIL"
```

`apply` は `yes` と入力すると実行されます。

作られるもの:

| ファイル | 内容 |
|---|---|
| `main.tf` | VPC / Subnet / SG / IAM / SNS |
| `config.tf` | AWS Config / S3 / EventBridge |
| `lambda.tf` | Lambda |

完了したら SG ID を変数に保存し、ルートへ戻ります。

```bash
SG_ID=$(terraform output -raw production_sg_id)
echo "$SG_ID"   # sg-xxxxxxxxxxxxxxxxx
cd ..
```

> `SG_ID` は以降ずっと使います。ターミナルを開き直したら、この 2 行（`cd terraform` から）をやり直してください。

---

## Step 2. 購読確認メールを承認する（重要）

SNS のメール通知は、**承認するまで 1 通も届きません**。

1. `NOTIFICATION_EMAIL` 宛てに「AWS Notification - Subscription Confirmation」が届く（迷惑メールも確認）
2. メール内の **Confirm subscription** をクリックする

確認:

```bash
aws sns list-subscriptions-by-topic \
  --topic-arn "$(aws sns list-topics --query "Topics[?contains(TopicArn,'sg-remediation-notify')].TopicArn" --output text)" \
  --query "Subscriptions[0].SubscriptionArn"
```

`PendingConfirmation` ではなく ARN が表示されれば OK です。

> **会社のメールの場合:** メールセキュリティ製品がリンクを自動で開き、購読が勝手に解除される（「Your subscription ... has been deactivated」が届く）ことがあります。その場合は個人の Gmail など、リンクスキャンのないアドレスに変えてください。

---

## Step 3. リソースが生きているか確認する

違反を作る前に、監視と修復の経路を順に確認します。

| 確認対象 | コマンド | 期待値 |
|---|---|---|
| SG のルール | `aws ec2 describe-security-groups --group-ids "$SG_ID" --query "SecurityGroups[0].IpPermissions" --output table` | `10.0.0.0/8` の `tcp/22` だけ |
| Config Recorder | `aws configservice describe-configuration-recorder-status --query "ConfigurationRecordersStatus[0].recording"` | `true` |
| Config Rule | `aws configservice describe-compliance-by-config-rule --config-rule-names no-unrestricted-ssh --query "ComplianceByConfigRules[0].Compliance.ComplianceType"` | `"COMPLIANT"` |
| EventBridge | `aws events describe-rule --name config-sg-violation --query "State"` | `"ENABLED"` |
| Lambda | `aws lambda get-function --function-name sg-auto-remediation --query "Configuration.[FunctionName,Runtime,State]" --output table` | `python3.12` / `Active` |

> Config Recorder が `false` の場合は、30 秒ほど待って再実行してください。

---

## Step 4. Ansible の dry-run

手動修復の経路が通るかを、実変更なしで確認します。

```bash
ansible-playbook ansible/playbooks/fix_sg.yml -e "sg_id=$SG_ID" --check
```

エラーなく終われば OK です（`changed` と出ても `--check` 中は変更されません）。ここで失敗する場合は Step 7 でも失敗するので、先に直してください。

---

## Step 5. 自動修復を発火させる

ここがメインです。**ターミナルを 2 つ**開きます。ターミナル B では `SG_ID` の再設定が必要です（Step 1 参照）。

**ターミナル A: Lambda のログを監視**

```bash
aws logs tail /aws/lambda/sg-auto-remediation --follow --format short
```

**ターミナル B: 違反ルールを追加**

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0
```

20 秒前後（Config の評価待ちが大半）で、次のことが起きます。

- ターミナル A に Lambda のログが流れる
- 修復完了メールが届く

ログで見るポイント:

- `NON_COMPLIANT: no-unrestricted-ssh → sg-...`
- `Revoked all inbound rules from sg-...`
- `Applied compliant rules to sg-...`
- `Email notified via SNS: ...`

> ログが出ない場合は Step 8 を見てください。確認が終わったらターミナル A は `Ctrl+C` で止めます。

---

## Step 6. 修復結果を確認する

```bash
# 0.0.0.0/0 が消え、10.0.0.0/8 の tcp/22 だけ残っていること
aws ec2 describe-security-groups --group-ids "$SG_ID" \
  --query "SecurityGroups[0].IpPermissions" --output table

# "COMPLIANT" に戻っていること（反映に少し時間がかかることがあります）
aws configservice get-compliance-details-by-config-rule \
  --config-rule-name no-unrestricted-ssh \
  --query "EvaluationResults[0].ComplianceType"
```

メールには「対象 SG ID」と「`0.0.0.0/0 → port 22` を削除したこと」が書かれています。

---

## Step 7. Ansible で手動修復する

もう一度違反を作り、今度は Ansible で直します。

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0

ansible-playbook ansible/playbooks/fix_sg.yml -e "sg_id=$SG_ID"
```

確認ポイント:

- playbook が成功終了する
- メールが届く
- SG の状態が Step 6 と同じになる

> Lambda と同時に動いても最終状態は同じです。どちらも「全削除して正しい状態を書き戻す」ためです（冪等性）。

---

## Step 8. 困ったとき

| 症状 | 確認すること |
|---|---|
| 変数エラーで plan / apply が失敗 | `echo "$NOTIFICATION_EMAIL"` が空でないか |
| Config Recorder が `false` | 30 秒待つ。`aws configservice describe-delivery-channels` も確認 |
| Lambda が起動しない | `aws events describe-rule --name config-sg-violation --query "State"` と `aws lambda get-policy --function-name sg-auto-remediation` |
| Lambda が SG を直せない | `aws iam list-role-policies --role-name sg-remediation-lambda-role` |
| メールが届かない | Step 2 の購読が `PendingConfirmation` のままではないか / 迷惑メール / Lambda ログに `Email notified via SNS` があるか |
| Ansible が失敗する | Step 0-3 のコレクション導入、`aws sts get-caller-identity`、`ansible-playbook ... --check -vvv` |
| Ansible で `botocore and boto3` が無いと言われる | venv が有効か（`which ansible-playbook` が `.venv/bin/` を指すか）。`source .venv/bin/activate` してやり直す |
| 購読解除メール（deactivated）が届く | 会社メールのリンクスキャンが原因。個人アドレスに変えて `terraform apply -replace=aws_sns_topic_subscription.email -var="notification_email=$NOTIFICATION_EMAIL"` |
| `logs tail` が「log group does not exist」 | Terraform で作成済みのはず。`terraform apply` が完了しているか確認 |

Lambda を手動で呼んで切り分ける場合:

```bash
aws lambda invoke \
  --function-name sg-auto-remediation \
  --cli-binary-format raw-in-base64-out \
  --payload "{\"detail\":{\"resourceId\":\"$SG_ID\",\"configRuleName\":\"no-unrestricted-ssh\"}}" \
  /tmp/lambda-response.json && cat /tmp/lambda-response.json
```

---

## Step 9. 後片付け（必須）

```bash
cd terraform
terraform destroy -var="notification_email=$NOTIFICATION_EMAIL"
```

`yes` で実行します。削除後の確認:

```bash
aws configservice describe-configuration-recorder-status
```

Recorder が見つからない、または空であれば完了です。

---

## 仕組みを知りたいとき

なぜ自動で直るのか、Ansible はなぜ同じことができるのかは、[HOW_IT_WORKS.md](HOW_IT_WORKS.md) で解説しています。動かし終えた後に読むのがおすすめです。

---

## 学べること

- AWS Config によるドリフト検知と、EventBridge によるイベントのルーティング
- Lambda によるイベント駆動の自動修復
- 差分修正ではなく、正しい状態を再適用して整合性を保つ考え方
- Ansible の `connection: local` による AWS API 操作

## 発展課題

| 課題 | 内容 |
|---|---|
| 修復履歴の永続化 | DynamoDB に履歴を書き、頻度を可視化する |
| 監視ルールの追加 | RDP や HTTP など他ポートも対象にする |
| 通知先の追加 | SNS の購読先に Slack / PagerDuty / Chatwork を足す |
| 再発時エスカレーション | 短時間に繰り返す違反は人間承認フローにする |
| マルチアカウント展開 | Organizations 配下の共通ガードレールにする |

## 関連ファイル

- [HOW_IT_WORKS.md](HOW_IT_WORKS.md): 仕組みの解説（なぜ動くのか）
- [ARCHITECTURE.md](ARCHITECTURE.md): 設計と責務分担
- [terraform/main.tf](terraform/main.tf) / [terraform/config.tf](terraform/config.tf) / [terraform/lambda.tf](terraform/lambda.tf)
- [lambda/handler.py](lambda/handler.py): 自動修復ロジック
- [ansible/playbooks/fix_sg.yml](ansible/playbooks/fix_sg.yml): 手動修復 playbook
