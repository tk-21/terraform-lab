# terraform-ansible-ssm-alb-lab（SSM / Private Subnet / ALB 版）  
https://chatgpt.com/g/g-p-695889a4db848191863a77a798cf7309-ansible/c/695b13cd-ff48-8322-9ba5-49de62180ccb

Terraform と Ansible を **実務と同じ責務分離**で連携させる
**学習・検証用 IaC ラボ環境（SSM 接続・Private Subnet 構成）**です。

* Terraform：**インフラ（土台）を作る**
* Ansible：**サーバの中身（設定）を作る**
* 両者は **Terraform output → Ansible inventory 自動生成**で疎結合に連携
* **SSH / キーペア / 22番ポートは一切使用しない**
* EC2 は **Private Subnet 配置**
* 外部アクセスは **ALB 経由のみ**

> ⚠️ 本番利用は禁止（破棄前提のラボ）

---

## 1. このプロジェクトで作られるもの

このリポジトリを一通り実行すると、以下が実現されます。

* VPC / Public & Private Subnet / Route / NAT Gateway
* Public Subnet に **Application Load Balancer**
* Private Subnet に **EC2（Amazon Linux 2023）**
* EC2 に **SSM 用 IAM Role（AmazonSSMManagedInstanceCore）**
* **VPC Endpoint（ssm / ssmmessages / ec2messages）**
* Terraform output から **SSM 用 Ansible inventory を自動生成**
* Ansible を **SSM 経由**で実行し nginx をインストール・起動
* `http://<ALB DNS>/` にアクセスすると `ok` が返る

---

## 2. 構成イメージ（論理）

```text
[ Local PC ]
   |
   | make apply
   | make inv
   | make run   (Ansible via SSM)
   v
[ AWS ]
  ├─ VPC
  │   ├─ Public Subnet
  │   │   └─ ALB (80 open)
  │   └─ Private Subnet
  │       └─ EC2 (nginx)
  │           ├─ IAM Role (SSM)
  │           ├─ VPC Endpoint (SSM)
  │           └─ NAT Gateway (dnf/yum 用)
```

---

## 3. ディレクトリ構成

```text
.
├── terraform/                   # インフラ定義（Terraform）
│   └── envs/dev/                # dev 環境（VPC / Subnet / ALB / EC2 / IAM / S3）
├── ansible/                     # 構成管理（Ansible）
│   ├── ansible.cfg
│   ├── inventories/dev/         # inventory（自動生成）
│   ├── playbooks/site.yml
│   └── roles/nginx/             # nginx role
├── scripts/
│   └── gen_inventory.sh         # Terraform → Ansible inventory 生成
└── Makefile                     # 実行手順の固定化
```

---

## 4. 前提条件

ローカルに以下がインストール・設定されていること。

* Terraform（1.6+）
* Python 3.10+（venv 使用）
* Ansible（venv 内にインストール）
* AWS CLI v2（認証済み）
* session-manager-plugin

> **SSH 鍵 / EC2 キーペアは不要**

---

## 5. 初期セットアップ（最初に一度だけ）

### 5.1 AWS 認証確認

```bash
aws sts get-caller-identity
```

アカウント情報が表示されれば OK。

---

### 5.2 Ansible 用 venv 作成

```bash
cd ansible

python3 -m venv venv
source venv/bin/activate

python -m pip install -U pip
pip install ansible boto3 botocore amazon.aws community.aws
```

確認：

```bash
ansible --version
python -c "import boto3, botocore; print('ok')"
```

---

## 6. 実行手順（基本フロー）

### ① インフラ作成（Terraform）

```bash
make apply
```

* VPC / Subnet / ALB / EC2 / IAM Role / VPC Endpoint / S3 が作成される
* `instance_id` / `alb_url` が Terraform output に出力される

---

### ② inventory 自動生成（Terraform → Ansible）

```bash
make inv
```

* Terraform output を元に
  `ansible/inventories/dev/hosts.yml` が生成される
* inventory は **SSM 前提（instance_id がホスト名）**
* **手動編集は禁止**

---

### ③ 疎通確認（Ansible ping via SSM）

```bash
make ping
```

成功例：

```text
i-xxxxxxxxxxxxxxxxx | SUCCESS => {
  "changed": false,
  "ping": "pong"
}
```

---

### ④ 影響確認（ドライラン）

```bash
make diff
```

* 実際には変更しない
* 変更差分のみ確認

👉 **実務では必須**

---

### ⑤ 構成適用（Ansible）

```bash
make run
```

* SSM 経由で nginx がインストール・起動される

---

## 7. 動作確認（ALB 経由）

```bash
curl "$(terraform -chdir=terraform/envs/dev output -raw alb_url)"
```

```text
ok
```

> EC2 は Private Subnet のため **直接アクセス不可（設計通り）**

---

## 8. よく使う Make コマンド一覧

| コマンド                     | 内容                |
| ------------------------ | ----------------- |
| `make fmt`               | terraform fmt     |
| `make apply`             | インフラ作成            |
| `make destroy`           | インフラ削除            |
| `make inv`               | inventory 自動生成    |
| `make ping`              | Ansible 疎通確認（SSM） |
| `make diff`              | 変更差分確認            |
| `make run`               | Ansible 実行        |
| `make run-one HOST=<id>` | 1台だけ適用            |

---

## 9. 正常完了の確認ポイント（チェックリスト）

* `make ping` が成功
* `make diff` で差分なし
* `curl <ALB URL>` が `ok` を返す
* ALB Target Group が `healthy`
* `aws ssm start-session --target <instance_id>` で接続可能
* `systemctl status nginx` が `active (running)`

---

## 10. 後片付け（必ず実行）

```bash
make destroy
```

* EC2 / ALB / VPC / S3 すべて削除
* **課金防止のため必須**
* S3 は `force_destroy = true` により destroy で止まらない

---

## 11. このラボの学習ゴール

このプロジェクトの目的は **nginx** ではありません。

* Terraform / Ansible の責務分離
* SSH を使わない **SSM 運用設計**
* Private Subnet + ALB の実務構成
* output → inventory 連携パターン
* `diff → apply` を守る安全な IaC 運用

これを **自力で再構築・説明できる状態**になることがゴールです。

---

## 12. 次のステップ（発展）

* NAT Gateway を廃止（完全閉域構成）
* EC2 を複数台 + Auto Scaling Group
* ALB HTTPS 化（ACM）
* role を `common / web` に分割
* GitHub Actions から SSM 経由で Ansible 実行

---

必要であれば次に、

* **この構成を図解付きで解説した設計ドキュメント**
* **SSH 版との比較（なぜ SSM が良いか）**
* **実務レビュー観点チェックリスト**

まで一気に仕上げられます。
ここまで来ているので、**かなり実務レベル**です。
