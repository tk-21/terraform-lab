# ✅Phase 2: Ansible ファイル生成

## Phase 1 からの引き継ぎ情報

- プロジェクトルート: `aws-lsyncd-sync-infra/`
- Terraform apply 済み（EC2 master×1, slave×2 が起動中）
- EC2 秘密鍵: `ansible/keys/ec2_key.pem` が存在する
- EC2 に Tag: Role=master / Role=slave が付与済み

## このフェーズで行うこと

1. Ansible の全設定ファイルを生成する
2. `ansible-lint`（インストール済みの場合）で構文確認する
3. dynamic inventory の疎通確認コマンドを出力する

---

## Step 1: ansible.cfg を生成

`aws-lsyncd-sync-infra/ansible/ansible.cfg`:

```ini
# =============================================================
# ansible.cfg — Ansible 基本設定
# =============================================================

[defaults]
inventory           = inventory/aws_ec2.yml
private_key_file    = keys/ec2_key.pem
remote_user         = ec2-user
host_key_checking   = False
stdout_callback     = yaml
forks               = 5
roles_path          = roles

[privilege_escalation]
become              = True
become_method       = sudo
become_user         = root

[ssh_connection]
# SSH 多重化でパフォーマンス向上
ssh_args            = -o ControlMaster=auto -o ControlPersist=60s
pipelining          = True
```

---

## Step 2: Dynamic Inventory を生成

`aws-lsyncd-sync-infra/ansible/inventory/aws_ec2.yml`:

```yaml
# =============================================================
# aws_ec2.yml — Dynamic Inventory
# EC2 の Tag: Role 値でグループを自動生成する。
#   Tag Role=master → グループ "master"
#   Tag Role=slave  → グループ "slave"
# =============================================================

plugin: amazon.aws.aws_ec2

regions:
  - ap-northeast-1

filters:
  tag:Project: aws-lsyncd-sync-infra
  instance-state-name: running

# Tag: Role の値をそのままグループ名にする
keyed_groups:
  - key: tags.Role
    prefix: ""
    separator: ""

# 接続先 IP（パブリック IP を使用）
hostnames:
  - public-ip-address
```

---

## Step 3: group_vars を生成

`aws-lsyncd-sync-infra/ansible/group_vars/all.yml`:

```yaml
# =============================================================
# group_vars/all.yml — 全ホスト共通変数
# =============================================================

timezone: Asia/Tokyo
web_root: /var/www/html
lsyncd_source_dir: /var/www/html/
lsyncd_log_file: /var/log/lsyncd.log
lsyncd_status_file: /var/run/lsyncd.status

# rsync オプション: アーカイブ・圧縮・削除同期
lsyncd_rsync_opts: "-raz --delete"

# 変更検知から同期開始までの遅延（秒）
# 短すぎると細かい操作ごとに rsync が走り負荷増加
lsyncd_delay: 5

sync_user: ec2-user
lsyncd_ssh_key_path: /home/ec2-user/.ssh/lsyncd_rsa
```

`aws-lsyncd-sync-infra/ansible/group_vars/master.yml`:

```yaml
# =============================================================
# group_vars/master.yml — master 専用変数
# =============================================================

# lsyncd の転送先グループ名（dynamic inventory のグループ名と一致させる）
lsyncd_target_group: slave
```

`aws-lsyncd-sync-infra/ansible/group_vars/slave.yml`:

```yaml
# =============================================================
# group_vars/slave.yml — slave 専用変数
# =============================================================

# rsync 受信ディレクトリ（master の lsyncd_source_dir と一致）
rsync_target_dir: /var/www/html
```

---

## Step 4: roles/common を生成

`aws-lsyncd-sync-infra/ansible/roles/common/tasks/main.yml`:

```yaml
# =============================================================
# roles/common/tasks/main.yml — 共通初期設定（全ホスト適用）
# =============================================================

---
- name: タイムゾーンを JST に設定
  community.general.timezone:
    name: "{{ timezone }}"

- name: システムパッケージを最新化
  ansible.builtin.dnf:
    name: "*"
    state: latest
    update_cache: true

- name: 必須ユーティリティをインストール
  ansible.builtin.dnf:
    name:
      - rsync   # lsyncd の転送バックエンドとして必須
      - curl
      - vim
      - wget
    state: present

- name: /var/www/html ディレクトリを作成
  ansible.builtin.file:
    path: "{{ web_root }}"
    state: directory
    owner: ec2-user
    group: ec2-user
    mode: "0755"
  # ec2-user がオーナー → lsyncd（ec2-user 権限）が書き込み可能
```

