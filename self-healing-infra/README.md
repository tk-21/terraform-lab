# 自己修復インフラ ハンズオン

AWS Config + Lambda + Ansible で構築する、設定ドリフト自動検知・修復システム

---

## このハンズオンの目的

### 何を作るか

セキュリティグループ（SG）に「誰かが誤って `0.0.0.0/0 → port 22` の穴を開けた」という状況を自動で検知し、**10秒以内に自動修復して Chatwork に通知する**システムを作る。

### なぜ作るか

インフラエンジニアの仕事は「正しい状態を作る」だけでなく、**「正しい状態を維持し続ける」** ことでもある。手動での設定変更・オペレーションミス・外部からの侵害など、インフラは常に「あるべき状態」からズレるリスクを抱えている。このズレを「設定ドリフト」と呼ぶ。

多くのチームはドリフトを **定期監査（週次・月次）** で発見するか、インシデントが起きてから気づく。このハンズオンでは、ドリフトを **数秒で自動検知・修復する自律的なループ** を実装する。

### 現場で使われる場面

- 本番環境の SG に誤ったルールが追加されたとき
- 開発者が「一時的に」開けたポートを閉め忘れたとき
- 外部からの不正アクセスで SG が書き換えられたとき
- コンプライアンス要件として「不正なポート開放は即時修復」が求められるとき

### 学べること

| カテゴリ | 内容 |
|---|---|
| AWS Config | リソース変更の常時監視・マネージドルールの使い方・NON_COMPLIANT イベントの仕組み |
| EventBridge | Config イベントのフィルタリング・Lambda へのルーティング |
| Lambda | イベント駆動の自動修復・boto3 による SG 操作 |
| Ansible | 冪等性（Idempotency）の実践・purge_rules による状態強制上書き |
| Terraform | IAM ロール設計・複数サービスの依存関係管理 |
| 設計思想 | Infrastructure as Code の「あるべき状態」宣言・SRE の Toil 削減パターン |

---

## Ansible はどこで動くのか（重要）

ここを誤解すると全体像が把握できなくなるため、最初に整理する。

### 2 つの実行モデル

```
【一般的な使い方】ローカルPC から対象サーバーに SSH して操作する

  ローカルPC（Ansible がある）
      │ SSH
      ▼
  対象サーバー（nginx の設定を変える、など）
```

```
【このハンズオンの使い方】SSH せず、Ansible 自身が AWS API を直接呼ぶ

  ローカルPC（Ansible がある）
      │ SSH しない。自分自身が処理する
      ▼
  AWS API（boto3 経由で SG を操作する）
```

後者を実現するのが `hosts: localhost` / `connection: local` の組み合わせだ。
EC2 も SSM も登場しない。ローカルPC が直接 AWS と通信する。

### Lambda と Ansible の役割の違い

どちらも SG を修復できるが、用途が異なる。

| | Lambda | Ansible |
|---|---|---|
| 実行場所 | AWS 上（サーバーレス） | ローカルPC |
| トリガー | Config 違反イベント（自動） | 手動 |
| 用途 | 本番の自動修復・常時待機 | 手動確認・検証・強制再適用 |

---

## アーキテクチャ

```
【自動修復ループ】

  Security Group に不正ルールが追加される
      │
      ▼
  AWS Config が変更を検知（数秒以内）
      │
      ▼
  Config Rule: INCOMING_SSH_DISABLED が NON_COMPLIANT と判定
      │
      ▼
  EventBridge がパターンマッチして Lambda を起動
      │
      ▼
  Lambda（handler.py）が boto3 で SG を直接修復
      ├──▶ Security Group（0.0.0.0/0 のルールを削除、内部 CIDR のみ残す）
      └──▶ Chatwork（修復完了通知）


【手動での確認・再適用】

  ローカルPC
      │ ansible-playbook fix_sg.yml -e "sg_id=sg-xxx"
      ▼
  Ansible（connection: local で実行）
      │ boto3 → AWS API
      ├──▶ Security Group（purge_rules: true で全リセット → 正しいルール適用）
      └──▶ Chatwork（通知）
```

---

## 前提条件

### 必要なツール

```bash
aws --version        # AWS CLI v2.x
python3 --version    # Python 3.10+
ansible --version    # Ansible 2.15+
terraform --version  # Terraform 1.6+
```

### インストール（未導入の場合）

```bash
# Ansible + AWS コレクション
pip install ansible boto3 botocore
ansible-galaxy collection install amazon.aws

# Terraform（macOS）
brew tap hashicorp/tap && brew install hashicorp/tap/terraform

# Terraform（Linux）
sudo apt-get install -y gnupg software-properties-common
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform
```

### AWS 認証

```bash
aws configure
# AWS Access Key ID: <your key>
# AWS Secret Access Key: <your secret>
# Default region name: ap-northeast-1

# 確認
aws sts get-caller-identity
```

### Chatwork の準備

