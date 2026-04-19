# レビュー観点の詳細

Amazon Bedrock（Claude Sonnet 3.5）が評価する6カテゴリのレビュー観点を詳述する。
各カテゴリで問題の具体例（bad）と改善後の例（good）を示す。

---

## 1. セキュリティ（Security）

Ansible Playbookに潜むセキュリティリスクを検出する。影響範囲が広いため、問題の多くがCRITICAL/HIGH評価になる。

### 1-1. 認証情報のハードコード

**bad（CRITICAL）**
```yaml
vars:
  db_password: "SuperSecret123!"   # ハードコード: Gitに残り漏洩リスク
  api_token: "ghp_xxxxxxxxxxxx"
```

**good**
```yaml
vars:
  db_password: "{{ vault_db_password }}"   # ansible-vault で暗号化
  api_token: "{{ lookup('env', 'API_TOKEN') }}"  # 環境変数から取得
```

### 1-2. no_log未設定

**bad（CRITICAL）**
```yaml
- name: configure database
  ansible.builtin.command:
    cmd: mysql -u root -p{{ db_password }} -e "GRANT ALL..."
  # パスワードがCloudWatch Logsに平文で残る
```

**good**
```yaml
- name: configure database
  community.mysql.mysql_user:
    name: "{{ db_user }}"
    password: "{{ vault_db_password }}"
  no_log: true   # 認証情報をログから保護
```

### 1-3. becomeの過剰使用

**bad（HIGH）**
```yaml
- name: webserver setup
  hosts: webservers
  become: yes   # 全タスクをrootで実行。不要な権限昇格
```

**good**
```yaml
- name: webserver setup
  hosts: webservers
  # become はタスクレベルで必要なものにのみ付与

  tasks:
    - name: パッケージをインストールする
      ansible.builtin.dnf:
        name: httpd
        state: present
      become: true   # このタスクはroot権限が必要

    - name: アプリファイルをデプロイする
      ansible.builtin.template:
        src: app.conf.j2
        dest: /etc/app/app.conf
      become: true
      become_user: appuser   # 最小権限で実行
```

### 1-4. 危険なパーミッション設定

**bad（HIGH）**
```yaml
- name: set permissions
  ansible.builtin.shell: chmod -R 777 /var/www/html
```

**good**
```yaml
- name: Webルートのパーミッションを設定する
  ansible.builtin.file:
    path: /var/www/html
    owner: webappuser
    group: apache
    mode: "0755"   # 最小権限の原則
    recurse: false
  become: true
```

**参考**: [Ansible Security Best Practices](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_best_practices.html)

---

## 2. 冪等性（Idempotency）

Ansibleの最重要原則。同じPlaybookを何度実行しても結果が変わらないことを保証する。

### 2-1. changed_when未設定のshell/command

**bad（MEDIUM）**
```yaml
- name: アプリを起動する
  ansible.builtin.shell: systemctl start myapp
  # 毎回 changed になりレポートが不正確になる
```

**good**
```yaml
- name: アプリの起動状態を確認する
  ansible.builtin.command: systemctl is-active myapp
  register: app_status
  changed_when: false   # 確認コマンドは changed にしない
  failed_when: app_status.rc not in [0, 3]
```

### 2-2. shellによる状態変更（モジュール未使用）

**bad（HIGH）**
```yaml
- name: ユーザーを作成する
  ansible.builtin.shell: useradd -m webuser
  # ユーザーが既に存在するとエラーになる（冪等でない）
```

**good**
```yaml
- name: ユーザーを作成する
  ansible.builtin.user:
    name: webuser
    state: present   # userモジュールは冪等に動作する
    create_home: true
```

