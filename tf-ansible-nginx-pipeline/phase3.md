# ✅Phase 3: Ansible Role設計

## このフェーズで達成すること

「動くPlaybook」から「冪等で安全なRole」へ。
Dynamic Inventory、エラーハンドリング設計、Moleculeによるテストを実装する。

## Phase 2からの引き継ぎ

- EC2インスタンスが `Role=web` タグで起動済み
- SSMパラメータ `/${name_prefix}/nginx/*` が作成済み
- SSMセッションマネージャーでアクセス可能な状態

---

## Task 3-1: Dynamic Inventory設定ファイルの生成

`ansible/inventory/aws_ec2.yml` を作成してください:

```yaml
# =============================================================================
# AWS EC2 Dynamic Inventory設定
# 設計思想: IPアドレスやホスト名をハードコードせず、AWSタグで対象を動的に解決する
# これにより、インスタンスの再作成・スケールアウト時も inventory の修正が不要になる
# =============================================================================

plugin: aws_ec2
regions:
  - ap-northeast-1

# フィルタリング: Terraformで付与したタグで対象を絞り込む
filters:
  tag:AnsibleManaged: "true"
  instance-state-name: running

# ホスト変数: インスタンスの属性をAnsible変数として自動設定
hostnames:
  - instance-id  # SSMセッションマネージャーはinstance-idで接続するため

# グループ化: タグ値でグループを自動生成
keyed_groups:
  - key: tags.Role        # Role=web → グループ名 "web"
    prefix: ""
    separator: ""
  - key: tags.Environment # Environment=dev → グループ名 "dev"
    prefix: "env_"

# 接続設定: SSHではなくSSMセッションマネージャーを使用
compose:
  ansible_host: instance_id
  ansible_connection: "aws_ssm"
  ansible_aws_ssm_region: "ap-northeast-1"
```

---

## Task 3-2: ansible.cfg の生成

`ansible/ansible.cfg` を作成してください:

```ini
[defaults]
# インベントリのデフォルトパス
inventory = ./inventory/aws_ec2.yml

# SSH接続を使わないためhost_key_checkingは無効
# （SSMセッションマネージャー使用のため、そもそもSSH不使用）
host_key_checking = False

# 実行ログのタイムスタンプ付与
log_path = /tmp/ansible.log

# タスク実行の並列数（デフォルト5）
forks = 10

# changed/failedのサマリーをカラー表示
stdout_callback = yaml

[ssh_connection]
# SSMセッションマネージャー接続設定
# pipeliningを有効にすることでsudo実行のパフォーマンスが向上
pipelining = True

[privilege_escalation]
# EC2デフォルトユーザーからrootへのエスカレーション
become = True
become_method = sudo
become_user = root
```

---

## Task 3-3: nginxロールのディレクトリ構造と全ファイルの生成

### `ansible/roles/nginx/defaults/main.yml`

```yaml
# =============================================================================
# デフォルト変数（最低優先度）
# 設計思想: ここに書いた値は全環境での「デフォルト」
# 環境ごとの上書きは group_vars/env_dev.yml で行う
# Ansible変数優先順位: role defaults < group_vars < host_vars < extra_vars
# =============================================================================

nginx_port: 80
nginx_worker_processes: "auto"
nginx_worker_connections: 1024

# nginxバージョン固定しない（最新安定版を使う）
# 理由: セキュリティパッチを自動的に取得するため
nginx_package: nginx

# コンテンツルートのパス
nginx_document_root: /var/www/html

# ログパス
nginx_access_log: /var/log/nginx/access.log
nginx_error_log: /var/log/nginx/error.log
```

### `ansible/roles/nginx/tasks/main.yml`

