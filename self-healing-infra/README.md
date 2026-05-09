# 自己修復インフラ ハンズオン

AWS Config + EventBridge + Lambda + Ansible で、Security Group の設定ドリフトを自動検知・自動修復するハンズオンです。

この README は「実際に動かす手順書」として書いています。設計の背景や詳細構成を先に読みたい場合は [ARCHITECTURE.md](/home/takuya/terraform-lab/self-healing-infra/ARCHITECTURE.md) を参照してください。

---

## 1. このハンズオンで何を作るか

このプロジェクトでは、Security Group に誤って `0.0.0.0/0 -> tcp/22` が追加されたときに、次の流れで自動修復する仕組みを作ります。

1. AWS Config が SG の変更を検知する
2. Config Rule が `NON_COMPLIANT` と判定する
3. EventBridge が Lambda を起動する
4. Lambda が不正ルールを削除し、正しいルールだけを再適用する
5. Chatwork に修復完了通知を送る

あわせて、Ansible を使ってローカル PC から同じ修復ポリシーを手動で再適用する方法も確認します。

---

## 2. 先に全体像をつかむ

### 自動修復の流れ

```text
Security Group に不正ルールが追加される
  -> AWS Config が変更を検知
  -> Config Rule が NON_COMPLIANT と判定
  -> EventBridge が Lambda を起動
  -> Lambda が SG を全リセットして正しい SSH ルールだけ再適用
  -> Chatwork に通知
```

### 手動修復の流れ

```text
ローカル PC で ansible-playbook を実行
  -> Ansible が AWS API を直接呼ぶ
  -> SG を全リセットして正しい SSH ルールだけ再適用
  -> Chatwork に通知
```

### このハンズオンで重要な考え方

- Lambda は「自動修復」の経路
- Ansible は「手動確認・手動再適用」の経路
- どちらも「現在の状態を信用せず、一度リセットして正しい状態を書き戻す」方式
- EC2 や SSM は使わない
- Ansible は `hosts: localhost` / `connection: local` でローカル PC 上で動く

---

## 3. ハンズオンのゴール

完了時に次の状態になっていれば成功です。

- Terraform で必要な AWS リソースを作成できる
- Chatwork にテスト通知が届く
- SG に `0.0.0.0/0 -> 22` を追加すると数秒で自動修復される
- CloudWatch Logs に Lambda 実行ログが出る
- Chatwork に自己修復完了通知が届く
- Ansible からも同じ修復を手動実行できる

---

## 4. 所要時間とコスト感

| 項目 | 目安 |
|---|---|
| 所要時間 | 30〜45分 |
| 主な課金源 | AWS Config, Lambda, CloudWatch Logs, S3 |
| コスト感 | 数時間の検証なら小さいが、AWS Config は放置すると課金が続く |

> ハンズオン後は必ず `terraform destroy` を実行してください。

---

## 5. 前提条件

### 5.1 必要な権限

このハンズオンでは少なくとも次を扱える AWS 権限が必要です。

- VPC / Subnet / Security Group 作成
- IAM Role / Policy 作成
- Lambda 作成
- AWS Config 作成
- EventBridge Rule 作成
- S3 Bucket 作成
- CloudWatch Logs 参照

### 5.2 必要なツール

```bash
aws --version
python3 --version
terraform --version
```

Ansible はプロジェクトの venv に入れて使います。

推奨バージョン:

- AWS CLI v2.x
- Python 3.10+
- Terraform 1.6+

### 5.3 リージョン

このプロジェクトは `ap-northeast-1`（東京）前提です。

---

## 6. 事前準備

### 6.1 リポジトリルートに移動

```bash
cd /home/takuya/terraform-lab/self-healing-infra
```

### 6.2 venv を有効化

このプロジェクトでは venv を使います。

```bash
source .venv/bin/activate
```

確認:

```bash
which python
which ansible-playbook
```

期待する状態:

- `python` が `.venv/bin/python` を指す
- `ansible-playbook` が `.venv/bin/ansible-playbook` を指す

### 6.3 AWS 認証を確認

```bash
aws sts get-caller-identity
aws configure get region
```

確認ポイント:

- 呼び出しに成功する
- リージョンが `ap-northeast-1` になっている

