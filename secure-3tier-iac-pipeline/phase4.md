# ✅Phase 4: Ansible 完全実装
# (動的インベントリ / OS強化 / アプリデプロイ / ドリフト検出)

## Phase 1-3 で構築済みの前提
- EC2 インスタンス (Amazon Linux 2023, arm64, プライベートサブネット)
- IAM インスタンスプロファイル: s3t-prod-ec2-profile (SSM権限付き)
- VPCエンドポイント: SSM/SSMMessages/EC2Messages 設定済み
- EC2タグ: Role=webserver, Project=secure-3tier-iac-pipeline, Environment=prod
- SSM Parameter Store: /ata-prod/app/ 以下に DB接続情報あり
- Secrets Manager: ata-prod/rds/master-password にDBパスワードあり

---

## このフェーズで実装するもの
1. Ansible 動的インベントリ (aws_ec2 プラグイン + SSM接続)
2. Ansible Vault でのシークレット管理
3. os_hardening ロール (CIS Level 1 準拠)
4. app_deploy ロール (Nginx + Python アプリ + systemd)
5. drift_detection ロール (設定ドリフト検出・Chatworkレポート)
6. EventBridge + Lambda によるドリフト検出スケジューリング

---

## Step 1: 動的インベントリ設定

`ansible/inventories/aws_ec2.yml` を作成:

```yaml
# [設計意図] タグベースの動的グループ形成。EC2を追加するだけで自動的にインベントリに追加される
plugin: amazon.aws.aws_ec2
regions:
  - ap-northeast-1

# EC2タグでフィルタリング
filters:
  tag:Project: "secure-3tier-iac-pipeline"
  tag:Environment: "prod"
  instance-state-name: running

# [上級] タグからグループを自動生成
keyed_groups:
  - key: tags.Role
    prefix: role
    separator: "_"
  - key: tags.Environment
    prefix: env
    separator: "_"
  - key: placement.availability_zone
    prefix: az
    separator: "_"

# グループ名: role_webserver, env_prod, az_ap-northeast-1a 等が自動生成される
groups:
  webservers: "'webserver' in tags.Role"
  prod: "'prod' in tags.Environment"

# [セキュリティ] SSH不使用。SSM Session Manager経由で接続
compose:
  ansible_host: instance_id  # IPアドレスではなくインスタンスIDを使用
  ansible_connection: "aws_ssm"
  ansible_aws_ssm_region: "ap-northeast-1"
  ansible_aws_ssm_bucket_name: "s3t-prod-session-logs-{{ account_id }}"

# キャッシュ設定 (API呼び出し削減)
cache: true
cache_plugin: jsonfile
cache_connection: /tmp/aws_ec2_cache
cache_timeout: 300  # 5分
```

`ansible/ansible.cfg` を作成:

```ini
[defaults]
inventory          = inventories/aws_ec2.yml
remote_user        = ec2-user
private_key_file   =                    # SSM接続なので不要
host_key_checking  = False
stdout_callback    = yaml
callbacks_enabled  = timer, profile_tasks  # 実行時間プロファイリング
retry_files_enabled = False

[ssh_connection]
# SSM接続設定
ssh_executable = /usr/bin/ssh

[privilege_escalation]
become      = True
become_method = sudo
become_user = root
```

---

## Step 2: Ansible Vault 設定

`ansible/group_vars/all/vault.yml` を作成 (内容はプレースホルダー、実際は ansible-vault で暗号化):

```yaml
# このファイルは ansible-vault encrypt で暗号化すること
# 実行例: ansible-vault encrypt group_vars/all/vault.yml

# [設計意図] Secrets ManagerのパスワードはAnsible Vault経由で注入
# 実際のパスワードはデプロイ時に CI/CD から vault パスワードを渡す
vault_db_password: "{{ lookup('aws_secret', 'ata-prod/rds/master-password', region='ap-northeast-1') }}"
vault_app_secret_key: "CHANGE_ME_IN_VAULT"
```

