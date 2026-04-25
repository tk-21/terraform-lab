# ✅Phase3: Ansible Dynamic Inventory + Role構成 + Flask デプロイ

## Phaseサマリー（前Phaseの状態）
Phase1-2完了済み:
- VPC + Subnets + IGW + NAT GW 稼働中
- App EC2 × 2台 (Private Subnet, IMDSv2, SSM対応) 稼働中
- Bastion EC2 × 1台 (Public Subnet) 稼働中
- ALB稼働中（Target GroupはUnhealthy状態）
- 全EC2に `Role=app` または `Role=bastion` タグが付与済み
- IAM RoleにAmazonSSMManagedInstanceCore付与済み

## このPhaseの目的
Ansibleをセットアップし、Dynamic Inventoryでタグからホストを自動検出。
Nginx + FlaskをデプロイしてヘルスチェックをHealthyにする。

---

## 前提: Ansibleインストール確認

```bash
pip install ansible boto3 botocore
ansible --version  # 2.15以上を確認
ansible-galaxy collection install amazon.aws
```

---

## Task 1: Ansible設定ファイル

### ansible/ansible.cfg

```ini
[defaults]
inventory          = inventory/aws_ec2.yml
remote_user        = ec2-user
host_key_checking  = False
stdout_callback    = yaml
interpreter_python = auto_silent
retry_files_enabled = False

[ssh_connection]
# SSMセッションマネージャー経由のSSH接続設定
ssh_args = -o StrictHostKeyChecking=no -o ProxyCommand="aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p"
transfer_method = smart
```

---

## Task 2: Dynamic Inventory設定

### ansible/inventory/aws_ec2.yml

以下の要件でYAMLを作成:

```yaml
plugin: amazon.aws.aws_ec2

# 対象リージョン
regions:
  - ap-northeast-1

# TerraformのタグでフィルタリングしてApp EC2のみ対象に
filters:
  tag:Project: "terraform-ansible-platform"
  tag:Environment: "dev"
  tag:Role: "app"
  instance-state-name: running

# ホスト名にインスタンスIDを使用（IPアドレスは変動するため）
hostnames:
  - instance-id

# グループをタグで自動生成
keyed_groups:
  - key: tags.Role
    prefix: role
  - key: tags.Environment
    prefix: env

# Ansible接続変数を設定
compose:
  ansible_host: instance_id  # SSM経由接続のためinstance_idをhostに使用
```

### 動作確認コマンド
```bash
cd ansible
ansible-inventory -i inventory/aws_ec2.yml --list
# role_app グループにEC2 2台が表示されること
```

---

## Task 3: group_vars設定

### ansible/group_vars/all.yml
```yaml
# 全ホスト共通変数
ansible_connection: aws_ssm
ansible_aws_ssm_region: ap-northeast-1

# アプリケーション共通設定
app_name: flask-platform-api
app_user: app
app_group: app
app_dir: /opt/flask-app
app_port: 5000
```

### ansible/group_vars/app_servers.yml
```yaml
# Nginxリバースプロキシ設定
nginx_proxy_pass: "http://127.0.0.1:{{ app_port }}"
nginx_server_name: "_"

# Pythonバージョン
python_version: "python3"
pip_executable: "pip3"
```

---

## Task 4: commonロール

`ansible/roles/common/` に以下を作成:

### tasks/main.yml
以下のタスクを冪等性を保って実装:

1. **タイムゾーン設定**: Asia/Tokyo
2. **chronyインストール・有効化**: NTP同期
3. **システムアップデート**: `dnf update -y`（changed_whenでdiff検知）
4. **必要パッケージインストール**: python3, python3-pip, git, jq, wget
5. **appユーザー作成**: システムユーザー、ホームディレクトリ `/opt/flask-app`
6. **ファイアウォール設定**: firewalld無効化（SG管理のため）

### handlers/main.yml
- chrony再起動ハンドラー

---

## Task 5: nginxロール

`ansible/roles/nginx/` に以下を作成:

### tasks/main.yml

1. **Nginxインストール**: `dnf install nginx -y`
2. **nginx設定ファイルデプロイ**: テンプレートから生成
3. **nginx有効化・起動**: systemdで管理
4. **設定ファイル変更時のreload**: ハンドラー使用

