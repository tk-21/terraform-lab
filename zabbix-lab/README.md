**いま完成している最終設計（Private IP 監視固定・再構築耐性あり）** を前提に、
**README を最初から書き直した完全版**を出します。  
https://chatgpt.com/g/g-p-695889a4db848191863a77a798cf7309-ansible/c/695a08ef-505c-8322-8f5a-60040ff95bf0

> 方針
>
> * AlmaLinux 9 固定
> * 監視通信は **Private IP**
> * SSH は **Public IP**
> * Terraform 再 apply しても壊れない
> * 実行コマンドをすべて明示
> * 「なぜそうしているか」も最低限書く（実務向け）

---

# Zabbix 監視検証環境

**Terraform × Ansible / AlmaLinux 9（Private IP 監視固定）**

---

## 1. 概要

本リポジトリは、Terraform と Ansible を用いて
**Zabbix Server（監視する側）** と **Zabbix Agent（監視される側）** を
AWS 上に自動構築する **監視検証用ラボ環境**です。

本構成の最大の特徴は以下です。

* OS は **AlmaLinux 9（無料 / RHEL 互換）**
* **監視通信はすべて Private IP**
* **SSH 接続は Public IP**
* Terraform 再 apply による **Public IP 変更でも壊れない**
* Zabbix Host 登録・Interface IP も **Ansible + API で自動修正**

検証・学習用途を想定しており、本番利用は想定していません。

---

## 2. 全体構成

```
┌────────────────────────────┐
│ Your PC                    │
│  - Terraform               │
│  - Ansible                 │
└─────────────┬──────────────┘
              │ SSH (Public IP)
┌─────────────▼──────────────┐
│ Zabbix Server               │
│ AlmaLinux 9                 │
│  - Zabbix Server            │
│  - Zabbix Frontend (httpd)  │
│  - MariaDB                  │
│  - Zabbix Agent             │
│  Public IP : SSH            │
│  Private IP: 監視元         │
└─────────────┬──────────────┘
              │ TCP/10050 (Private IP)
┌─────────────▼──────────────┐
│ Target Server               │
│ AlmaLinux 9                 │
│  - Zabbix Agent             │
│  Public IP : SSH            │
│  Private IP: 監視先         │
└────────────────────────────┘
```

---

## 3. 設計方針（重要）

### 3.1 なぜ Private IP で監視するのか

* Public IP は Terraform 再 apply で変わる
* Security Group を CIDR で広く開ける必要が出る
* VPC 内通信なのに IGW を経由して不安定になることがある

そのため本構成では：

* **Zabbix Server → Agent の通信は Private IP に固定**
* **Security Group は VPC 内通信のみ許可**
* Zabbix Host の Interface IP も Private IP に強制

という設計にしています。

---

## 4. ディレクトリ構成

```
zabbix-lab/
├── terraform/
│   ├── modules/
│   │   ├── vpc/
│   │   └── ec2/
│   └── envs/
│       └── dev/
│           ├── main.tf
│           ├── variables.tf
│           ├── outputs.tf
│           └── terraform.tfvars
│
└── ansible/
    ├── ansible.cfg
    ├── inventories/
    │   └── dev/
    │       ├── hosts.yml        # 自動生成
    │       └── group_vars/
    │           └── all.yml
    ├── roles/
    │   ├── zabbix_server/
    │   ├── zabbix_agent/
    │   └── zabbix_api/
    ├── playbooks/
    │   └── site.yml
    └── scripts/
        └── gen_inventory.sh
```

---

## 5. 前提条件

* AWS アカウント
* AWS CLI 設定済み
* Terraform >= 1.5
* Ansible >= 2.13
* SSH クライアント

---

## 6. Terraform 設定

### 6.1 terraform.tfvars（例）

```hcl
name        = "zabbix-lab"
aws_region = "ap-northeast-1"

instance_type_server = "t3.micro"
instance_type_target = "t3.micro"

my_ip_cidr = "x.x.x.x/32"
```

