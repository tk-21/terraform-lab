# self-healing-infra

## プロジェクト概要

AWS Config + Lambda + Ansible で、セキュリティグループの設定ドリフトを自動検知・修復するシステムを構築するハンズオン。

**ゴール:** SG に `0.0.0.0/0 → port 22` の穴が開けられたら、10秒以内に Lambda が自動修復して Chatwork に通知する仕組みを動かす。

**Ansible の役割:** 自動修復の本体は Lambda（boto3 直接）。Ansible はローカルPC から手動確認・強制再適用するときに使う。EC2・SSM は登場しない。

## アーキテクチャ

```
SG（不正ルール追加）
  → AWS Config（変更検知）
  → Config Rule: INCOMING_SSH_DISABLED（NON_COMPLIANT 判定）
  → EventBridge（Lambda 起動）
  → Lambda / handler.py（boto3 で SG を直接修復）
  → Chatwork（修復完了通知）

Ansible（ローカルPC から手動実行・検証用）
  → connection: local（SSH しない）
  → boto3 → AWS API → SG 修復
  → Chatwork 通知
```

## ディレクトリ構成

```
self-healing-infra/
├── CLAUDE.md
├── terraform/
│   ├── main.tf       # VPC, SG, IAM ロール（EC2 は含まない）
│   ├── config.tf     # AWS Config Recorder + Config Rules + EventBridge
│   └── lambda.tf     # Lambda 関数デプロイ
├── ansible/
│   ├── ansible.cfg   # connection: local 前提の設定
│   └── playbooks/
│       └── fix_sg.yml  # SG 修復 Playbook（ローカルPC から手動実行）
├── lambda/
│   └── handler.py    # 自動修復 Lambda（boto3 で SG を直接操作）
└── README.md
```

## 技術スタック・バージョン

| ツール | バージョン | 用途 |
|---|---|---|
| Python | 3.12 | Lambda ランタイム |
| Ansible | 2.15+ | SG 修復 Playbook（手動確認用） |
| Terraform | 1.6+ | インフラ構築 |
| AWS CLI | v2 | AWS 操作・確認 |
| boto3 | latest | Lambda から AWS API 操作 |

## AWS 設定

- **リージョン**: ap-northeast-1（東京）固定
- **Lambda アーキテクチャ**: arm64
- **Lambda ランタイム**: python3.12
- **許可する SSH CIDR**: `10.0.0.0/8`（内部 VPC のみ）
- **通知**: Chatwork API（Slack は使わない）
- **環境変数**:
  - `CHATWORK_API_TOKEN`: Chatwork API トークン
  - `CHATWORK_ROOM_ID`: 通知先ルーム ID

## コーディング規約

### Python（Lambda）
- 型ヒントを使う（`def remediate_sg(sg_id: str) -> None:`）
- 関数を `lambda_handler` / `remediate_sg` / `notify_chatwork` に分離する
- `urllib.request` を使う（外部ライブラリ追加なし）
- ログは `logger.info` / `logger.error` で統一

### Terraform
- `variable` には `sensitive = true` を適切に設定する
- `output` には `production_sg_id` のみ出力する
- Lambda IAM ポリシーは最小権限（`ec2:DescribeSecurityGroups` / `ec2:AuthorizeSecurityGroupIngress` / `ec2:RevokeSecurityGroupIngress` のみ）

### Ansible Playbook
- `hosts: localhost` / `connection: local` を必ず指定する
- `purge_rules: true` で全ルールをリセットしてから正しいルールを適用する（冪等性）
- `region: ap-northeast-1` を各タスクに明示する

## 重要な設計判断

| 項目 | 採用 | 理由 |
|---|---|---|
| 修復の実装 | Lambda + boto3 直接 | シンプル・EC2 不要・コスト低 |
| Ansible の用途 | 手動確認・再適用のみ | 自動修復には使わない |
| SSM / EC2 | 使わない | この構成では不要 |
| Config 記録対象 | SG のみ | コスト削減（全リソース記録しない） |
| Chatwork 通知 | urllib.request で直接 POST | 外部ライブラリ不要 |

## よく使うコマンド

```bash
# Terraform デプロイ
cd terraform
terraform init
terraform plan  -var="chatwork_api_token=$CHATWORK_API_TOKEN" -var="chatwork_room_id=$CHATWORK_ROOM_ID"
terraform apply -var="chatwork_api_token=$CHATWORK_API_TOKEN" -var="chatwork_room_id=$CHATWORK_ROOM_ID" -auto-approve

# SG ID 取得
SG_ID=$(terraform output -raw production_sg_id)

# 意図的に違反を作成（自己修復テスト用）
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0

# Lambda ログをリアルタイム監視
aws logs tail /aws/lambda/sg-auto-remediation --follow --format short

# SG のルール確認（修復後に 0.0.0.0/0 が消えているか）
aws ec2 describe-security-groups \
  --group-ids $SG_ID \
  --query "SecurityGroups[0].IpPermissions" --output table

# Config ルールの準拠状態確認
aws configservice get-compliance-details-by-config-rule \
  --config-rule-name no-unrestricted-ssh \
  --query "EvaluationResults[0].ComplianceType"

# Ansible dry-run（ローカルPC から手動確認）
ansible-playbook ansible/playbooks/fix_sg.yml -e "sg_id=$SG_ID" --check

# Ansible 強制再適用
ansible-playbook ansible/playbooks/fix_sg.yml -e "sg_id=$SG_ID"

# クリーンアップ
terraform destroy -var="chatwork_api_token=$CHATWORK_API_TOKEN" -var="chatwork_room_id=$CHATWORK_ROOM_ID" -auto-approve
```

## 進め方のルール

1. ファイルを作る前にこの CLAUDE.md のディレクトリ構成・設計判断を確認する
2. Terraform apply 後は必ず `terraform output` で SG ID を確認してから次に進む
3. Lambda のコードを変更したら必ず `terraform apply` で再デプロイしてから動作確認する
4. クリーンアップは `terraform destroy` で行う（AWS コンソールで手動削除しない）
5. コスト注意：AWS Config は課金される。ハンズオン後は必ず destroy する

## トラブルシューティング

```
Lambda が起動しない:
  → aws events describe-rule --name config-sg-violation --query "State"
  → aws lambda get-policy --function-name sg-auto-remediation

Lambda が SG を修復できない:
  → aws iam list-role-policies --role-name sg-remediation-lambda-role
  → aws lambda invoke で手動テスト:
    aws lambda invoke \
      --function-name sg-auto-remediation \
      --payload '{"detail":{"resourceId":"sg-xxx","configRuleName":"no-unrestricted-ssh"}}' \
      /tmp/response.json && cat /tmp/response.json

Config Recorder が記録していない:
  → aws configservice describe-configuration-recorder-status \
      --query "ConfigurationRecordersStatus[0].recording"
  → false の場合は config.tf の depends_on を確認する

Chatwork に通知が届かない:
  → curl -X POST \
      -H "X-ChatWorkToken: $CHATWORK_API_TOKEN" \
      -d "body=テスト" \
      "https://api.chatwork.com/v2/rooms/$CHATWORK_ROOM_ID/messages"
  → {"message_id":"..."} が返れば Token/Room ID は正しい

Ansible が失敗する:
  → boto3 が入っているか: python3 -c "import boto3; print(boto3.__version__)"
  → AWS 認証が通っているか: aws sts get-caller-identity
  → 詳細ログ: ansible-playbook ... -vvv
```