`ansible/group_vars/all/vars.yml` を作成:

```yaml
# プロジェクト共通変数
project_name: "secure-3tier-iac-pipeline"
environment: "prod"
aws_region: "ap-northeast-1"

# アプリケーション設定
app_user: "appuser"
app_group: "appgroup"
app_dir: "/opt/app"
app_port: 8080

# DB接続情報 (SSM Parameter Storeから取得)
db_endpoint: "{{ lookup('aws_ssm', '/ata-prod/app/db_endpoint', region=aws_region) }}"
db_reader_endpoint: "{{ lookup('aws_ssm', '/ata-prod/app/db_reader_endpoint', region=aws_region) }}"
db_port: "{{ lookup('aws_ssm', '/ata-prod/app/db_port', region=aws_region) }}"
db_name: "{{ lookup('aws_ssm', '/ata-prod/app/db_name', region=aws_region) }}"
db_password: "{{ vault_db_password }}"
```

---

## Step 3: os_hardening ロール (CIS Benchmark Level 1)

`ansible/roles/os_hardening/` を以下の構成で作成:
- `tasks/main.yml`
- `tasks/kernel.yml`
- `tasks/users.yml`
- `tasks/services.yml`
- `tasks/audit.yml`
- `handlers/main.yml`
- `defaults/main.yml`

### tasks/main.yml

```yaml
---
# [セキュリティ] CIS Amazon Linux 2023 Benchmark Level 1 準拠
# 参考: https://www.cisecurity.org/benchmark/amazon_linux

- name: カーネルパラメータのハードニング
  import_tasks: kernel.yml
  tags: [hardening, kernel]

- name: ユーザーとアクセス制御のハードニング
  import_tasks: users.yml
  tags: [hardening, users]

- name: 不要サービスの無効化
  import_tasks: services.yml
  tags: [hardening, services]

- name: auditd 設定
  import_tasks: audit.yml
  tags: [hardening, audit]
```

### tasks/kernel.yml

```yaml
---
# [セキュリティ] ネットワーク関連カーネルパラメータの強化

- name: sysctl ハードニングパラメータ適用
  ansible.posix.sysctl:
    name: "{{ item.key }}"
    value: "{{ item.value }}"
    state: present
    reload: true
    sysctl_file: /etc/sysctl.d/99-hardening.conf
  loop:
    # IPスプーフィング防止
    - { key: "net.ipv4.conf.all.rp_filter", value: "1" }
    - { key: "net.ipv4.conf.default.rp_filter", value: "1" }
    # ICMPリダイレクト受信拒否
    - { key: "net.ipv4.conf.all.accept_redirects", value: "0" }
    - { key: "net.ipv4.conf.default.accept_redirects", value: "0" }
    - { key: "net.ipv6.conf.all.accept_redirects", value: "0" }
    # ソースルーティング無効
    - { key: "net.ipv4.conf.all.accept_source_route", value: "0" }
    # SYN flood対策
    - { key: "net.ipv4.tcp_syncookies", value: "1" }
    # IPフォワーディング無効 (ルーターではないため)
    - { key: "net.ipv4.ip_forward", value: "0" }
    # ICMP broadcast応答無効
    - { key: "net.ipv4.icmp_echo_ignore_broadcasts", value: "1" }
    # コアダンプ無効 (メモリ内シークレット漏洩防止)
    - { key: "fs.suid_dumpable", value: "0" }
    # ASLR有効
    - { key: "kernel.randomize_va_space", value: "2" }
  changed_when: true
  notify: sysctl再読み込み

- name: /proc/sys/kernel/dmesg_restrict を制限
  ansible.posix.sysctl:
    name: kernel.dmesg_restrict
    value: "1"
    state: present
    sysctl_file: /etc/sysctl.d/99-hardening.conf
  changed_when: true
```