```yaml
# =============================================================================
# nginxロール メインタスク
# 設計思想:
#   1. changed_when / failed_when で冪等性を明示的に制御する
#   2. block/rescue/always でエラーハンドリングを構造化する
#   3. handlerで「変更があったときだけ」サービスを再起動する
# =============================================================================

---
- name: SSMパラメータからnginx設定値を取得
  # 設計思想: 設定値はSSMパラメータから動的に取得し、Ansibleのvarsへの
  # ハードコードを避ける。Terraformが設定値の信頼できる唯一の情報源となる。
  amazon.aws.aws_ssm_parameter_facts:
    names:
      - "/handson-dev/nginx/port"
      - "/handson-dev/nginx/worker_processes"
    region: ap-northeast-1
  register: ssm_params
  # このタスクはSSM APIを読み取るだけなので常にchangedにならない
  changed_when: false

- name: SSMパラメータ値を変数にセット
  ansible.builtin.set_fact:
    nginx_port: "{{ ssm_params.parameters['/handson-dev/nginx/port'] | int }}"
    nginx_worker_processes: "{{ ssm_params.parameters['/handson-dev/nginx/worker_processes'] }}"

- name: nginxインストールと設定のブロック
  block:
    - name: nginxパッケージのインストール
      ansible.builtin.dnf:
        name: "{{ nginx_package }}"
        state: present
      # dnfは冪等: すでにインストール済みなら changed=false になる

    - name: ドキュメントルートディレクトリの作成
      ansible.builtin.file:
        path: "{{ nginx_document_root }}"
        state: directory
        owner: nginx
        group: nginx
        mode: "0755"

    - name: nginx設定ファイルのデプロイ
      ansible.builtin.template:
        src: nginx.conf.j2
        dest: /etc/nginx/nginx.conf
        owner: root
        group: root
        mode: "0644"
        # validate: 設定ファイルのデプロイ前にnginx -tで構文チェック
        validate: nginx -t -c %s
      notify: nginx reload
      # notifyの設計思想: 設定ファイルが変更されたときだけreloadする
      # 変更がなければhandlerは実行されない → 不要なサービス再起動を防ぐ

    - name: インデックスページのデプロイ
      ansible.builtin.template:
        src: index.html.j2
        dest: "{{ nginx_document_root }}/index.html"
        owner: nginx
        group: nginx
        mode: "0644"

    - name: nginxサービスの有効化と起動
      ansible.builtin.systemd:
        name: nginx
        state: started
        enabled: true
      # systemdモジュールは冪等: 起動済みなら changed=false

  rescue:
    # エラー発生時: nginxのエラーログを収集してから失敗させる
    - name: nginxエラーログを収集（デバッグ用）
      ansible.builtin.command: journalctl -u nginx --no-pager -n 50
      register: nginx_journal
      changed_when: false  # ログ取得はシステム状態を変更しない

    - name: エラーログを表示
      ansible.builtin.debug:
        msg: "{{ nginx_journal.stdout_lines }}"

    - name: 失敗を明示的に伝播させる
      ansible.builtin.fail:
        msg: "nginxのインストール/設定に失敗しました。上記のログを確認してください。"

  always:
    # 成功・失敗に関わらず: nginx設定の検証結果を記録
    - name: nginx設定検証ステータスの確認
      ansible.builtin.command: nginx -t
      register: nginx_config_test
      changed_when: false
      failed_when: false  # alwaysブロック内では失敗しても処理を継続

    - name: nginx設定検証結果をログ出力
      ansible.builtin.debug:
        msg: "nginx -t result: {{ nginx_config_test.rc == 0 | ternary('OK', 'FAILED') }}"
```

### `ansible/roles/nginx/handlers/main.yml`

```yaml
# =============================================================================
# ハンドラー
# 設計思想: ハンドラーは「タスクの変更があったときだけ実行」される
# 同じハンドラーが複数のタスクからnotifyされても、1回だけ実行される
# これにより不必要なサービス再起動を防ぎ、冪等性を確保する
# =============================================================================

---
- name: nginx reload
  ansible.builtin.systemd:
    name: nginx
    state: reloaded
  # reloadとrestartの使い分け:
  # reload: 設定ファイルの再読み込み（接続を切断しない）← nginx設定変更時はこちら
  # restart: プロセスの再起動（接続が一時的に切断される）← バイナリ更新時のみ使用
```

### `ansible/roles/nginx/templates/nginx.conf.j2`

```nginx
# Ansible管理ファイル: 手動編集禁止
# 生成元: roles/nginx/templates/nginx.conf.j2
# 変数はSSMパラメータから取得

user nginx;
worker_processes {{ nginx_worker_processes }};
error_log {{ nginx_error_log }} warn;
pid /run/nginx.pid;

events {
    worker_connections {{ nginx_worker_connections }};
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    access_log {{ nginx_access_log }} main;

    sendfile        on;
    keepalive_timeout  65;

    server {
        listen       {{ nginx_port }};
        server_name  _;
        root         {{ nginx_document_root }};
        index        index.html;

        location / {
            try_files $uri $uri/ =404;
        }

        # ヘルスチェックエンドポイント（ALBターゲットグループ用）
        location /health {
            access_log off;
            return 200 "OK\n";
            add_header Content-Type text/plain;
        }
    }
}
```

### `ansible/roles/nginx/templates/index.html.j2`

```html
<!DOCTYPE html>
<html>
<head><title>{{ inventory_hostname }}</title></head>
<body>
  <h1>Ansible管理によるnginx</h1>
  <p>ホスト: {{ inventory_hostname }}</p>
  <p>nginxポート: {{ nginx_port }}</p>
  <p>デプロイ日時: {{ ansible_date_time.iso8601 }}</p>
</body>
</html>
```

