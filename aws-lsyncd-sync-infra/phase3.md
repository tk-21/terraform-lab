# ✅Phase 3: 動作確認・トラブルシューティング

## Phase 2 からの引き継ぎ情報

- Terraform apply 済み（EC2 × 3 起動中）
- `ansible-playbook playbooks/site.yml` 実行済み
- lsyncd が master で稼働中
- lsyncd_delay = 5 秒（同期確認時は 5 秒以上待つ）

## このフェーズで行うこと

1. 環境の最終状態を確認する（Terraform outputs / Ansible inventory）
2. 動作確認スクリプトを生成する
3. トラブルシューティングチェックリストを出力する
4. docs/runbook と ADR を最終版として生成する

---

## Step 1: 現在の環境状態を確認

```bash
# Terraform output から接続情報を取得
cd aws-lsyncd-sync-infra/terraform
terraform output -json

# Ansible から見えている EC2 を確認
cd ../ansible
ansible-inventory -i inventory/aws_ec2.yml --graph
ansible all -i inventory/aws_ec2.yml -m ping
```

上記の出力結果を確認し、以下を報告すること:
- master の public IP
- slave × 2 の public IP
- すべての EC2 に ping が通っているか

---

## Step 2: 動作確認スクリプトを生成

`aws-lsyncd-sync-infra/scripts/verify.sh` を生成する:

```bash
#!/usr/bin/env bash
# =============================================================
# verify.sh — lsyncd 同期動作確認スクリプト
# Usage: bash scripts/verify.sh
# =============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
KEY_PATH="$PROJECT_ROOT/ansible/keys/ec2_key.pem"
DELAY=7  # lsyncd_delay(5秒) + バッファ(2秒)

# terraform output から IP を取得
MASTER_IP=$(cd "$PROJECT_ROOT/terraform" && terraform output -raw master_public_ip)
SLAVE_IPS=$(cd "$PROJECT_ROOT/terraform" && terraform output -json slave_public_ips | python3 -c "import sys,json; [print(ip) for ip in json.load(sys.stdin)]")

echo "=============================="
echo "lsyncd 動作確認"
echo "=============================="
echo "Master IP: $MASTER_IP"
echo "Slave IPs: $(echo $SLAVE_IPS | tr '\n' ' ')"
echo ""

# テストファイルを master に作成
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
TEST_FILE="sync_test_${TIMESTAMP}.html"
TEST_CONTENT="<h1>lsyncd sync test: $TIMESTAMP</h1>"

echo "[1/4] master にテストファイルを作成..."
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no ec2-user@"$MASTER_IP" \
  "echo '$TEST_CONTENT' | sudo tee /var/www/html/$TEST_FILE"

echo "[2/4] ${DELAY}秒待機（lsyncd 同期遅延）..."
sleep "$DELAY"

echo "[3/4] slave への同期を確認..."
FAILED=0
for SLAVE_IP in $SLAVE_IPS; do
  RESPONSE=$(curl -s --max-time 5 "http://$SLAVE_IP/$TEST_FILE" || echo "FAILED")
  if echo "$RESPONSE" | grep -q "$TIMESTAMP"; then
    echo "  ✅ slave $SLAVE_IP: 同期成功"
  else
    echo "  ❌ slave $SLAVE_IP: 同期失敗（レスポンス: $RESPONSE）"
    FAILED=1
  fi
done

echo "[4/4] テストファイルをクリーンアップ..."
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no ec2-user@"$MASTER_IP" \
  "sudo rm -f /var/www/html/$TEST_FILE"

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "=============================="
  echo "✅ 全 slave への同期が確認できました"
  echo "=============================="
else
  echo "=============================="
  echo "❌ 一部の slave で同期が確認できませんでした"
  echo "   トラブルシューティング: docs/runbook/operations.md を参照"
  echo "=============================="
  exit 1
fi
```

```bash
chmod +x aws-lsyncd-sync-infra/scripts/verify.sh
```

---

## Step 3: lsyncd ステータス確認コマンドを出力

以下のコマンドを実行して lsyncd の状態を確認し、結果を報告すること:

```bash
# master の IP を取得
MASTER_IP=$(cd aws-lsyncd-sync-infra/terraform && terraform output -raw master_public_ip)
KEY_PATH="aws-lsyncd-sync-infra/ansible/keys/ec2_key.pem"

# lsyncd サービス状態
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no ec2-user@"$MASTER_IP" \
  "sudo systemctl status lsyncd --no-pager"

# lsyncd ログ（直近 30 行）
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no ec2-user@"$MASTER_IP" \
  "sudo tail -30 /var/log/lsyncd.log"

# 同期ステータスファイル
ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no ec2-user@"$MASTER_IP" \
  "cat /var/run/lsyncd.status 2>/dev/null || echo 'status file not found'"
```

確認ポイント:
- `Active: active (running)` になっているか
- ログにエラーが出ていないか
- `lsyncd.status` に slave の IP が記録されているか

---

## Step 4: docs/ を最終版で生成

`aws-lsyncd-sync-infra/docs/adr/001-lsyncd-over-nfs.md`:

```markdown
# ADR-001: ファイル同期に NFS ではなく lsyncd を採用

## ステータス: 採用済み

## コンテキスト

master EC2 の `/var/www/html` を slave EC2 × 2 にリアルタイム同期する方式を選定。
NFS マウントと lsyncd + rsync over SSH の 2 案を検討した。

## 決定

lsyncd + rsync over SSH を採用する。

## 理由

| 観点 | NFS | lsyncd + rsync |
|---|---|---|
| 単一障害点 | NFS サーバが SPOF | slave は直前の同期内容を保持 |
| セキュリティ | NFS ポート開放が必要 | SSH のみ（ポート 22）で完結 |
| 帯域効率 | 全 I/O がネットワーク経由 | 差分のみ転送 |
| 実装複雑さ | NFS サーバ設定・マウント管理が必要 | lsyncd 1 つで完結 |
| ポートフォリオ観点 | 一般的すぎる | inotify + rsync の仕組みを示せる |

## トレードオフ

- lsyncd は非同期（デフォルト 5 秒遅延）。NFS は即時反映。
- ネットワーク分断時、slave が古い状態になる可能性がある。
- ハンズオン用途ではこの遅延は許容範囲と判断した。
```

`aws-lsyncd-sync-infra/docs/runbook/operations.md`:

```markdown
# 運用手順書 — aws-lsyncd-sync-infra

## セットアップ手順

### 前提条件

```bash
# Ansible コレクションをインストール
ansible-galaxy collection install amazon.aws community.general community.crypto ansible.posix
pip install boto3 botocore

# ツールバージョン確認
terraform version   # >= 1.7.0
ansible --version   # >= 2.14
```

### 1. Terraform でインフラ構築

```bash
cd terraform

# バックエンド用リソースを手動作成（初回のみ）
aws s3api create-bucket \
  --bucket your-tfstate-bucket \
  --region ap-northeast-1 \
  --create-bucket-configuration LocationConstraint=ap-northeast-1
aws s3api put-bucket-versioning \
  --bucket your-tfstate-bucket \
  --versioning-configuration Status=Enabled
aws dynamodb create-table \
  --table-name terraform-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-northeast-1

# backend.tf の bucket 名を変更後に実行
terraform init && terraform apply
```

### 2. Ansible でミドルウェア構築

```bash
cd ../ansible

# dynamic inventory 確認
ansible-inventory -i inventory/aws_ec2.yml --graph

# 全ロール適用
ansible-playbook playbooks/site.yml
```

### 3. 動作確認

```bash
bash scripts/verify.sh
```

## 日常運用

### lsyncd ステータス確認

```bash
MASTER_IP=$(cd terraform && terraform output -raw master_public_ip)
ssh -i ansible/keys/ec2_key.pem ec2-user@$MASTER_IP \
  'sudo systemctl status lsyncd && sudo tail -20 /var/log/lsyncd.log'
```

### lsyncd 再起動

```bash
ssh -i ansible/keys/ec2_key.pem ec2-user@$MASTER_IP 'sudo systemctl restart lsyncd'
```

## トラブルシューティング

### 同期されない場合

1. `systemctl status lsyncd` で稼働確認
2. `tail -100 /var/log/lsyncd.log` でエラー確認
3. SSH 疎通テスト（lsyncd 用鍵で）:
   ```bash
   ssh -i /home/ec2-user/.ssh/lsyncd_rsa ec2-user@<slave-private-ip> hostname
   ```
4. rsync 単体テスト:
   ```bash
   rsync -avz --delete -e "ssh -i /home/ec2-user/.ssh/lsyncd_rsa" \
     /var/www/html/ ec2-user@<slave-private-ip>:/var/www/html/
   ```

### lsyncd が EPEL からインストールできない場合

Amazon Linux 2023 では epel-release が利用できない場合があります。
その場合はソースビルドを行ってください:

```bash
sudo dnf install -y gcc make lua-devel cmake
git clone https://github.com/lsyncd/lsyncd.git
cd lsyncd && cmake . && make && sudo make install
```

## クリーンアップ

```bash
cd terraform
terraform plan -destroy  # 削除対象を確認
terraform destroy
```
```