### tasks/users.yml

```yaml
---
- name: パスワードポリシー設定 (pwquality)
  ansible.builtin.lineinfile:
    path: /etc/security/pwquality.conf
    regexp: "^{{ item.key }}"
    line: "{{ item.key }} = {{ item.value }}"
    state: present
  loop:
    - { key: "minlen", value: "14" }
    - { key: "dcredit", value: "-1" }
    - { key: "ucredit", value: "-1" }
    - { key: "ocredit", value: "-1" }
    - { key: "lcredit", value: "-1" }
  changed_when: true

- name: rootの直接ログイン無効化 (/etc/securetty)
  ansible.builtin.file:
    path: /etc/securetty
    state: touch
    mode: "0600"
    owner: root
    group: root

- name: アプリ実行ユーザー作成 (ログインシェルなし)
  ansible.builtin.user:
    name: "{{ app_user }}"
    group: "{{ app_group }}"
    system: true
    shell: /sbin/nologin
    home: "{{ app_dir }}"
    create_home: false
  changed_when: true

- name: sudoers 設定強化
  ansible.builtin.lineinfile:
    path: /etc/sudoers
    regexp: "^Defaults.*requiretty"
    line: "Defaults requiretty"
    state: present
    validate: "visudo -cf %s"
```

### tasks/services.yml

```yaml
---
# [セキュリティ] 不要サービスを無効化して攻撃面を最小化

- name: 不要サービスの無効化と停止
  ansible.builtin.systemd:
    name: "{{ item }}"
    state: stopped
    enabled: false
    masked: true  # [上級] masked=trueで他のサービスからの起動も防ぐ
  loop:
    - bluetooth
    - cups
    - avahi-daemon
    - rpcbind
    - nfs
  failed_when: false  # サービスが存在しない場合はスキップ
  changed_when: true

- name: SELinux ステータス確認
  ansible.builtin.command: getenforce
  register: selinux_status
  changed_when: false
  check_mode: false

- name: SELinux が Enforcing でない場合に警告
  ansible.builtin.debug:
    msg: "[警告] SELinux が Enforcing ではありません: {{ selinux_status.stdout }}. 本番環境では Enforcing を推奨"
  when: selinux_status.stdout != "Enforcing"
```

### tasks/audit.yml

```yaml
---
# [セキュリティ] auditd でシステムコール・ファイルアクセスを監査ログに記録

- name: auditd インストール
  ansible.builtin.dnf:
    name: audit
    state: present

- name: auditd ルール設定
  ansible.builtin.copy:
    dest: /etc/audit/rules.d/99-hardening.rules
    content: |
      # [セキュリティ] 権限昇格の監査
      -a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=unset -k privilege_escalation
      # passwd, shadow ファイルへのアクセス
      -w /etc/passwd -p wa -k identity
      -w /etc/shadow -p wa -k identity
      -w /etc/group -p wa -k identity
      -w /etc/sudoers -p wa -k sudoers_changes
      # ネットワーク設定変更
      -a always,exit -F arch=b64 -S sethostname -S setdomainname -k system_locale
      # ファイル削除の監査
      -a always,exit -F arch=b64 -S unlink -S unlinkat -S rename -S renameat -F auid>=1000 -F auid!=unset -k delete
      # ルール変更を禁止 (改ざん防止)
      -e 2
    mode: "0640"
    owner: root
    group: root
  notify: auditd再起動

- name: auditd サービス有効化
  ansible.builtin.systemd:
    name: auditd
    state: started
    enabled: true
```

### handlers/main.yml

```yaml
---
- name: sysctl再読み込み
  ansible.builtin.command: sysctl --system
  changed_when: true

- name: auditd再起動
  ansible.builtin.systemd:
    name: auditd
    state: restarted
```

---

## Step 4: app_deploy ロール