---

## Task 3-4: Molecule テスト設定の生成

`ansible/roles/nginx/molecule/default/molecule.yml`:

```yaml
# =============================================================================
# Molecule設定: nginxロールの単体テスト
# 設計思想:
#   1. Dockerを使いAWS不要でロールをテストする（CI/CDコスト削減）
#   2. converge → idempotency → verify の3段階で品質を保証する
#   3. idempotencyチェックで「2回実行してもchanged=0」を自動検証する
# =============================================================================

dependency:
  name: galaxy

driver:
  name: docker

platforms:
  - name: nginx-test
    # Amazon Linux 2023に近いイメージを使用
    image: amazonlinux:2023
    pre_build_image: true
    # systemdを使用するための設定
    command: /usr/sbin/init
    privileged: true
    volumes:
      - /sys/fs/cgroup:/sys/fs/cgroup:ro
    tmpfs:
      - /run
      - /tmp

provisioner:
  name: ansible
  config_options:
    defaults:
      stdout_callback: yaml
  # SSMパラメータ取得をモック化するための変数上書き
  inventory:
    host_vars:
      nginx-test:
        ansible_connection: local
        # テスト環境ではSSMパラメータ取得をスキップし、defaultsの値を使用
        skip_ssm_fetch: true

verifier:
  name: ansible

scenario:
  test_sequence:
    - dependency
    - create
    - converge
    - idempotency   # ← 2回目実行でchanged=0を確認する重要なステップ
    - verify
    - destroy
```

`ansible/roles/nginx/molecule/default/converge.yml`:

```yaml
---
- name: Converge
  hosts: all
  roles:
    - role: nginx
```

`ansible/roles/nginx/molecule/default/verify.yml`:

```yaml
# =============================================================================
# 検証タスク: Roleが期待通りの状態を作っているかを確認する
# =============================================================================

---
- name: Verify
  hosts: all
  tasks:
    - name: nginxパッケージがインストールされていること
      ansible.builtin.package_facts:
        manager: auto

    - name: nginxパッケージの存在確認
      ansible.builtin.assert:
        that: "'nginx' in ansible_facts.packages"
        fail_msg: "nginxパッケージがインストールされていません"
        success_msg: "nginxパッケージのインストール確認OK"

    - name: nginxサービスが起動していること
      ansible.builtin.service_facts:

    - name: nginxサービスのステータス確認
      ansible.builtin.assert:
        that: "ansible_facts.services['nginx.service'].state == 'running'"
        fail_msg: "nginxサービスが起動していません"

    - name: nginx設定ファイルの構文チェック
      ansible.builtin.command: nginx -t
      changed_when: false

    - name: ポート80でHTTPレスポンスが返ること
      ansible.builtin.uri:
        url: "http://localhost:80/health"
        status_code: 200
      register: health_check

    - name: ヘルスチェックレスポンス確認
      ansible.builtin.assert:
        that: "health_check.status == 200"
        fail_msg: "ヘルスチェックエンドポイントが応答しません"
```

---

## Task 3-5: サイトPlaybookの生成

`ansible/site.yml`:

```yaml
---
# =============================================================================
# サイトPlaybook: インフラ全体のエントリーポイント
# 設計思想: site.ymlはインポートのみで、実処理はRoleに委譲する
# =============================================================================

- name: Webサーバー構成
  hosts: web          # Dynamic Inventoryで生成されるグループ名
  gather_facts: true

  pre_tasks:
    - name: 接続確認（SSMセッションマネージャー経由）
      ansible.builtin.ping:

  roles:
    - nginx

  post_tasks:
    - name: デプロイ完了確認
      ansible.builtin.uri:
        url: "http://localhost/health"
        status_code: 200
      changed_when: false
```

---

## Phase 3 実行コマンド

```bash
# Moleculeによるロール単体テスト
cd ansible
pip install molecule molecule-docker ansible-lint

# 全テストシーケンスの実行
molecule test

# 個別ステップ実行（開発時）
molecule create       # コンテナ作成
molecule converge     # Roleの適用
molecule idempotency  # 冪等性確認（2回目実行でchanged=0を検証）
molecule verify       # 検証タスクの実行
molecule destroy      # クリーンアップ

# AWSへの実際の適用（EC2起動済みの場合）
ansible-playbook site.yml --check  # ドライラン
ansible-playbook site.yml
```

## Phase 4への引き継ぎ情報

- Moleculeテストが全て通過していること
- nginxロールの冪等性が確認済みであること
- Dynamic Inventoryで `web` グループにEC2インスタンスが検出されること