---

## Step 5: README.md を最終版で生成

`aws-lsyncd-sync-infra/README.md` を以下の内容で上書きする:

```markdown
# aws-lsyncd-sync-infra

**Terraform × Ansible × lsyncd** による Web コンテンツリアルタイム同期基盤のハンズオン実装。

master EC2 の `/var/www/html` への変更を inotify で検知し、rsync over SSH で slave EC2 × 2 へ自動同期する **1:N 構成**。

## アーキテクチャ

```
                 ┌──────────────────────────────────────┐
                 │         VPC (10.0.0.0/16)             │
                 │                                        │
┌────────┐ SSH   │  ┌──────────────┐                     │
│ 運用者  │──────▶│  │    master    │                     │
└────────┘       │  │  EC2 t3.micro│                     │
                 │  │ /var/www/html│                     │
                 │  └──────┬───────┘                     │
                 │         │ lsyncd (rsync over SSH)      │
                 │    ┌────┴────┐                         │
                 │    ▼         ▼                         │
                 │ ┌────────┐ ┌────────┐                 │
                 │ │slave-1 │ │slave-2 │                 │
                 │ │ nginx  │ │ nginx  │                 │
                 │ └────────┘ └────────┘                 │
                 └──────────────────────────────────────┘
```

## 技術スタック

| レイヤー | 技術 |
|---|---|
| IaC | Terraform >= 1.7 |
| 構成管理 | Ansible + amazon.aws collection |
| 同期エンジン | lsyncd (inotify + rsync over SSH) |
| Web サーバー | nginx |
| CI/CD | GitHub Actions + OIDC（アクセスキー不使用） |
| インフラ | AWS EC2 t3.micro × 3, VPC, S3, DynamoDB |
| リージョン | ap-northeast-1 (東京) |

## ポートフォリオポイント

- **OIDC 認証**: GitHub Actions で AWS アクセスキーを使わない安全な CI/CD
- **Dynamic Inventory**: EC2 Tag で IP ハードコード排除
- **SSH 鍵2層設計**: 運用者用鍵と lsyncd 専用鍵を分離
- **ADR**: 技術選定の意思決定を文書化
- **日本語コメント**: 設計理由をコード内に明記

## クイックスタート

詳細は [運用手順書](docs/runbook/operations.md) を参照。

```bash
# 1. インフラ構築
cd terraform && terraform init && terraform apply

# 2. ミドルウェア設定
cd ../ansible && ansible-playbook playbooks/site.yml

# 3. 動作確認
bash ../scripts/verify.sh
```

## 月次コスト（概算）

t3.micro × 3台で **約 $32/月**。ハンズオン終了後は `terraform destroy` で削除。

## License

MIT
```

---

## Phase 3 完了条件

- [ ] `scripts/verify.sh` が存在し実行権限がある
- [ ] `bash scripts/verify.sh` がエラーなく完了する（slave 両方で同期成功）
- [ ] lsyncd が master で `active (running)` 状態
- [ ] docs/ が最終版で生成されている
- [ ] README.md が最終版になっている

## Phase 3 完了後のまとめ報告

以下を最終レポートとして出力すること:

1. **構築完了リソース一覧**（EC2 IP, SG ID 等）
2. **lsyncd 動作確認結果**（verify.sh の出力）
3. **GitHub 公開前チェックリスト**
   - [ ] `backend.tf` のバケット名が実際のものになっているか
   - [ ] `variables.tf` の `allowed_ssh_cidr` が絞られているか
   - [ ] `ansible/keys/` が `.gitignore` に含まれているか
   - [ ] `*.tfstate` が `.gitignore` に含まれているか
   - [ ] `terraform.tfvars` が `.gitignore` に含まれているか

## ハンズオン終了後のクリーンアップ

```bash
cd aws-lsyncd-sync-infra/terraform
terraform plan -destroy  # 削除対象を必ず確認
terraform destroy
```