`ansible/roles/app_deploy/` を作成:
- `tasks/main.yml`
- `tasks/nginx.yml`
- `tasks/python_app.yml`
- `tasks/systemd_service.yml`
- `templates/app.conf.j2`
- `templates/app_service.j2`
- `templates/app_config.j2`
- `handlers/main.yml`

### tasks/main.yml

```yaml
---
- name: Nginx インストールと設定
  import_tasks: nginx.yml
  tags: [deploy, nginx]

- name: Python アプリデプロイ
  import_tasks: python_app.yml
  tags: [deploy, app]

- name: systemd サービス設定
  import_tasks: systemd_service.yml
  tags: [deploy, systemd]
```

### tasks/nginx.yml

```yaml
---
- name: Nginx インストール
  ansible.builtin.dnf:
    name: nginx
    state: present

- name: Nginx 設定ファイル配置
  ansible.builtin.template:
    src: app.conf.j2
    dest: /etc/nginx/conf.d/app.conf
    owner: root
    group: root
    mode: "0644"
    validate: "nginx -t -c /etc/nginx/nginx.conf"  # [上級] デプロイ前に構文チェック
  notify: nginx再起動

- name: Nginx サービス有効化
  ansible.builtin.systemd:
    name: nginx
    state: started
    enabled: true
```

### templates/app.conf.j2

```nginx
# {{ ansible_managed }}
# [設計意図] Nginxはリバースプロキシとして動作。アプリは8080で待受
server {
    listen 80;
    server_name _;

    # セキュリティヘッダー
    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # サーバーバージョン非表示
    server_tokens off;

    location /health {
        access_log off;
        return 200 'ok\n';
        add_header Content-Type text/plain;
    }

    location / {
        proxy_pass http://127.0.0.1:{{ app_port }};
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 30s;
        proxy_read_timeout 60s;
    }
}
```

### tasks/python_app.yml

```yaml
---
- name: Python 3.11 と依存パッケージのインストール
  ansible.builtin.dnf:
    name:
      - python3.11
      - python3.11-pip
    state: present

- name: アプリグループ作成
  ansible.builtin.group:
    name: "{{ app_group }}"
    system: true

- name: アプリディレクトリ作成
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    owner: "{{ app_user }}"
    group: "{{ app_group }}"
    mode: "0750"
  loop:
    - "{{ app_dir }}"
    - "{{ app_dir }}/logs"
    - "{{ app_dir }}/config"

- name: アプリ設定ファイル配置
  ansible.builtin.template:
    src: app_config.j2
    dest: "{{ app_dir }}/config/app.cfg"
    owner: "{{ app_user }}"
    group: "{{ app_group }}"
    mode: "0640"  # グループ読み取り可、その他不可
  notify: アプリ再起動

- name: requirements.txt 配置
  ansible.builtin.copy:
    dest: "{{ app_dir }}/requirements.txt"
    content: |
      flask==3.0.3
      gunicorn==22.0.0
      boto3==1.34.69
      pymysql==1.1.1
    owner: "{{ app_user }}"
    group: "{{ app_group }}"
    mode: "0644"

- name: pip パッケージインストール (virtualenv)
  ansible.builtin.pip:
    requirements: "{{ app_dir }}/requirements.txt"
    virtualenv: "{{ app_dir }}/venv"
    virtualenv_python: python3.11
  become_user: "{{ app_user }}"
```

### templates/app_config.j2

```ini
# {{ ansible_managed }}
# [設計意図] DB接続情報はSSM Parameter StoreとSecrets Managerから取得
[database]
host = {{ db_endpoint }}
reader_host = {{ db_reader_endpoint }}
port = {{ db_port }}
name = {{ db_name }}
password = {{ db_password }}

[app]
secret_key = {{ vault_app_secret_key }}
port = {{ app_port }}
environment = {{ environment }}
```

### tasks/systemd_service.yml