**参考**: [Ansible Idempotency](https://docs.ansible.com/ansible/latest/reference_appendices/glossary.html#term-Idempotency)

---

## 3. エラーハンドリング（Error Handling）

障害発生時の適切な処理と、意図しないエラー隠蔽を防ぐ。

### 3-1. ignore_errorsの乱用

**bad（HIGH）**
```yaml
- name: サービスを起動する
  ansible.builtin.shell: systemctl start myapp
  ignore_errors: yes   # エラーを握りつぶす。問題の発見が遅れる
```

**good**
```yaml
- name: サービスを起動する
  ansible.builtin.service:
    name: myapp
    state: started
  register: start_result
  failed_when:
    - start_result.failed
    - "'Unit not found' not in start_result.msg"   # 特定条件のみ許容
```

### 3-2. block/rescue/alwaysの未活用

**bad（MEDIUM）**
```yaml
- name: DBマイグレーションを実行する
  ansible.builtin.command: python manage.py migrate
  ignore_errors: yes   # 失敗してもロールバックなし
```

**good**
```yaml
- name: DBマイグレーションを安全に実行する
  block:
    - name: マイグレーションを実行する
      ansible.builtin.command: python manage.py migrate
      register: migrate_result

    - name: マイグレーション成功を検証する
      ansible.builtin.assert:
        that: migrate_result.rc == 0

  rescue:
    - name: マイグレーション失敗をアラート通知する
      ansible.builtin.debug:
        msg: "マイグレーション失敗: {{ migrate_result.stderr }}"

    - name: バックアップからDBをロールバックする
      ansible.builtin.command: python manage.py migrate --fake {{ previous_version }}

  always:
    - name: マイグレーションログを記録する
      ansible.builtin.copy:
        content: "{{ migrate_result | to_json }}"
        dest: /var/log/migrations/{{ ansible_date_time.iso8601 }}.json
```

**参考**: [Error Handling in Playbooks](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_error_handling.html)

---

## 4. パフォーマンス（Performance）

不要な処理を排除し、Playbookの実行時間を最適化する。

### 4-1. 不要なgather_facts

**bad（LOW）**
```yaml
- name: ファイルをコピーするだけのPlaybook
  hosts: all
  gather_facts: yes   # デフォルトtrue。ファイルコピーのみなら不要（数秒のオーバーヘッド）
```

**good**
```yaml
- name: ファイルをコピーするだけのPlaybook
  hosts: all
  gather_facts: false   # Ansible変数（ansible_os_family等）を使わない場合は無効化
```

### 4-2. with_itemsの使用（非推奨）

**bad（MEDIUM）**
```yaml
- name: パッケージをインストールする
  ansible.builtin.yum:
    name: "{{ item }}"
    state: present
  with_items:   # 非推奨。Ansible 2.5以降はloopを使う
    - httpd
    - mysql
    - php
```

**good**
```yaml
- name: パッケージをインストールする
  ansible.builtin.dnf:
    name:
      - httpd
      - mysql-server
      - php
    state: present   # リストで渡すと1回のトランザクションで処理（最速）
```

**参考**: [Loops in Ansible](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_loops.html)

---

## 5. 可読性（Readability）

Playbookはインフラのドキュメントでもある。可読性を高めることでレビューと保守性を向上させる。

### 5-1. 不明確なタスク名

**bad（LOW）**
```yaml
- name: do stuff          # 何をするか不明
  ansible.builtin.shell: yum update -y

- name: install           # 何をインストールするか不明
  ansible.builtin.dnf:
    name: httpd
```

**good**
```yaml
- name: すべてのシステムパッケージをアップデートする
  ansible.builtin.dnf:
    name: "*"
    state: latest
  become: true

- name: Apacheウェブサーバーをインストールする
  ansible.builtin.dnf:
    name: httpd
    state: present
  become: true
```

### 5-2. 変数命名規則の違反

**bad（LOW）**
```yaml
vars:
  x: 8080          # 意味不明な変数名
  DBpwd: "secret"  # 命名規則がバラバラ（camelCase + 略語）
  temp-file: /tmp  # ハイフンは変数名に使用不可
```

**good**
```yaml
vars:
  app_port: 8080               # スネークケース統一
  db_password: "{{ vault_db_password }}"  # 意味が明確
  temp_work_dir: /tmp/ansible  # アンダースコアを使用
```

**参考**: [Ansible Best Practices - Variable Names](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_best_practices.html#use-dynamic-inventory-with-clouds)

---

## 6. ベストプラクティス（Best Practices）

Ansibleコミュニティが推奨する標準的な実装パターンへの準拠を確認する。

### 6-1. FQCNモジュール名の未使用

**bad（MEDIUM）**
```yaml
- name: パッケージをインストールする
  yum:        # 短縮名。コレクション競合が起きる可能性がある
    name: httpd
    state: present

- name: サービスを起動する
  service:    # 短縮名
    name: httpd
    state: started
```

**good**
```yaml
- name: パッケージをインストールする
  ansible.builtin.dnf:        # FQCN: コレクション名.モジュール名
    name: httpd
    state: present

- name: サービスを起動する
  ansible.builtin.service:    # FQCN
    name: httpd
    state: started
```

### 6-2. タグの未設定

**bad（LOW）**
```yaml
tasks:
  - name: Apacheをインストールする
    ansible.builtin.dnf:
      name: httpd
      state: present
    # タグなし: --tags install で選択実行ができない
```

**good**
```yaml
tasks:
  - name: Apacheをインストールする
    ansible.builtin.dnf:
      name: httpd
      state: present
    tags:
      - install
      - apache
      - packages
```

### 6-3. handlersの未活用

**bad（MEDIUM）**
```yaml
tasks:
  - name: Apache設定ファイルを更新する
    ansible.builtin.template:
      src: httpd.conf.j2
      dest: /etc/httpd/conf/httpd.conf

  - name: Apacheを再起動する    # 設定変更のたびに無条件再起動
    ansible.builtin.service:
      name: httpd
      state: restarted
```

**good**
```yaml
handlers:
  - name: Apacheを再起動する    # 変更があった場合のみ再起動（Playbook末尾に一度）
    ansible.builtin.service:
      name: httpd
      state: restarted
    become: true

tasks:
  - name: Apache設定ファイルを更新する
    ansible.builtin.template:
      src: httpd.conf.j2
      dest: /etc/httpd/conf/httpd.conf
    notify: Apacheを再起動する   # 変更があったときのみhandlerが呼ばれる
    become: true
```

**参考**: [Ansible Best Practices](https://docs.ansible.com/ansible/latest/tips_tricks/ansible_tips_tricks.html)