1. Chatwork にログイン → 右上のアイコン → **「サービス連携」** → **「APIトークン」** を発行
2. 通知先ルームの URL を確認する
   例: `https://www.chatwork.com/#!rid123456` → Room ID は `123456`

### 環境変数を設定する

```bash
export CHATWORK_API_TOKEN="your_api_token_here"
export CHATWORK_ROOM_ID="your_room_id_here"
```

---

## 手順

### Step 1: Chatwork の疎通確認

構築を始める前に、Chatwork への通知が機能するか確認しておく。
後でトラブルが起きたとき、通知側の問題か AWS 側の問題かを切り分けやすくなる。

```bash
curl -X POST \
  -H "X-ChatWorkToken: $CHATWORK_API_TOKEN" \
  -d "body=テスト通知：self-healing-infra ハンズオン開始" \
  "https://api.chatwork.com/v2/rooms/$CHATWORK_ROOM_ID/messages"
```

**確認:** Chatwork のルームにメッセージが届いたら OK。
`{"message_id":"..."}` が返ってくれば API トークンと Room ID は正しい。

---

### Step 2: インフラ構築（Terraform）

Terraform が作るリソースは以下の 3 カテゴリだ。

**`main.tf`** — 監視対象のインフラ
- VPC と private サブネット（SG の置き場）
- 本番 SG（`production-sg`）: SSH を `10.0.0.0/8`（内部）のみ許可した「あるべき状態」で作成
- Lambda 用 IAM ロール（SG の読み取り・修正権限のみ）
- Config 用 IAM ロール

**`config.tf`** — 監視・検知の仕組み
- AWS Config Recorder: SG の変更を常時記録する
- Config Rule `no-unrestricted-ssh`: SSH が `0.0.0.0/0` に開放されていたら NON_COMPLIANT と判定
- EventBridge ルール: NON_COMPLIANT イベントを受け取ったら Lambda を起動する

**`lambda.tf`** — 自動修復の本体
- Lambda 関数 `sg-auto-remediation` を `lambda/handler.py` からデプロイする

```bash
cd terraform
terraform init
terraform plan \
  -var="chatwork_api_token=$CHATWORK_API_TOKEN" \
  -var="chatwork_room_id=$CHATWORK_ROOM_ID"
```

plan の結果に問題がなければ apply する。

```bash
terraform apply \
  -var="chatwork_api_token=$CHATWORK_API_TOKEN" \
  -var="chatwork_room_id=$CHATWORK_ROOM_ID" \
  -auto-approve
```

**確認:** apply 完了後に SG ID を取得して保存する。

```bash
SG_ID=$(terraform output -raw production_sg_id)
echo "SG ID: $SG_ID"
```

> **コスト注意:** AWS Config は課金される。推定 $1〜3/日（ap-northeast-1）。ハンズオン後は必ず `terraform destroy` を実行すること。

---

### Step 3: Config が動いていることを確認する

apply 直後は Config Recorder が起動中の場合がある。30秒ほど待ってから確認する。

```bash
# Config Recorder が記録中か確認
aws configservice describe-configuration-recorder-status \
  --query "ConfigurationRecordersStatus[0].recording"
# → true が返ればOK
```

```bash
# Config Rule の状態確認（まだ違反がなければ COMPLIANT）
aws configservice describe-compliance-by-config-rule \
  --config-rule-names no-unrestricted-ssh \
  --query "ComplianceByConfigRules[0].Compliance.ComplianceType"
# → "COMPLIANT"
```

**`true` / `COMPLIANT` が返れば次に進める。**
`false` が返った場合はトラブルシューティングの「Config Recorder が記録していない」を参照。

---

### Step 4: Ansible の動作確認（dry-run）

実際に SG を変更する前に、Ansible が正しく動くか dry-run で確認する。
`--check` をつけると「実際には何も変更しない」モードで実行される。

```bash
cd ..  # リポジトリルートに戻る
ansible-playbook ansible/playbooks/fix_sg.yml \
  -e "sg_id=$SG_ID" \
  --check
```

**確認:** エラーなく完了すれば OK。`changed` が出ても `--check` 中は実際には変更されていない。
boto3 のエラーが出る場合はトラブルシューティングの「Ansible が動かない」を参照。

---

### Step 5: 自己修復を体験する

ここからがハンズオンのメインだ。
意図的に SG に違反ルールを追加し、自動修復が動くのを観察する。

**ターミナルを 2 つ開いて並べておくと見やすい。**

**ターミナル A（Lambda のログを監視）:**

```bash
aws logs tail /aws/lambda/sg-auto-remediation \
  --follow \
  --format short
```

**ターミナル B（違反を作成する）:**

```bash
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0

echo "違反ルールを追加しました。Lambda のログを確認してください..."
```

#### 期待される動作の流れ

| 経過時間 | 何が起きているか |
|---|---|
| 0秒 | SG 変更 → AWS Config が検知 |
| 約 2秒 | Config Rule が NON_COMPLIANT と判定 |
| 約 3秒 | EventBridge が Lambda を起動 |
| 約 8秒 | Lambda が SG の全ルールをリセット → 正しいルールを適用 |
| 約 10秒 | Chatwork に修復完了通知が届く |