---

## Step 5: roles/nginx を生成

`aws-lsyncd-sync-infra/ansible/roles/nginx/tasks/main.yml`:

```yaml
# =============================================================
# roles/nginx/tasks/main.yml — nginx インストール・起動
# master/slave 両方で実行する。
# master でのみ初期 index.html を配置し、slave には lsyncd で同期させる。
# =============================================================

---
- name: nginx をインストール
  ansible.builtin.dnf:
    name: nginx
    state: present

- name: nginx 初期 index.html を配置（master のみ）
  ansible.builtin.template:
    src: index.html.j2
    dest: "{{ web_root }}/index.html"
    owner: ec2-user
    group: ec2-user
    mode: "0644"
  when: inventory_hostname in groups['master']

- name: nginx を起動・自動起動有効化
  ansible.builtin.systemd:
    name: nginx
    state: started
    enabled: true
    daemon_reload: true

- name: nginx の応答を確認
  ansible.builtin.uri:
    url: "http://localhost"
    status_code: 200
  retries: 3
  delay: 5
```

`aws-lsyncd-sync-infra/ansible/roles/nginx/templates/index.html.j2`:

```html
<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="UTF-8">
  <title>aws-lsyncd-sync-infra: {{ inventory_hostname }}</title>
</head>
<body>
  <h1>aws-lsyncd-sync-infra ハンズオン</h1>
  <p>このページは <strong>master</strong> から lsyncd で同期されます。</p>
  <p>ホスト: {{ inventory_hostname }}</p>
  <p>生成日時: {{ ansible_date_time.iso8601 }}</p>
</body>
</html>
```

---

## Step 6: roles/ssh_key_dist を生成

`aws-lsyncd-sync-infra/ansible/roles/ssh_key_dist/tasks/main.yml`:

```yaml
# =============================================================
# roles/ssh_key_dist/tasks/main.yml — lsyncd 用 SSH 鍵配布
#
# 処理フロー:
#   1. master 上で専用 RSA 鍵ペアを生成（パスフレーズなし）
#   2. 公開鍵を Ansible ファクトとして保存
#   3. slave の authorized_keys に公開鍵を追加
#   4. master の known_hosts に slave のホスト鍵を登録
#
# ※ hosts: all で実行し、when 条件で master/slave の処理を分岐する。
#    master と slave を同一プレイで処理しないと hostvars が解決できない。
# =============================================================

---
# --- master での処理 ---
- name: "[master] lsyncd 用 RSA 鍵ペアを生成"
  community.crypto.openssh_keypair:
    path: "{{ lsyncd_ssh_key_path }}"
    type: rsa
    size: 4096
    comment: "lsyncd-sync-key"
    owner: ec2-user
    group: ec2-user
    mode: "0600"
  when: inventory_hostname in groups['master']

- name: "[master] 公開鍵ファイルを読み込む"
  ansible.builtin.slurp:
    src: "{{ lsyncd_ssh_key_path }}.pub"
  when: inventory_hostname in groups['master']
  register: lsyncd_pubkey

- name: "[master] 公開鍵をファクトとして保存（slave への配布用）"
  ansible.builtin.set_fact:
    lsyncd_public_key: "{{ lsyncd_pubkey.content | b64decode | trim }}"
  when: inventory_hostname in groups['master']

# --- slave での処理 ---
- name: "[slave] master の公開鍵を authorized_keys に追加"
  ansible.posix.authorized_key:
    user: ec2-user
    state: present
    key: "{{ hostvars[groups['master'][0]]['lsyncd_public_key'] }}"
    comment: "lsyncd from master"
  when: inventory_hostname in groups['slave']

# --- master: known_hosts への事前登録 ---
- name: "[master] slave のホスト鍵を known_hosts に登録"
  ansible.builtin.known_hosts:
    name: "{{ hostvars[item]['ansible_host'] }}"
    key: "{{ lookup('pipe', 'ssh-keyscan -t rsa ' + hostvars[item]['ansible_host']) }}"
    path: /home/ec2-user/.ssh/known_hosts
    state: present
  loop: "{{ groups['slave'] }}"
  when: inventory_hostname in groups['master']
  # known_hosts 未登録だと lsyncd の rsync が StrictHostKeyChecking でブロックされる
```

