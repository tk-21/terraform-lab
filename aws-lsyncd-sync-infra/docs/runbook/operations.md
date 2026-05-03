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

# terraform.tfvars で SSH CIDR を自宅 IP に絞る（必須）
cat > terraform.tfvars <<'EOF'
allowed_ssh_cidr = "YOUR_HOME_IP/32"  # curl ifconfig.me で確認
EOF

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
