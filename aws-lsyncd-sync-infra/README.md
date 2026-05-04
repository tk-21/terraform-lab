# aws-lsyncd-sync-infra

**Terraform × Ansible × lsyncd** で構築する Web コンテンツ自動同期基盤のハンズオン。

---

## このハンズオンで何を学ぶのか

### 解決する課題

Web サーバーを複数台運用していると「master にファイルを置いたが他のサーバーに反映されていない」という問題が起きやすい。手動コピーは抜け漏れが発生し、cron での定期同期では遅延が大きい。

このハンズオンでは **lsyncd** を使って「master でファイルを保存した瞬間に slave 全台へ自動伝播する」仕組みを構築する。

### 構築する構成

```
                 ┌──────────────────────────────────────┐
                 │         VPC (10.0.0.0/16)             │
                 │                                        │
┌────────┐ SSM  │  ┌──────────────┐                     │
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

**セキュリティ設計のポイント:**
- 運用者からの EC2 アクセスは **SSM Session Manager** 経由のみ（ポート22はインターネットに開けない）
- master→slave の lsyncd 通信は **VPC 内プライベート IP** で完結（SSH ポートは VPC 内のみ許可）

**動作の流れ:**
1. 運用者が master の `/var/www/html` にファイルを置く
2. lsyncd が inotify でファイル変更を検知（即時）
3. 5 秒後に rsync over SSH で slave-1・slave-2 へ自動転送
4. slave の nginx が更新されたファイルを配信

### できるようになること

| 学習項目 | 習得内容 |
|---|---|
| **Terraform** | AWS リソース（VPC/EC2/SG/S3）の IaC 管理、リモートバックエンド |
| **Ansible** | Dynamic Inventory（EC2 Tag でグループ自動分類）、ロール構成 |
| **lsyncd** | inotify + rsync over SSH によるリアルタイム同期の仕組み |
| **SSH 鍵管理** | 用途別の鍵分離（lsyncd 専用）と Ansible 経由の自動配布 |
| **SSM** | ポート22不要のセキュアな EC2 アクセス |
| **OIDC 認証** | GitHub Actions で AWS アクセスキーを使わない CI/CD |

### ポートフォリオとしての価値

- 「インフラをコードで管理できる」ことを具体的に示せる
- NFS との比較設計（ADR）で技術選定の思考プロセスを説明できる
- Dynamic Inventory・OIDC・SSM など、現場で使われるプラクティスを実践している

---

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

---

## ハンズオン全体の流れ

```
[事前準備] ローカル環境のセットアップ（初回のみ）
    → ツールインストール、AWS 認証、venv セットアップ

[Phase 1] Terraform でインフラ構築
    → VPC / EC2 × 3 / Security Group / SSH 鍵ペアを作成
    → 所要時間: ~30 分

[Phase 2] Ansible でミドルウェア設定
    → nginx / lsyncd インストール、SSH 鍵配布、lsyncd 起動
    → 所要時間: ~30 分

[Phase 3] 動作確認
    → master にファイルを置いて slave への同期を確認
    → 所要時間: ~15 分
```

---

## 事前準備: ローカル環境のセットアップ（初回のみ）

### 必須ツールの確認・インストール

```bash
terraform version          # >= 1.7.0
aws --version              # AWS CLI v2
python3 --version          # >= 3.9
session-manager-plugin --version   # SSM Session Manager Plugin
```

**Terraform のインストール（未インストールの場合）:**

```bash
curl -fsSL https://releases.hashicorp.com/terraform/1.9.0/terraform_1.9.0_linux_amd64.zip -o /tmp/tf.zip
unzip /tmp/tf.zip -d /tmp && sudo mv /tmp/terraform /usr/local/bin/
```

**SSM Session Manager Plugin のインストール（未インストールの場合）:**

```bash
# Linux (deb 系)
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o /tmp/ssm-plugin.deb
sudo dpkg -i /tmp/ssm-plugin.deb

# Linux (rpm 系)
sudo yum install -y https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm

# macOS
brew install --cask session-manager-plugin
```

### AWS 認証設定

```bash
aws configure
# → Access Key ID, Secret Access Key, region: ap-northeast-1, output: json を入力

aws sts get-caller-identity   # Account/UserId/Arn が返れば OK
```

### Python venv のセットアップ

> **venv が必要な理由**: Python 3.11+ では PEP 668 により system Python への `pip install` がエラーになるディストリビューションが多い。また boto3 のバージョン競合を避けるため、プロジェクト専用 venv を使う。

```bash
cd /path/to/aws-lsyncd-sync-infra

python3 -m venv .venv
source .venv/bin/activate     # シェルを開き直す度に必要

pip install --upgrade pip
pip install ansible boto3 botocore

ansible --version             # ansible [core 2.17.x] などと出れば OK
```

### Ansible Galaxy コレクションのインストール

```bash
ansible-galaxy collection install \
  amazon.aws \
  community.general \
  community.crypto \
  ansible.posix

ansible-galaxy collection list | grep amazon   # インストール確認
```

---

## Phase 1: Terraform でインフラを構築する

### 1-1. バックエンド用 AWS リソースを手動作成（初回のみ）

Terraform の state ファイルを S3 で管理するため、**apply より前に**以下を実行:

```bash
# アカウント ID を含むユニークなバケット名を生成
BUCKET_NAME="tfstate-lsyncd-$(aws sts get-caller-identity --query Account --output text)"
echo "使用するバケット名: $BUCKET_NAME"

aws s3api create-bucket \
  --bucket "$BUCKET_NAME" \
  --region ap-northeast-1 \
  --create-bucket-configuration LocationConstraint=ap-northeast-1

# バージョニング有効化（state の誤削除対策）
aws s3api put-bucket-versioning \
  --bucket "$BUCKET_NAME" \
  --versioning-configuration Status=Enabled

# DynamoDB テーブル作成（state ロック用）
aws dynamodb create-table \
  --table-name terraform-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-northeast-1
```

### 1-2. Terraform の設定値を変更

`terraform/backend.tf` のバケット名を変更:

```hcl
# 変更前
bucket = "YOUR_TFSTATE_BUCKET_NAME"

# 変更後（1-1 で確認したバケット名に置き換え）
bucket = "tfstate-lsyncd-123456789012"
```

### 1-3. Terraform を実行

```bash
cd terraform

terraform init
# → "Terraform has been successfully initialized!" が出れば OK

terraform plan
# → 作成リソース一覧を目視確認（EC2×3, VPC, SG, IAM role など）

terraform apply
# → "yes" と入力（EC2 起動まで約 2〜3 分）

terraform output
# → master_instance_id と slave_public_ips を確認
```

**apply 完了後に確認すること:**

```bash
# 秘密鍵が生成されているか確認
ls -la ../ansible/keys/ec2_key.pem
# → -rw------- (0600) で存在すれば OK

# SSM 経由で master に接続確認（EC2 起動後 1〜2 分待つ）
MASTER_ID=$(terraform output -raw master_instance_id)
aws ssm start-session --target "$MASTER_ID" --region ap-northeast-1
# → シェルが開けば OK（exit で抜ける）
```

---

## Phase 2: Ansible でミドルウェアを設定する

### 2-1. venv を有効化（シェルを開き直した場合は毎回必要）

```bash
cd /path/to/aws-lsyncd-sync-infra
source .venv/bin/activate
```

### 2-2. Dynamic Inventory の疎通確認

EC2 が Ansible から見えているか確認:

```bash
cd ansible
ansible-inventory -i inventory/aws_ec2.yml --graph
```

**期待される出力:**

```
@all:
  |--@master:
  |  |--i-0abc1234...
  |--@slave:
  |  |--i-0def5678...
  |  |--i-0ghi9012...