```yaml
---
- name: systemd サービスユニット配置
  ansible.builtin.template:
    src: app_service.j2
    dest: /etc/systemd/system/webapp.service
    owner: root
    group: root
    mode: "0644"
  notify:
    - systemd daemon-reload
    - アプリ再起動

- name: webapp サービス有効化
  ansible.builtin.systemd:
    name: webapp
    state: started
    enabled: true
    daemon_reload: true
```

### templates/app_service.j2

```ini
[Unit]
Description=Web Application ({{ project_name }})
After=network.target
Wants=network.target

[Service]
Type=notify
User={{ app_user }}
Group={{ app_group }}
WorkingDirectory={{ app_dir }}
ExecStart={{ app_dir }}/venv/bin/gunicorn \
    --bind 127.0.0.1:{{ app_port }} \
    --workers 2 \
    --timeout 60 \
    --access-logfile {{ app_dir }}/logs/access.log \
    --error-logfile {{ app_dir }}/logs/error.log \
    app:create_app()

# [セキュリティ] systemd サービスのサンドボックス設定
PrivateTmp=true
PrivateDevices=true
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths={{ app_dir }}/logs {{ app_dir }}/config

Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

---

## Step 5: drift_detection ロール

`ansible/roles/drift_detection/` を作成。

### tasks/main.yml

```yaml
---
# [設計意図] --check モードで実行し変更が必要なタスクを検出、レポートとしてChatworkに送信

- name: ドリフト検出実行 (check mode)
  # このロールは --check で呼ばれることを想定
  # 実際の変更は行わない
  block:
    - name: Nginx 設定ドリフト確認
      ansible.builtin.template:
        src: "{{ role_path }}/../app_deploy/templates/app.conf.j2"
        dest: /etc/nginx/conf.d/app.conf
        owner: root
        group: root
        mode: "0644"
      check_mode: true
      register: nginx_config_drift
      changed_when: false

    - name: アプリ設定ドリフト確認
      ansible.builtin.template:
        src: "{{ role_path }}/../app_deploy/templates/app_config.j2"
        dest: "{{ app_dir }}/config/app.cfg"
      check_mode: true
      register: app_config_drift
      changed_when: false

    - name: セキュリティグループ設定ドリフト確認 (sysctl)
      ansible.builtin.command:
        cmd: sysctl net.ipv4.conf.all.rp_filter
      register: sysctl_check
      changed_when: false
      check_mode: false

    - name: ドリフト結果を集約
      ansible.builtin.set_fact:
        drift_results:
          timestamp: "{{ ansible_date_time.iso8601 }}"
          host: "{{ inventory_hostname }}"
          nginx_config_drifted: "{{ nginx_config_drift.changed }}"
          app_config_drifted: "{{ app_config_drift.changed }}"
          sysctl_rp_filter: "{{ sysctl_check.stdout }}"
          drift_detected: "{{ nginx_config_drift.changed or app_config_drift.changed }}"

    - name: Chatwork にドリフトレポートを送信
      ansible.builtin.uri:
        url: "https://api.chatwork.com/v2/rooms/{{ chatwork_room_id }}/messages"
        method: POST
        headers:
          X-ChatWorkToken: "{{ vault_chatwork_token }}"
        body_format: form-urlencoded
        body:
          body: |
            [info][title]🔍 設定ドリフト検出レポート[/title]
            ホスト: {{ drift_results.host }}
            検出時刻: {{ drift_results.timestamp }}
            ドリフト検出: {{ '⚠️ あり' if drift_results.drift_detected else '✅ なし' }}

            Nginx設定: {{ '変更あり' if drift_results.nginx_config_drifted else '正常' }}
            アプリ設定: {{ '変更あり' if drift_results.app_config_drifted else '正常' }}
            sysctl rp_filter: {{ drift_results.sysctl_rp_filter }}
            [/info]
        status_code: 200
      when: drift_results.drift_detected or force_notify | default(false)
      delegate_to: localhost  # CWへの通知はローカルから
      run_once: true          # 複数ホストでも通知は1回