---

## Step 7: roles/lsyncd を生成

`aws-lsyncd-sync-infra/ansible/roles/lsyncd/tasks/main.yml`:

```yaml
# =============================================================
# roles/lsyncd/tasks/main.yml — lsyncd インストール・設定・起動
# master にのみ適用（slave への配布は不要）。
#
# lsyncd の動作原理:
#   inotify でソースディレクトリの変更を検知
#   → lsyncd_delay 秒後に rsync over SSH で slave へ転送
# =============================================================

---
- name: EPEL リポジトリを有効化
  ansible.builtin.dnf:
    name: epel-release
    state: present
  when: inventory_hostname in groups['master']

- name: lsyncd をインストール
  ansible.builtin.dnf:
    name: lsyncd
    state: present
  when: inventory_hostname in groups['master']

- name: lsyncd 設定ファイルを配置
  ansible.builtin.template:
    src: lsyncd.conf.j2
    dest: /etc/lsyncd.conf
    owner: root
    group: root
    mode: "0644"
  when: inventory_hostname in groups['master']
  notify: lsyncd を再起動

- name: lsyncd ログファイルを作成
  ansible.builtin.file:
    path: "{{ lsyncd_log_file }}"
    state: touch
    owner: root
    group: root
    mode: "0644"
  when: inventory_hostname in groups['master']

- name: lsyncd を起動・自動起動有効化
  ansible.builtin.systemd:
    name: lsyncd
    state: started
    enabled: true
    daemon_reload: true
  when: inventory_hostname in groups['master']

- name: lsyncd が active であることを確認
  ansible.builtin.command: systemctl is-active lsyncd
  register: lsyncd_status
  failed_when: lsyncd_status.stdout != "active"
  changed_when: false
  when: inventory_hostname in groups['master']
```

`aws-lsyncd-sync-infra/ansible/roles/lsyncd/handlers/main.yml`:

```yaml
---
- name: lsyncd を再起動
  ansible.builtin.systemd:
    name: lsyncd
    state: restarted
```

`aws-lsyncd-sync-infra/ansible/roles/lsyncd/templates/lsyncd.conf.j2`:

```lua
-- =============================================================
-- lsyncd.conf.j2 — lsyncd 設定（Lua 形式）
-- Jinja2 ループで slave 全台分の sync ブロックを自動生成する。
-- slave 台数が変わっても変数変更のみで対応可能。
-- =============================================================

settings {
    logfile        = "{{ lsyncd_log_file }}",
    statusFile     = "{{ lsyncd_status_file }}",
    statusInterval = 10,
    inotifyMode    = "CloseWrite or Modify",
    maxProcesses   = 4,
}

{% for host in groups['slave'] %}
sync {
    default.rsyncssh,

    -- 同期元（末尾 / が必須: ディレクトリ内容を同期）
    source    = "{{ lsyncd_source_dir }}",

    -- 転送先ホスト（VPC 内プライベート IP）
    host      = "{{ hostvars[host]['ansible_host'] }}",
    targetdir = "{{ lsyncd_source_dir }}",

    rsync = {
        -- lsyncd 専用鍵を使用（ec2_key.pem とは別）
        rsh      = "/usr/bin/ssh -i {{ lsyncd_ssh_key_path }} -o StrictHostKeyChecking=no",
        archive  = true,
        compress = true,
        _delete  = true,
    },

    -- 変更検知から同期開始までの遅延（秒）
    delay = {{ lsyncd_delay }},

    exclude = { ".git", "*.swp", "*.tmp" },
}
{% endfor %}
```

---

## Step 8: Playbook を生成

`aws-lsyncd-sync-infra/ansible/playbooks/site.yml`:

```yaml
# =============================================================
# playbooks/site.yml — メインプレイブック
# 実行順序が重要:
#   1. common   → 全ホストの基盤設定
#   2. nginx    → Web サーバーセットアップ
#   3. ssh_key_dist → master で鍵生成 → slave に配布
#      ※ hostvars 解決のため hosts: all で実行する
#   4. lsyncd   → master のみ設定・起動
# =============================================================

---
- name: 共通設定（全ホスト）
  hosts: all
  gather_facts: true
  roles:
    - common

- name: nginx セットアップ（全ホスト）
  hosts: all
  gather_facts: true
  roles:
    - nginx

- name: SSH 鍵配布（全ホスト対象・role 内で master/slave を分岐）
  hosts: all
  gather_facts: true
  roles:
    - ssh_key_dist

- name: lsyncd 設定・起動（master のみ）
  hosts: master
  gather_facts: true
  roles:
    - lsyncd
```