#### 修復結果の確認

```bash
# SG のルール一覧（0.0.0.0/0 が消えて 10.0.0.0/8 だけ残っているはず）
aws ec2 describe-security-groups \
  --group-ids $SG_ID \
  --query "SecurityGroups[0].IpPermissions" \
  --output table
```

```bash
# Config Rule が COMPLIANT に戻っているか
aws configservice get-compliance-details-by-config-rule \
  --config-rule-name no-unrestricted-ssh \
  --query "EvaluationResults[0].ComplianceType"
# → "COMPLIANT"
```

---

### Step 6: Ansible で手動修復を試す

Lambda の自動修復とは別に、Ansible から手動で同じ修復をやってみる。
「自動修復が動いていない環境で、ローカルから強制的に直す」という運用ユースケースだ。

まず再度違反ルールを追加する（Lambda が修復してしまうため、素早く次のコマンドを実行する）。

```bash
# 違反を作成
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0

# Ansible で修復（実際に変更が走る）
ansible-playbook ansible/playbooks/fix_sg.yml -e "sg_id=$SG_ID"
```

> Lambda と Ansible が競合しても問題ない。どちらも「全リセット → 正しいルール適用」という同じ操作をするため、どちらが先に動いても最終的な状態は同じになる（冪等性）。

**確認ポイント:** `purge_rules: true` がミソ。現在の状態を読まずに「全リセットしてから正しいルールを書く」ことで、ルールが何個積み重なっていても確実に正しい状態に戻せる。

---

## トラブルシューティング

### Config Recorder が記録していない（recording: false）

```bash
# Delivery Channel が存在するか確認
aws configservice describe-delivery-channels

# Recorder Status を確認
aws configservice describe-configuration-recorder-status
```

Delivery Channel がない場合は `config.tf` の `depends_on` が正しいか確認し、`terraform apply` を再実行する。

### Lambda が起動しない

```bash
# EventBridge ルールが有効か
aws events describe-rule --name config-sg-violation --query "State"
# → "ENABLED"

# Lambda に EventBridge からの実行権限があるか
aws lambda get-policy --function-name sg-auto-remediation
```

### Lambda が SG を修復できない

```bash
# IAM ポリシーを確認
aws iam list-role-policies --role-name sg-remediation-lambda-role

# Lambda を手動でテスト実行して直接エラーを確認する
aws lambda invoke \
  --function-name sg-auto-remediation \
  --payload "$(echo "{\"detail\":{\"resourceId\":\"$SG_ID\",\"configRuleName\":\"no-unrestricted-ssh\"}}" | base64 -w 0)" \
  /tmp/lambda-response.json

cat /tmp/lambda-response.json
```

### Ansible が動かない

```bash
# boto3 が入っているか
python3 -c "import boto3; print(boto3.__version__)"

# AWS 認証が通っているか
aws sts get-caller-identity

# 詳細ログで実行
ansible-playbook ansible/playbooks/fix_sg.yml -e "sg_id=$SG_ID" --check -vvv
```

### Chatwork に通知が届かない

```bash
# API トークンと Room ID を直接テスト
curl -X POST \
  -H "X-ChatWorkToken: $CHATWORK_API_TOKEN" \
  -d "body=疎通テスト" \
  "https://api.chatwork.com/v2/rooms/$CHATWORK_ROOM_ID/messages"
# {"message_id":"..."} が返れば Token / Room ID は正しい
```

Lambda から届かない場合は CloudWatch Logs でエラーを確認する。

```bash
aws logs tail /aws/lambda/sg-auto-remediation --format short
```

---

## クリーンアップ

**ハンズオン後は必ず実行すること（AWS Config は放置すると課金が続く）**

```bash
cd terraform
terraform destroy \
  -var="chatwork_api_token=$CHATWORK_API_TOKEN" \
  -var="chatwork_room_id=$CHATWORK_ROOM_ID" \
  -auto-approve
```

destroy 後に確認する。

```bash
aws configservice describe-configuration-recorder-status 2>&1
# NoSuchConfigurationRecorderException が返れば削除完了
```

---

## 発展課題

このハンズオンで動くものができたら、次のステップとして検討できる拡張を挙げる。

| 課題 | 難易度 | 内容 |
|---|---|---|
| 修復履歴の記録 | 低 | DynamoDB に修復ログを書き込む。「いつ・どの SG が・何回修復されたか」を可視化する |
| 複数ルールへの対応 | 中 | SSH だけでなく、RDP（3389）・HTTP（80）なども監視対象に追加する |
| エスカレーション | 中 | 同じ SG が 3 回以上修復されたら、自動修復を止めて人間にアラートを上げる |
| マルチアカウント展開 | 高 | AWS Organizations + CloudFormation StackSets で全アカウントに横展開する |
| Lambda → SSM → EC2上の Ansible | 高 | より複雑なサーバー内の設定修復（ファイル・OS 設定など）に対応するパターン |