リージョンが違う場合は明示的に設定します。

```bash
aws configure set region ap-northeast-1
```

### 6.4 Chatwork の準備

1. Chatwork の API トークンを発行する
2. 通知先ルームの Room ID を確認する

Room ID の確認例:

```text
https://www.chatwork.com/#!rid123456
-> Room ID は 123456
```

### 6.5 環境変数を設定

```bash
export CHATWORK_API_TOKEN="your_api_token_here"
export CHATWORK_ROOM_ID="your_room_id_here"
```

確認:

```bash
echo "$CHATWORK_ROOM_ID"
test -n "$CHATWORK_API_TOKEN" && echo "CHATWORK_API_TOKEN is set"
```

---

## 7. 最短実行ルート

先に全体をざっと流したい場合は、この順番で進めると迷いません。

1. Chatwork テスト通知
2. Terraform `init` / `plan` / `apply`
3. SG ID を取得
4. Config / Lambda / EventBridge の状態確認
5. Ansible dry-run
6. SG に違反ルールを追加
7. 自動修復と通知を確認
8. Ansible 手動修復を確認
9. `terraform destroy`

以下で各手順を詳しく説明します。

---

## 8. 手順 1: Chatwork の疎通確認

最初に通知経路だけ切り出して確認します。ここを先に通しておくと、後で通知が来ないときに AWS 側の問題か Chatwork 側の問題か切り分けやすくなります。

```bash
curl -X POST \
  -H "X-ChatWorkToken: $CHATWORK_API_TOKEN" \
  -d "body=テスト通知: self-healing-infra ハンズオン開始" \
  "https://api.chatwork.com/v2/rooms/$CHATWORK_ROOM_ID/messages"
```

成功の目安:

- `{"message_id":"..."}` のようなレスポンスが返る
- Chatwork の対象ルームにメッセージが届く

失敗した場合の確認:

- API トークンが正しいか
- Room ID が正しいか
- 変数が未設定ではないか

---

## 9. 手順 2: Terraform でインフラを作成

### 9.1 Terraform が作るもの

このプロジェクトの Terraform は大きく 3 つの役割に分かれています。

| ファイル | 役割 |
|---|---|
| `terraform/main.tf` | VPC / Subnet / SG / IAM |
| `terraform/config.tf` | AWS Config / S3 / EventBridge |
| `terraform/lambda.tf` | Lambda パッケージングとデプロイ |

### 9.2 `terraform init`

```bash
cd terraform
terraform init
```

確認ポイント:

- provider の初期化が完了する
- エラーなく `Terraform has been successfully initialized` が出る

### 9.3 `terraform plan`

```bash
terraform plan \
  -var="chatwork_api_token=$CHATWORK_API_TOKEN" \
  -var="chatwork_room_id=$CHATWORK_ROOM_ID"
```

確認ポイント:

- 作成対象に Lambda / Config / EventBridge / SG が含まれている
- 変数未設定エラーが出ていない

### 9.4 `terraform apply`

```bash
terraform apply \
  -var="chatwork_api_token=$CHATWORK_API_TOKEN" \
  -var="chatwork_room_id=$CHATWORK_ROOM_ID" \
  -auto-approve
```

確認ポイント:

- apply が最後まで完了する
- output として `production_sg_id` が取得できる

### 9.5 SG ID を保存

以降の手順で何度も使うため、環境変数に入れておきます。

```bash
SG_ID=$(terraform output -raw production_sg_id)
echo "$SG_ID"
```

期待する形:

```text
sg-xxxxxxxxxxxxxxxxx
```

---

## 10. 手順 3: 作成されたリソースを確認

apply が終わったら、いきなり違反を作る前に「監視と修復の導線」が生きているかを順番に見ます。

### 10.1 Security Group を確認

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query "SecurityGroups[0].IpPermissions" \
  --output table
```

確認ポイント:

- `10.0.0.0/8` からの `tcp/22` だけが入っている

### 10.2 Config Recorder の状態確認

apply 直後は少し待つことがあります。30 秒ほど待ってから確認してください。

```bash
aws configservice describe-configuration-recorder-status \
  --query "ConfigurationRecordersStatus[0].recording"