### templates/nginx.conf.j2
```nginx
# Flaskアプリへのリバースプロキシ設定
server {
    listen 80;
    server_name {{ nginx_server_name }};

    # ALBのヘルスチェックパス
    location /api/health {
        proxy_pass {{ nginx_proxy_pass }};
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    location / {
        proxy_pass {{ nginx_proxy_pass }};
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 60s;
    }
}
```

### handlers/main.yml
- nginx reload ハンドラー

---

## Task 6: flask_appロール

`ansible/roles/flask_app/` に以下を作成:

### tasks/main.yml

1. **アプリディレクトリ作成**: `/opt/flask-app`（appユーザー所有）
2. **requirements.txtコピー**
3. **pipパッケージインストール**: Flask, gunicorn, requests
4. **app.pyコピー**
5. **systemdサービスファイルデプロイ**
6. **flask-app有効化・起動**
7. **ヘルスチェック**: `uri`モジュールで `http://localhost/api/health` に3回リトライ

### files/app.py
```python
#!/usr/bin/env python3
"""
Flask API - terraform-ansible-aws-platform
IMDSv2経由でインスタンスメタデータを取得して返す
"""
import os
import requests
from flask import Flask, jsonify

app = Flask(__name__)


def get_imdsv2_token() -> str:
    """IMDSv2トークンを取得（v1は使用しない）"""
    response = requests.put(
        "http://169.254.169.254/latest/api/token",
        headers={"X-aws-ec2-metadata-token-ttl-seconds": "21600"},
        timeout=2,
    )
    return response.text


def get_metadata(path: str) -> str:
    """IMDSv2経由でメタデータを取得"""
    try:
        token = get_imdsv2_token()
        response = requests.get(
            f"http://169.254.169.254/latest/meta-data/{path}",
            headers={"X-aws-ec2-metadata-token": token},
            timeout=2,
        )
        return response.text
    except Exception:
        return "unknown"


@app.route("/")
def index():
    """ルートパス - シンプルなヘルスレスポンス"""
    return jsonify({"message": "terraform-ansible-aws-platform", "status": "ok"})


@app.route("/api/health")
def health():
    """ALBヘルスチェック用エンドポイント"""
    return jsonify({
        "status": "healthy",
        "host": os.uname().nodename,
    })


@app.route("/api/info")
def info():
    """インスタンスメタデータ返却（IMDSv2使用）"""
    return jsonify({
        "instance_id":        get_metadata("instance-id"),
        "availability_zone":  get_metadata("placement/availability-zone"),
        "instance_type":      get_metadata("instance-type"),
        "local_ipv4":         get_metadata("local-ipv4"),
    })


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
```

### templates/flask-app.service.j2
```ini
[Unit]
Description=Flask Platform API
After=network.target

[Service]
Type=simple
User={{ app_user }}
Group={{ app_group }}
WorkingDirectory={{ app_dir }}
ExecStart=/usr/local/bin/gunicorn --workers 2 --bind 0.0.0.0:{{ app_port }} app:app
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

---

## Task 7: メインPlaybook

### ansible/site.yml

```yaml
---
# メインPlaybook - 全ロールを順番に適用
- name: App Server Provisioning
  hosts: role_app
  become: true
  gather_facts: true

  roles:
    - common      # OS基本設定（タイムゾーン、パッケージ等）
    - nginx        # Nginxインストール・リバースプロキシ設定
    - flask_app    # Flaskアプリデプロイ・起動
```

---

## Task 8: Playbook実行

```bash
cd ansible

# Dynamic Inventoryの動作確認
ansible-inventory --list | jq '.role_app.hosts'

# Dry run（変更内容を確認）
ansible-playbook site.yml --check --diff

# 本番実行
ansible-playbook site.yml

# 特定ロールのみ再実行したい場合
ansible-playbook site.yml --tags nginx
ansible-playbook site.yml --tags flask_app
```

---

## 完了基準

- [ ] `ansible-playbook site.yml` がエラーなく完了
- [ ] ALB Target GroupのヘルスチェックがHealthy (2台とも)
- [ ] `curl http://<ALB_DNS>/api/health` で200が返る
- [ ] `curl http://<ALB_DNS>/api/info` でinstance_idが返る（2回叩くと別AZのIDが返る）
- [ ] Playbook再実行時に全タスクが `ok` (changed=0)
- [ ] SSMセッションで `journalctl -u flask-app -f` でアクセスログが確認できる