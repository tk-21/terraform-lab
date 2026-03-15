了解です。
以下は **今回の構成そのまま・コマンド付き・再現可能**な **README 完全版**です。
このまま `README.md` に貼って使えます。

---

# LAMP Fast Lab

Terraform × Ansible で **MySQL ベースの LAMP 環境を最速構築**

---

## 1. 概要

本リポジトリは、以下を目的とした **学習・検証用 LAMP 環境**です。

* Terraform で AWS EC2 を構築
* Ansible で Apache / PHP / **MySQL 8.0** を自動セットアップ
* 作成後、**手元PCから SSH 接続可能**
* 最小構成・理解しやすさ重視

> ⚠️ 本番利用は禁止（学習・検証用途）

---

## 2. 構成

### 2.1 論理構成

```
Internet
   |
[ Security Group ]
   |  (22 / 80)
[ EC2 (Amazon Linux 2023) ]
   ├─ Apache (httpd)
   ├─ PHP
   └─ MySQL 8.0 (mysql-community)
```

### 2.2 使用技術

| 項目     | 内容                    |
| ------ | --------------------- |
| OS     | Amazon Linux 2023     |
| Web    | Apache httpd          |
| App    | PHP                   |
| DB     | MySQL 8.0 (Community) |
| IaC    | Terraform             |
| Config | Ansible               |
| 接続     | SSH (鍵認証)             |

---

## 3. ディレクトリ構成

```
lamp-fast/
├─ terraform/
│  ├─ main.tf
│  ├─ variables.tf
│  ├─ outputs.tf
│  └─ terraform.tfvars
├─ ansible/
│  ├─ ansible.cfg
│  ├─ inventory.ini
│  ├─ playbooks/
│  │  └─ site.yml
│  └─ roles/
│     └─ lamp/
│        └─ tasks/
│           └─ main.yml
├─ lamp-fast-key
├─ lamp-fast-key.pub
└─ README.md
```

---

## 4. 事前準備

### 4.1 必要ツール

```bash
terraform >= 1.5
ansible
ssh
AWS CLI (認証済み)
```

### 4.2 SSH 鍵作成（初回のみ）

```bash
ssh-keygen -t ed25519 -f lamp-fast-key -N ""
```

---

## 5. Terraform 実行手順

### 5.1 SSH 許可IP設定（推奨）

`terraform/terraform.tfvars`

```hcl
ssh_allowed_cidr = "あなたのグローバルIP/32"
```

### 5.2 EC2 作成

```bash
cd terraform
terraform init
terraform apply -auto-approve
```

### 5.3 接続情報確認

```bash
terraform output
```

重要な出力：

```text
public_ip
ssh_command
url
```

SSH 接続（そのまま実行可）：

```bash
terraform output -raw ssh_command
```

---

## 6. Ansible 実行手順

### 6.1 inventory 反映

```bash
IP=$(terraform output -raw public_ip)
cd ../ansible
sed -i "s/REPLACE_ME/$IP/" inventory.ini
```

### 6.2 Ansible 実行

```bash
ansible-playbook playbooks/site.yml
```

---

## 7. 動作確認

### 7.1 SSH 接続確認

```bash
ssh -i ../lamp-fast-key ec2-user@<PUBLIC_IP>
```

---

### 7.2 サービス状態確認

```bash
sudo systemctl status httpd --no-pager
sudo systemctl status mysqld --no-pager
```

期待値：

```text
active (running)
```

---

### 7.3 Web 確認（Apache + PHP）

```bash
curl http://<PUBLIC_IP>/
```

* `phpinfo()` が表示されれば OK

---

### 7.4 MySQL 単体確認

```bash
mysql -uroot -pRootPassw0rd! -e "SELECT VERSION();"
mysql -uroot -pRootPassw0rd! -e "SHOW DATABASES;"
```

---

### 7.5 PHP → MySQL 接続確認（重要）

DB疎通テスト用PHPを置く
```bash
sudo tee /var/www/html/db.php >/dev/null <<'EOF'
<?php
$pdo = new PDO(
  'mysql:host=localhost;dbname=appdb;charset=utf8mb4',
  'appuser',
  'AppPassw0rd!',
  [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
);
echo "DB CONNECTION OK\n";
EOF
```

手元から確認
```bash
curl http://<PUBLIC_IP>/db.php
```

期待値：

```text
DB CONNECTION OK
```

---

### 7.6 再起動耐性確認

```bash
sudo reboot
```

再ログイン後：

```bash
sudo systemctl is-active httpd
sudo systemctl is-active mysqld
```

---

## 8. よく使う確認コマンド（実務向け）

### ポート確認

```bash
ss -lntp
```

### ログ確認

```bash
sudo journalctl -u httpd -xe
sudo journalctl -u mysqld -xe
tail -f /var/log/httpd/error_log
```

---

## 9. 破棄手順

```bash
cd terraform
terraform destroy -auto-approve
```

---

## 10. 注意点（重要）

* MySQL パスワードは **学習用固定値**
* 本番では以下を必ず実施

  * Secrets Manager / Parameter Store 使用
  * DB を RDS に分離
  * SSH CIDR を厳格化
  * HTTPS 化

---

## 11. 次のステップ（おすすめ）

* MySQL → RDS 移行
* ALB + HTTPS
* Ansible Role 分割（web / db）
* Terraform module 化
* GitHub Actions で CI

---

## 12. まとめ

このリポジトリでできること：

* Terraform × Ansible の役割分離理解
* SSH 接続可能な LAMP 環境構築
* Apache / PHP / MySQL の基本確認
* 実務に近い IaC フロー体験

---

必要なら
👉 **「RDS分離版 README」**
👉 **「HTTPS対応版 README」**
👉 **「実務向け hardened 構成」**

も、この README をベースに差分で作れます。