```

期待値:

```text
true
```

### 10.3 Config Rule の状態確認

```bash
aws configservice describe-compliance-by-config-rule \
  --config-rule-names no-unrestricted-ssh \
  --query "ComplianceByConfigRules[0].Compliance.ComplianceType"
```

期待値:

```text
"COMPLIANT"
```

### 10.4 EventBridge ルールの状態確認

```bash
aws events describe-rule \
  --name config-sg-violation \
  --query "State"
```

期待値:

```text
"ENABLED"
```

### 10.5 Lambda の存在確認

```bash
aws lambda get-function \
  --function-name sg-auto-remediation \
  --query "Configuration.[FunctionName,Runtime,State]" \
  --output table
```

確認ポイント:

- 関数名が `sg-auto-remediation`
- Runtime が `python3.12`
- State が `Active`

---

## 11. 手順 4: Ansible の dry-run を確認

違反を作る前に、手動修復経路も通るか確認します。`--check` を付けると実変更なしで検証できます。

リポジトリルートに戻ります。

```bash
cd ..
ansible-playbook ansible/playbooks/fix_sg.yml \
  -e "sg_id=$SG_ID" \
  --check
```

確認ポイント:

- playbook がエラーなく完了する
- AWS 認証エラーが出ない
- `amazon.aws` コレクション関連エラーが出ない

補足:

- `changed` が表示されても `--check` 中は実際には変更されません
- ここで失敗する場合は後の手動修復でも失敗するので、先に直しておくのがおすすめです

---

## 12. 手順 5: 自動修復を実際に発火させる

ここがハンズオンのメインです。ターミナルを 2 つ用意すると観察しやすくなります。

### 12.1 ターミナル A: Lambda ログ監視

```bash
aws logs tail /aws/lambda/sg-auto-remediation \
  --follow \
  --format short
```

### 12.2 ターミナル B: 違反ルールを追加

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0
```

成功すると、数秒後にターミナル A のログと Chatwork の通知が動き始めます。

### 12.3 期待される時系列

| 時間の目安 | 起きること |
|---|---|
| 0 秒 | SG に違反ルールが追加される |
| 数秒 | AWS Config が変更を検知する |
| 数秒 | Config Rule が `NON_COMPLIANT` になる |
| 数秒 | EventBridge が Lambda を起動する |
| 数秒 | Lambda が全インバウンドルールを削除して正しいルールを再適用する |
| 数秒 | Chatwork に自己修復完了通知が届く |

### 12.4 Lambda ログで見るポイント

ログでは次のような流れが見えれば OK です。

- 受信したイベントが表示される
- `resourceId` と `configRuleName` がログに出る
- 既存ルール削除のログが出る
- 準拠ルール再適用のログが出る
- Chatwork 通知成功のログが出る

---

## 13. 手順 6: 自動修復の結果を確認

### 13.1 SG の最終状態を確認

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query "SecurityGroups[0].IpPermissions" \
  --output table
```

確認ポイント:

- `0.0.0.0/0` が消えている
- `10.0.0.0/8 -> tcp/22` だけが残っている

### 13.2 Config Rule が戻っているか確認

```bash
aws configservice get-compliance-details-by-config-rule \
  --config-rule-name no-unrestricted-ssh \
  --query "EvaluationResults[0].ComplianceType"
```

期待値:

```text
"COMPLIANT"
```

### 13.3 Chatwork 通知を確認

通知文面の要点:

- 自己修復完了
- 対象 SG ID
- `0.0.0.0/0 -> port 22` を削除したこと

---

## 14. 手順 7: Ansible で手動修復を試す

今度は Ansible から同じ修復を手動で実行します。

### 14.1 再度違反を作る

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0
```

### 14.2 すぐに Ansible を実行

```bash
ansible-playbook ansible/playbooks/fix_sg.yml \
  -e "sg_id=$SG_ID"
```

確認ポイント:

- playbook が成功終了する
- Chatwork に通知が届く
- 最終的な SG 状態が自動修復時と同じになる

### 14.3 なぜ Lambda と競合しても大丈夫か

Lambda も Ansible も、どちらも同じポリシーで「全削除して正しい状態だけ再適用」を行います。つまり途中で同時実行に近い状態になっても、最終状態は同じです。