```

---

## Step 6: Playbook 作成

### ansible/site.yml (フルデプロイ)

```yaml
---
- name: OS ハードニング
  hosts: role_webserver
  gather_facts: true
  roles:
    - os_hardening

- name: アプリデプロイ
  hosts: role_webserver
  gather_facts: true
  roles:
    - app_deploy
```

### ansible/drift_check.yml (ドリフト検出専用)

```yaml
---
- name: 設定ドリフト検出
  hosts: role_webserver
  gather_facts: true
  check_mode: true  # [上級] Playbook全体をcheck modeで実行
  roles:
    - drift_detection
```

---

## Step 7: 実行スクリプト

`scripts/run_ansible.sh` を作成:

```bash
#!/bin/bash
# SSM Session Manager 経由での Ansible 実行スクリプト
set -euo pipefail

PLAYBOOK="${1:-site.yml}"
VAULT_PASSWORD_FILE="${VAULT_PASSWORD_FILE:-~/.vault_pass}"
ANSIBLE_DIR="$(cd "$(dirname "$0")/../ansible" && pwd)"

echo "=== Ansible 実行開始: ${PLAYBOOK} ==="
echo "対象環境: prod (ap-northeast-1)"

# 動的インベントリの確認
echo "--- インベントリ確認 ---"
cd "${ANSIBLE_DIR}"
ansible-inventory -i inventories/aws_ec2.yml --list | jq '.role_webserver.hosts // [] | length' | \
  xargs -I{} echo "対象ホスト数: {}"

# Playbook 実行
ansible-playbook \
  -i inventories/aws_ec2.yml \
  --vault-password-file "${VAULT_PASSWORD_FILE}" \
  --diff \
  "${PLAYBOOK}"

echo "=== 完了 ==="
```

`scripts/run_drift_check.sh` を作成 (EventBridgeから呼ばれるLambda用のコマンド):

```bash
#!/bin/bash
# ドリフト検出専用スクリプト (定期実行想定)
set -euo pipefail

cd "$(dirname "$0")/../ansible"
ansible-playbook \
  -i inventories/aws_ec2.yml \
  --vault-password-file "${VAULT_PASSWORD_FILE:-~/.vault_pass}" \
  --check \
  --diff \
  drift_check.yml
```

---

## Step 8: Vault 変数に Chatwork トークンを追加

`ansible/group_vars/all/vault.yml` に追記:
```yaml
vault_chatwork_token: "YOUR_CHATWORK_API_TOKEN"  # ansible-vault で暗号化
chatwork_room_id: "YOUR_ROOM_ID"
```

---

## 完了条件
- [ ] `ansible-inventory --list` で `role_webserver` グループにEC2インスタンスが表示される
- [ ] `ansible-playbook site.yml --check` がエラーなく完了する
- [ ] os_hardening ロールの全タスクに `changed_when` または `failed_when` が明示されている
- [ ] app_deploy のテンプレートに `{{ ansible_managed }}` ヘッダーがある
- [ ] drift_detection ロールが `check_mode: true` で実行される
- [ ] Chatwork への通知が `delegate_to: localhost` で実行される
- [ ] vault.yml が Ansible Vault で暗号化されている (ansible-vault encrypt 済み)
- [ ] `ansible-lint` 警告が最小限

## プロジェクト全体の完了後チェックリスト
- [ ] `terraform plan` で変更差分ゼロ (drift なし)
- [ ] SSM Session Manager でEC2に接続できる (SSH不要)
- [ ] ALB DNS 経由で /health エンドポイントに200が返る
- [ ] Aurora に EC2 から接続できる (SSH トンネル不要)
- [ ] Secrets Manager のパスワードローテーションが成功している
- [ ] VPC Flow Logs が CloudWatch に記録されている
- [ ] drift_check.yml を実行するとChatworkにレポートが届く