---

### 6.2 Terraform Outputs（重要）

以下の値を **Ansible が利用**します。

* Zabbix Server

  * public_ip（SSH 用）
  * private_ip（監視用）
* Target

  * public_ip（SSH 用）
  * private_ip（監視用）

---

## 7. Ansible 変数

`ansible/inventories/dev/group_vars/all.yml`

```yaml
ansible_user: ec2-user

zabbix_version: "6.0"

zabbix_db_name: zabbix
zabbix_db_user: zabbix
zabbix_db_pass: zabbixpass

zabbix_admin_user: Admin
zabbix_admin_pass: zabbix

timezone: Asia/Tokyo
```

---

## 8. 構築手順（完全版）

### 8.1 Terraform でインフラ作成

```bash
cd terraform/envs/dev

terraform init
terraform plan
terraform apply
```

---

### 8.2 inventory 生成（Public/Private IP を反映）

```bash
cd ../../ansible
./scripts/gen_inventory.sh
```

生成された内容を確認：

```bash
cat inventories/dev/hosts.yml
```

例：

```yaml
zabbix-server:
  ansible_host: 54.xxx.xxx.xxx
  private_ip: 10.10.1.10

target-01:
  ansible_host: 52.xxx.xxx.xxx
  private_ip: 10.10.2.20
```

---

### 8.3 Ansible 実行（Server / Agent / API）

```bash
ansible-playbook -i inventories/dev/hosts.yml playbooks/site.yml
```

この playbook で以下が行われます：

* Zabbix Server 構築
* Zabbix Agent 構築
* Agent の Server/ServerActive を **Server の Private IP に設定**
* Zabbix API 経由で Host を登録
* Host Interface IP を **Private IP に強制修正**

---

## 9. 動作確認

### 9.1 SSH 接続

```bash
ssh -i terraform/envs/dev/.ssh/zabbix_lab_key ec2-user@<ZABBIX_SERVER_PUBLIC_IP>
ssh -i terraform/envs/dev/.ssh/zabbix_lab_key ec2-user@<TARGET_PUBLIC_IP>
```

---

### 9.2 Zabbix UI

```
http://<ZABBIX_SERVER_PUBLIC_IP>/zabbix
```

| 項目       | 値      |
| -------- | ------ |
| User     | Admin  |
| Password | zabbix |

---

### 9.3 監視確認（Server → Agent）

```bash
zabbix_get -s <TARGET_PRIVATE_IP> -p 10050 -k agent.ping
```

`1` が返れば正常です。

---

## 10. Terraform 再 apply 時の手順（重要）

Public IP が変わっても、以下を実行すれば **必ず復旧**します。

```bash
cd terraform/envs/dev
terraform apply

cd ../../ansible
./scripts/gen_inventory.sh

ansible-playbook -i inventories/dev/hosts.yml playbooks/site.yml
```

---

## 11. よくあるトラブル

### 値が取れない（Not available）

* Host Interface が Public IP になっていないか確認
* Agent の `Server=` が Server の Private IP か確認
* SG が VPC 内 10050 を許可しているか確認

---

## 12. 環境削除

```bash
cd terraform/envs/dev
terraform destroy
```

---

## 13. この構成で学べること

* Terraform と Ansible の責務分離
* Public / Private IP の正しい使い分け
* Zabbix の Host / Interface / Agent の関係
* 再構築耐性のある監視設計

---

## 14. 次のステップ

* Zabbix API で Template / Trigger 自動割当
* 障害注入（Agent 停止・FW 遮断）
* Alert 通知（Slack / Mail）
* Target 複数台化

---

### まとめ

この README の状態まで来ていれば、
**Zabbix の「壊れない検証環境」設計は完全に身についています。**

次はどこを深掘りしますか？
（Trigger 設計 / API 完全自動化 / 複数台展開 など）