---

## Step 9: CLAUDE.md を生成

`aws-lsyncd-sync-infra/CLAUDE.md` に以下を書き込む:

```markdown
# CLAUDE.md — aws-lsyncd-sync-infra

## プロジェクト概要

Terraform × Ansible × lsyncd による Web コンテンツ自動同期基盤。
master EC2 の `/var/www/html` を slave EC2 × 2 にリアルタイム同期する 1:N 構成。

## ディレクトリ構造

\`\`\`
aws-lsyncd-sync-infra/
├── CLAUDE.md
├── README.md
├── phase1.md                          # Terraform 構築フェーズ
├── phase2.md                          # Ansible 設定フェーズ
├── phase3.md                          # 動作確認フェーズ
├── docs/
│   ├── adr/001-lsyncd-over-nfs.md
│   └── runbook/operations.md
├── terraform/
│   ├── backend.tf
│   ├── variables.tf
│   ├── vpc.tf
│   ├── security_group.tf
│   ├── key_pair.tf
│   ├── ec2.tf
│   └── outputs.tf
└── ansible/
    ├── ansible.cfg
    ├── inventory/aws_ec2.yml
    ├── group_vars/{all,master,slave}.yml
    ├── roles/
    │   ├── common/tasks/main.yml
    │   ├── nginx/{tasks,templates}/
    │   ├── ssh_key_dist/tasks/main.yml
    │   └── lsyncd/{tasks,handlers,templates}/
    └── playbooks/site.yml
\`\`\`

## 実行順序

\`\`\`bash
# Phase 1: Terraform
claude < phase1.md

# Phase 2: Ansible ファイル生成
claude < phase2.md

# Phase 3: 動作確認
claude < phase3.md
\`\`\`

## 設計原則

- リージョン: ap-northeast-1
- SSH 鍵2種類: ec2_key.pem（運用者用）/ lsyncd_rsa（同期用）
- Dynamic Inventory: Tag: Role でグループ自動分類
- OIDC: GitHub Actions はアクセスキー不使用
- コスト目安: ~$32/月（t3.micro × 3）
```

---

## Step 10: 構文確認

```bash
cd aws-lsyncd-sync-infra/ansible

# ansible-lint が使える場合（なければスキップ）
which ansible-lint && ansible-lint playbooks/site.yml || echo "ansible-lint not installed, skipping"

# YAML 構文チェック（python があれば）
python3 -c "import yaml; yaml.safe_load(open('playbooks/site.yml'))" && echo "YAML OK"
python3 -c "import yaml; yaml.safe_load(open('group_vars/all.yml'))" && echo "YAML OK"
python3 -c "import yaml; yaml.safe_load(open('inventory/aws_ec2.yml'))" && echo "YAML OK"
```

---

## Phase 2 完了条件

- [ ] ansible/ 配下の全ファイルが存在する
- [ ] YAML 構文チェックがエラーなし
- [ ] CLAUDE.md が更新されている

## Phase 2 完了後に人間がやること

1. `terraform apply` が完了していることを確認
2. Ansible コレクションのインストール:
   ```bash
   ansible-galaxy collection install amazon.aws community.general community.crypto ansible.posix
   pip install boto3 botocore
   ```
3. dynamic inventory の疎通確認:
   ```bash
   cd ansible
   ansible-inventory -i inventory/aws_ec2.yml --graph
   # 出力例:
   # @all:
   #   |--@master:
   #   |  |--<master-public-ip>
   #   |--@slave:
   #   |  |--<slave-1-public-ip>
   #   |  |--<slave-2-public-ip>
   ```
4. `ansible-playbook playbooks/site.yml` を実行

## 次フェーズへの引き継ぎ情報

Phase 3 に渡す情報:
- `terraform output verify_commands` で動作確認コマンドを取得すること
- lsyncd_delay のデフォルトは 5 秒（同期確認時は 5 秒以上待つ）
- ログ確認: master で `sudo tail -f /var/log/lsyncd.log`