```

> **なぜ Dynamic Inventory を使うのか?**
> EC2 の IP は起動のたびに変わる可能性がある。IP をファイルにハードコードすると毎回書き換えが必要になる。Dynamic Inventory は EC2 の Tag（`Role=master` / `Role=slave`）を読み取って自動でグループを生成するため、IP 変更に対応できる。

**全ホストへの ping 確認:**

```bash
ansible all -i inventory/aws_ec2.yml -m ping
# → SUCCESS が master + slave 2台分出れば OK
```

> Ansible は `ansible.cfg` に設定された SSM ProxyCommand 経由で SSH 接続する。ホスト名にはインスタンス ID が使われる。

### 2-3. Ansible Playbook を実行

```bash
# 構文チェック（推奨）
ansible-playbook playbooks/site.yml --syntax-check

# 本番実行（約 5〜10 分）
ansible-playbook playbooks/site.yml
```

**Playbook の処理内容（順序どおり）:**

| role | 対象 | 内容 |
|---|---|---|
| common | 全台 | タイムゾーン設定・パッケージ更新・rsync インストール |
| nginx | 全台 | nginx インストール・起動。master のみ `index.html` を配置 |
| ssh_key_dist | 全台 | master で lsyncd 用鍵ペアを生成 → slave の `authorized_keys` に公開鍵を追加 |
| lsyncd | master のみ | lsyncd インストール・設定ファイル配置・起動 |

---

## Phase 3: 動作確認

### 3-1. 自動確認スクリプトを実行

```bash
cd ..  # プロジェクトルートへ
bash scripts/verify.sh
```

スクリプトは以下を自動実行する:
1. master にタイムスタンプ入りテストファイルを作成
2. 7 秒待機（lsyncd の遅延 5 秒 + バッファ）
3. slave-1・slave-2 に同期されているか curl で確認
4. テストファイルを削除

**成功時の出力:**

```
==============================
lsyncd 動作確認
==============================
[1/4] master にテストファイルを作成...
[2/4] 7秒待機（lsyncd 同期遅延）...
[3/4] slave への同期を確認...
  ✅ slave 54.xx.xx.xx: 同期成功
  ✅ slave 52.xx.xx.xx: 同期成功
[4/4] テストファイルをクリーンアップ...

==============================
✅ 全 slave への同期が確認できました
==============================
```

### 3-2. 手動で動作確認したい場合

```bash
cd terraform
MASTER_ID=$(terraform output -raw master_instance_id)
SLAVE1_IP=$(terraform output -json slave_public_ips | python3 -c "import sys,json; print(json.load(sys.stdin)[0])")
SLAVE2_IP=$(terraform output -json slave_public_ips | python3 -c "import sys,json; print(json.load(sys.stdin)[1])")

# SSM 経由でテストファイルを master に作成
aws ssm send-command \
  --instance-ids "$MASTER_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["echo \"hello from master - $(date)\" | sudo tee /var/www/html/test.html"]' \
  --region ap-northeast-1

# 5 秒以上待ってから slave で確認
sleep 7
curl http://$SLAVE1_IP/test.html
curl http://$SLAVE2_IP/test.html
# → 両方で "hello from master - ..." が返れば同期成功
```

---

## 日常運用

### EC2 への接続（SSM Session Manager）

このプロジェクトはインターネットからのポート 22 を開けない設計。EC2 へのアクセスはすべて SSM 経由で行う。

```bash
MASTER_ID=$(cd terraform && terraform output -raw master_instance_id)

# コンソールセッションを開く（SSH クライアント不要）
aws ssm start-session --target "$MASTER_ID" --region ap-northeast-1
```

SSH クライアントでファイル転送などが必要な場合は ProxyCommand 経由:

```bash
ssh -i ansible/keys/ec2_key.pem \
  -o ProxyCommand="aws ssm start-session --target $MASTER_ID --document-name AWS-StartSSHSession --parameters portNumber=22 --region ap-northeast-1" \
  ec2-user@"$MASTER_ID"