これがこのハンズオンで学ぶ冪等性のポイントです。

---

## 15. 手順 8: 後片付け

AWS Config は放置すると課金が継続するため、検証が終わったら必ず削除します。

```bash
cd terraform
terraform destroy \
  -var="chatwork_api_token=$CHATWORK_API_TOKEN" \
  -var="chatwork_room_id=$CHATWORK_ROOM_ID" \
  -auto-approve
```

削除確認:

```bash
aws configservice describe-configuration-recorder-status
```

期待する状態:

- Recorder が見つからない、または削除済みであることを確認できる

---

## 16. つまずきやすいポイント

### `terraform plan` / `apply` が変数未設定で失敗する

確認:

```bash
echo "$CHATWORK_API_TOKEN"
echo "$CHATWORK_ROOM_ID"
```

### Config Recorder が `false` のまま

数十秒待って再確認してください。

```bash
aws configservice describe-delivery-channels
aws configservice describe-configuration-recorder-status
```

### EventBridge ルールが無効

```bash
aws events describe-rule --name config-sg-violation --query "State"
```

### Lambda が起動しない

```bash
aws lambda get-policy --function-name sg-auto-remediation
aws logs tail /aws/lambda/sg-auto-remediation --format short
```

### Lambda が SG を修復できない

```bash
aws iam list-role-policies --role-name sg-remediation-lambda-role
```

必要なら手動で Lambda を呼びます。

```bash
aws lambda invoke \
  --function-name sg-auto-remediation \
  --cli-binary-format raw-in-base64-out \
  --payload "{\"detail\":{\"resourceId\":\"$SG_ID\",\"configRuleName\":\"no-unrestricted-ssh\"}}" \
  /tmp/lambda-response.json

cat /tmp/lambda-response.json
```

### Ansible が失敗する

```bash
which ansible-playbook
python -c "import boto3; print(boto3.__version__)"
aws sts get-caller-identity
ansible-playbook ansible/playbooks/fix_sg.yml -e "sg_id=$SG_ID" --check -vvv
```

### Chatwork に通知が届かない

```bash
curl -X POST \
  -H "X-ChatWorkToken: $CHATWORK_API_TOKEN" \
  -d "body=疎通テスト" \
  "https://api.chatwork.com/v2/rooms/$CHATWORK_ROOM_ID/messages"
```

---

## 17. ここまでで学べること

- AWS Config を使ったドリフト検知
- EventBridge による違反イベントのルーティング
- Lambda でのイベント駆動型修復
- Ansible の `connection: local` による AWS API 操作
- 差分修正ではなく desired state の再適用で整合性を保つ考え方

---

## 18. 次の発展課題

| 課題 | 内容 |
|---|---|
| 修復履歴の永続化 | DynamoDB に修復履歴を書き、回数や頻度を可視化する |
| 監視ルールの追加 | RDP や HTTP など他ポートも対象にする |
| 通知強化 | Chatwork だけでなく SNS / Slack / PagerDuty などにも広げる |
| 再発時エスカレーション | 同一 SG の違反が短時間に続いたら人間承認フローに切り替える |
| マルチアカウント展開 | Organizations 配下に共通ガードレールとして配布する |

---

## 19. 関連ドキュメント

- [ARCHITECTURE.md](/home/takuya/terraform-lab/self-healing-infra/ARCHITECTURE.md): 設計と責務分担の詳細
- [terraform/main.tf](/home/takuya/terraform-lab/self-healing-infra/terraform/main.tf): ネットワーク / SG / IAM
- [terraform/config.tf](/home/takuya/terraform-lab/self-healing-infra/terraform/config.tf): Config / S3 / EventBridge
- [terraform/lambda.tf](/home/takuya/terraform-lab/self-healing-infra/terraform/lambda.tf): Lambda デプロイ
- [lambda/handler.py](/home/takuya/terraform-lab/self-healing-infra/lambda/handler.py): 自動修復ロジック
- [ansible/playbooks/fix_sg.yml](/home/takuya/terraform-lab/self-healing-infra/ansible/playbooks/fix_sg.yml): 手動修復 playbook