```

### lsyncd の状態確認

```bash
# SSM セッションを開いてから実行
sudo systemctl status lsyncd
sudo tail -20 /var/log/lsyncd.log
```

または SSM send-command で直接確認:

```bash
MASTER_ID=$(cd terraform && terraform output -raw master_instance_id)
CMD_ID=$(aws ssm send-command \
  --instance-ids "$MASTER_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["sudo systemctl status lsyncd && sudo tail -20 /var/log/lsyncd.log"]' \
  --region ap-northeast-1 \
  --query 'Command.CommandId' \
  --output text)

# 数秒後に出力を確認
aws ssm get-command-invocation \
  --command-id "$CMD_ID" \
  --instance-id "$MASTER_ID" \
  --region ap-northeast-1 \
  --query 'StandardOutputContent' \
  --output text
```

### lsyncd の再起動

```bash
# SSM セッション内で
sudo systemctl restart lsyncd
```

---

## トラブルシューティング

### slave に同期されない

```bash
# master に SSM でログインして確認
MASTER_ID=$(cd terraform && terraform output -raw master_instance_id)
aws ssm start-session --target "$MASTER_ID" --region ap-northeast-1

# セッション内で実行
sudo systemctl status lsyncd
sudo tail -100 /var/log/lsyncd.log

# lsyncd 専用鍵で slave への SSH 疎通確認（プライベート IP）
ssh -i /home/ec2-user/.ssh/lsyncd_rsa \
  -o StrictHostKeyChecking=no \
  ec2-user@<slave-private-ip> hostname

# rsync 単体テスト
rsync -avz --delete \
  -e "ssh -i /home/ec2-user/.ssh/lsyncd_rsa" \
  /var/www/html/ ec2-user@<slave-private-ip>:/var/www/html/
```

### ansible-inventory でホストが表示されない

```bash
# venv が有効化されているか確認
source .venv/bin/activate
python3 -c "import boto3; print(boto3.__version__)"

# EC2 の状態と Tag を確認
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=aws-lsyncd-sync-infra" \
  --query "Reservations[].Instances[].[InstanceId,State.Name,Tags[?Key=='Role'].Value|[0]]" \
  --output table
```

### SSM セッションが開けない

```bash
# EC2 インスタンスの SSM 登録状態を確認
MASTER_ID=$(cd terraform && terraform output -raw master_instance_id)
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$MASTER_ID" \
  --region ap-northeast-1

# 登録されていない場合: IAM ロールが正しくアタッチされているか確認
aws iam get-role --role-name lsyncd-ws-ec2-role
```

> EC2 起動直後は SSM Agent の初期化に 1〜2 分かかる。すぐに接続できない場合は少し待ってから再試行。

### Ansible の SSH 接続が失敗する

```bash
# SSM ProxyCommand を手動で試す
MASTER_ID=$(cd terraform && terraform output -raw master_instance_id)
ssh -i ansible/keys/ec2_key.pem \
  -o ProxyCommand="aws ssm start-session --target $MASTER_ID --document-name AWS-StartSSHSession --parameters portNumber=22 --region ap-northeast-1" \
  ec2-user@"$MASTER_ID" hostname
```

### lsyncd が EPEL からインストールできない

Amazon Linux 2023 では epel-release が利用できない場合がある。その場合はソースビルドで対応:

```bash
sudo dnf install -y gcc make lua-devel cmake
git clone https://github.com/lsyncd/lsyncd.git
cd lsyncd && cmake . && make && sudo make install
```

---

## クリーンアップ（必ず実施）

ハンズオン終了後は **$32/月** のコストが発生し続けるため、必ず削除する:

```bash
cd terraform
terraform plan -destroy   # 削除対象を確認
terraform destroy         # EC2, VPC, IAM role 等を全削除
```

> **注意**: S3 バケットと DynamoDB テーブルは `terraform destroy` では削除されない。不要な場合は手動削除:
>
> ```bash
> aws s3 rb s3://YOUR_BUCKET_NAME --force
> aws dynamodb delete-table --table-name terraform-lock --region ap-northeast-1
> ```

---

## 月次コスト（概算）

| リソース | 単価 | 数量 | 月額 |
|---|---|---|---|
| t3.micro EC2 | $0.0136/h | 3台 | ~$30 |
| EBS gp3 8GB | $0.096/GB | 3台 | ~$2 |
| S3 (tfstate) | - | 1 | ~$0.01 |
| **合計** | | | **~$32** |

---

## License

MIT
