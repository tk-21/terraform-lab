# ✅Phase 2: Ansible ロール実装（CIS Benchmark / containerd / EKS準備）

## 前フェーズの要約

Phase 1 で以下を完了した：
- プロジェクトディレクトリ構造の作成
- ansible.cfg / inventory / playbooks/golden-ami.yml のベース生成
- packer/variables.pkrvars.hcl のベース生成
- terraform/environments/dev/ のベース設定

## このフェーズの目的

Ansible の3ロールを実装する：
1. `cis-benchmark` - Amazon Linux 2023 に CIS Level 1 ハードニングを適用
2. `docker-runtime` - containerd 1.7.x をインストール・設定
3. `eks-node-prep` - EKS ノード起動に必要な設定を事前適用

CLAUDE.md の設計原則（最小権限・日本語コメント・冪等性）を厳守。

---

## タスク一覧

### 1. cis-benchmark ロール

**ファイル: `ansible/roles/cis-benchmark/defaults/main.yml`**

```yaml
---
# CIS Benchmark Level 1 デフォルト変数
# 環境ごとにPlaybookから上書き可能

# SSH設定
cis_ssh_port: 22
cis_ssh_permit_root_login: "no"
cis_ssh_password_authentication: "no"
cis_ssh_max_auth_tries: 4
cis_ssh_client_alive_interval: 300
cis_ssh_client_alive_count_max: 0

# パスワードポリシー
cis_password_min_days: 7
cis_password_max_days: 365
cis_password_warn_age: 7

# ファイルシステム
cis_disable_cramfs: true
cis_disable_freevxfs: true
cis_disable_jffs2: true
cis_disable_hfs: true
cis_disable_squashfs: true
cis_disable_udf: true
cis_disable_usb_storage: true

# ネットワーク
cis_disable_ipv6: false          # EKSはIPv6を使う場合があるため無効化しない
cis_enable_iptables: true
cis_tcp_syncookies: true
cis_ip_forward: true             # EKSノードはIPフォワードが必要
```

**ファイル: `ansible/roles/cis-benchmark/tasks/main.yml`**

```yaml
---
# CIS Benchmark Level 1 ハードニング タスク
# Amazon Linux 2023 対応
# 参考: CIS Amazon Linux 2023 Benchmark v1.0.0

# === 1. ファイルシステム設定 ===

- name: 不要なファイルシステムを無効化（CIS 1.1.x）
  ansible.builtin.copy:
    dest: "/etc/modprobe.d/{{ item }}.conf"
    content: "install {{ item }} /bin/true\n"
    owner: root
    group: root
    mode: "0644"
  loop:
    - cramfs
    - freevxfs
    - jffs2
    - hfs
    - hfsplus
    - squashfs
    - udf
    - usb-storage
  when: cis_disable_cramfs  # 変数で制御

# === 2. パッケージ管理 ===

- name: セキュリティパッチを適用（CIS 1.8.x）
  ansible.builtin.dnf:
    name: "*"
    state: latest
    security: true
  tags: ["packages", "security"]

- name: 不要なパッケージを削除（CIS 2.x）
  ansible.builtin.dnf:
    name:
      - telnet
      - rsh
      - ypbind
      - ypserv
    state: absent
  tags: ["packages"]

# === 3. SSH ハードニング ===

- name: SSH 設定を強化（CIS 5.2.x）
  ansible.builtin.template:
    src: sshd_config.j2
    dest: /etc/ssh/sshd_config
    owner: root
    group: root
    mode: "0600"
    validate: "/usr/sbin/sshd -t -f %s"
  notify: restart sshd
  tags: ["ssh"]

# === 4. ネットワークカーネルパラメータ ===

- name: ネットワークセキュリティ設定（sysctl）（CIS 3.x）
  ansible.posix.sysctl:
    name: "{{ item.key }}"
    value: "{{ item.value }}"
    sysctl_set: true
    state: present
    reload: true
  loop:
    # IPスプーフィング対策
    - { key: "net.ipv4.conf.all.rp_filter", value: "1" }
    - { key: "net.ipv4.conf.default.rp_filter", value: "1" }
    # ICMPリダイレクト無効化
    - { key: "net.ipv4.conf.all.accept_redirects", value: "0" }
    - { key: "net.ipv4.conf.default.accept_redirects", value: "0" }
    # SYN Cookie 有効化（SYNフラッド対策）
    - { key: "net.ipv4.tcp_syncookies", value: "1" }
    # EKSノードに必要なIPフォワード
    - { key: "net.ipv4.ip_forward", value: "1" }
    # ブロードキャストへのICMP応答を無効化
    - { key: "net.ipv4.icmp_echo_ignore_broadcasts", value: "1" }
  tags: ["network", "sysctl"]

# === 5. ファイル権限 ===

- name: /etc/passwd の権限設定（CIS 6.1.x）
  ansible.builtin.file:
    path: /etc/passwd
    owner: root
    group: root
    mode: "0644"

- name: /etc/shadow の権限設定（CIS 6.1.x）
  ansible.builtin.file:
    path: /etc/shadow
    owner: root
    group: root
    mode: "0000"

# === 6. Auditd 設定 ===

- name: auditd インストール（CIS 4.1.x）
  ansible.builtin.dnf:
    name: audit
    state: present
  tags: ["audit"]

- name: auditd 有効化
  ansible.builtin.systemd:
    name: auditd
    enabled: true
    state: started
  tags: ["audit"]

- name: auditd ルール設定（CIS 4.1.x）
  ansible.builtin.copy:
    dest: /etc/audit/rules.d/cis.rules
    content: |
      # CIS Benchmark auditd ルール
      # 特権コマンドの監査
      -a always,exit -F arch=b64 -S execve -F euid=0 -k privileged
      # ファイル削除の監査
      -a always,exit -F arch=b64 -S unlink -S unlinkat -S rename -S renameat -F auid>=1000 -k delete
      # ユーザー・グループ変更の監査
      -w /etc/passwd -p wa -k identity
      -w /etc/group -p wa -k identity
      -w /etc/shadow -p wa -k identity
      -w /etc/sudoers -p wa -k sudoers
    owner: root
    group: root
    mode: "0640"
  notify: restart auditd
  tags: ["audit"]

# === 7. パスワードポリシー ===

- name: パスワードエイジング設定（CIS 5.4.x）
  ansible.builtin.lineinfile:
    path: /etc/login.defs
    regexp: "^{{ item.key }}"
    line: "{{ item.key }}\t{{ item.value }}"
    state: present
  loop:
    - { key: "PASS_MIN_DAYS", value: "{{ cis_password_min_days }}" }
    - { key: "PASS_MAX_DAYS", value: "{{ cis_password_max_days }}" }
    - { key: "PASS_WARN_AGE", value: "{{ cis_password_warn_age }}" }
  tags: ["password"]
```

**ファイル: `ansible/roles/cis-benchmark/handlers/main.yml`**

```yaml
---
# CIS Benchmark ハンドラー

- name: restart sshd
  ansible.builtin.systemd:
    name: sshd
    state: restarted

- name: restart auditd
  ansible.builtin.systemd:
    name: auditd
    state: restarted
```

**ファイル: `ansible/roles/cis-benchmark/templates/sshd_config.j2`**

```
# SSHd設定 - CIS Benchmark Level 1 準拠
# Ansible管理ファイル - 手動編集禁止

Port {{ cis_ssh_port }}
Protocol 2

# 認証設定
PermitRootLogin {{ cis_ssh_permit_root_login }}
PasswordAuthentication {{ cis_ssh_password_authentication }}
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes

# セッション制限
MaxAuthTries {{ cis_ssh_max_auth_tries }}
MaxSessions 4
LoginGraceTime 60

# アイドルタイムアウト（300秒 = 5分）
ClientAliveInterval {{ cis_ssh_client_alive_interval }}
ClientAliveCountMax {{ cis_ssh_client_alive_count_max }}

# 転送設定（EKSノードでは不要なため無効化）
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no

# 暗号化設定（強い暗号のみ許可）
KexAlgorithms curve25519-sha256,diffie-hellman-group14-sha256
Ciphers aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com

# ログ設定
SyslogFacility AUTHPRIV
LogLevel VERBOSE

# その他
PrintLastLog yes
Banner /etc/issue.net
```

---

### 2. docker-runtime ロール（containerd）

**ファイル: `ansible/roles/docker-runtime/tasks/main.yml`**

```yaml
---
# containerd インストール・設定タスク
# EKS 1.30 は containerd を CRI として使用する
# Docker デーモン（dockerd）はインストールしない

# === 1. 前提パッケージ ===

- name: containerd の依存パッケージをインストール
  ansible.builtin.dnf:
    name:
      - socat        # kubelet が使用
      - conntrack    # ネットワーク接続追跡
      - ipvsadm      # IPVSロードバランシング
      - ipset        # iptables拡張
      - tc           # トラフィック制御
    state: present
  tags: ["packages"]

# === 2. containerd インストール ===

- name: containerd のリポジトリ設定
  ansible.builtin.yum_repository:
    name: docker-ce-stable
    description: Docker CE Stable
    baseurl: "https://download.docker.com/linux/centos/9/aarch64/stable"
    gpgcheck: true
    gpgkey: "https://download.docker.com/linux/centos/gpg"
    enabled: true
  tags: ["containerd"]

- name: containerd.io をインストール
  ansible.builtin.dnf:
    name: containerd.io
    state: present
  tags: ["containerd"]

# === 3. containerd 設定 ===

- name: containerd デフォルト設定を生成
  ansible.builtin.shell:
    cmd: containerd config default > /etc/containerd/config.toml
    creates: /etc/containerd/config.toml
  tags: ["containerd"]

- name: containerd の SystemdCgroup を有効化（EKS必須設定）
  # kubelet と containerd の cgroup ドライバーを統一する
  ansible.builtin.replace:
    path: /etc/containerd/config.toml
    regexp: 'SystemdCgroup = false'
    replace: 'SystemdCgroup = true'
  notify: restart containerd
  tags: ["containerd"]

- name: containerd の sandbox image を EKS 対応版に変更
  # EKS の pause コンテナイメージを使用する
  ansible.builtin.replace:
    path: /etc/containerd/config.toml
    regexp: 'sandbox_image = ".*"'
    replace: 'sandbox_image = "602401143452.dkr.ecr.ap-northeast-1.amazonaws.com/eks/pause:3.5"'
  notify: restart containerd
  tags: ["containerd"]

# === 4. カーネルモジュール（コンテナネットワーク用）===

- name: コンテナ用カーネルモジュールを自動ロード設定
  ansible.builtin.copy:
    dest: /etc/modules-load.d/containerd.conf
    content: |
      # containerd / Kubernetes が必要とするカーネルモジュール
      overlay      # OverlayFS（コンテナ層管理）
      br_netfilter  # bridge経由のネットワークフィルタリング
    owner: root
    group: root
    mode: "0644"
  tags: ["kernel"]

- name: カーネルモジュールをロード（即時適用）
  community.general.modprobe:
    name: "{{ item }}"
    state: present
  loop:
    - overlay
    - br_netfilter
  tags: ["kernel"]

- name: containerd を有効化・起動
  ansible.builtin.systemd:
    name: containerd
    enabled: true
    state: started
  tags: ["containerd"]

- name: containerd の動作確認
  ansible.builtin.command: ctr version
  register: ctr_version
  changed_when: false
  tags: ["validation"]

- name: containerd バージョンを表示
  ansible.builtin.debug:
    msg: "containerd: {{ ctr_version.stdout }}"
  tags: ["validation"]
```

---

### 3. eks-node-prep ロール

**ファイル: `ansible/roles/eks-node-prep/tasks/main.yml`**

```yaml
---
# EKS ノード事前設定タスク
# Karpenter が起動するノードに必要な設定を事前に Golden AMI に焼き込む

# === 1. aws-cli v2 インストール ===

- name: aws-cli v2 をインストール
  # EKS ノードブートストラップスクリプトが aws-cli を使用する
  ansible.builtin.shell:
    cmd: |
      curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o /tmp/awscliv2.zip
      unzip -q /tmp/awscliv2.zip -d /tmp
      /tmp/aws/install
      rm -rf /tmp/aws /tmp/awscliv2.zip
    creates: /usr/local/bin/aws
  tags: ["awscli"]

# === 2. SSM Agent インストール ===

- name: SSM Agent をインストール（Session Manager経由でのアクセス用）
  ansible.builtin.dnf:
    name: amazon-ssm-agent
    state: present
  tags: ["ssm"]

- name: SSM Agent を有効化
  ansible.builtin.systemd:
    name: amazon-ssm-agent
    enabled: true
    state: started
  tags: ["ssm"]

# === 3. kubelet 事前設定 ===

- name: kubelet 設定ディレクトリ作成
  ansible.builtin.file:
    path: /etc/kubernetes/kubelet
    state: directory
    owner: root
    group: root
    mode: "0755"
  tags: ["kubelet"]

- name: kubelet 追加設定（EKS最適化）
  ansible.builtin.copy:
    dest: /etc/kubernetes/kubelet/kubelet-config-additional.json
    content: |
      {
        "apiVersion": "kubelet.config.k8s.io/v1beta1",
        "kind": "KubeletConfiguration",
        "maxPods": 110,
        "evictionHard": {
          "memory.available": "100Mi",
          "nodefs.available": "10%",
          "nodefs.inodesFree": "5%"
        },
        "systemReserved": {
          "cpu": "100m",
          "memory": "100Mi",
          "ephemeral-storage": "1Gi"
        },
        "kubeReserved": {
          "cpu": "100m",
          "memory": "100Mi",
          "ephemeral-storage": "1Gi"
        }
      }
    owner: root
    group: root
    mode: "0644"
  tags: ["kubelet"]

# === 4. EKS ブートストラップスクリプト ===

- name: EKS ノードブートストラップスクリプトをインストール
  ansible.builtin.dnf:
    name: "amazon-eks-node-{{ eks_version }}"
    state: present
  tags: ["eks"]

# === 5. ディスク設定 ===

- name: /var/lib/containerd のディスク確保（コンテナイメージ用）
  ansible.builtin.file:
    path: /var/lib/containerd
    state: directory
    owner: root
    group: root
    mode: "0711"
  tags: ["disk"]

# === 6. ログローテーション ===

- name: コンテナログのローテーション設定
  ansible.builtin.copy:
    dest: /etc/logrotate.d/containers
    content: |
      /var/log/containers/*.log {
          daily
          rotate 7
          compress
          missingok
          notifempty
          sharedscripts
      }
    owner: root
    group: root
    mode: "0644"
  tags: ["logging"]

# === 7. AMI メタデータタグ ===

- name: AMI ビルド情報をファイルに記録
  ansible.builtin.copy:
    dest: /etc/eks-golden-ami-version
    content: |
      BUILD_DATE={{ ansible_date_time.date }}
      EKS_VERSION={{ eks_version }}
      CIS_LEVEL=1
      CONTAINERD_ENABLED=true
    owner: root
    group: root
    mode: "0644"
  tags: ["metadata"]

- name: EKS ノード準備完了メッセージ
  ansible.builtin.debug:
    msg: "EKS node prep completed. EKS_VERSION={{ eks_version }}"
  tags: ["validation"]
```

---

## 完了条件

- [ ] `ansible/roles/cis-benchmark/tasks/main.yml` が存在する
- [ ] `ansible/roles/cis-benchmark/handlers/main.yml` が存在する
- [ ] `ansible/roles/cis-benchmark/defaults/main.yml` が存在する
- [ ] `ansible/roles/cis-benchmark/templates/sshd_config.j2` が存在する
- [ ] `ansible/roles/docker-runtime/tasks/main.yml` が存在する
- [ ] `ansible/roles/eks-node-prep/tasks/main.yml` が存在する

## 次フェーズへの引き継ぎ

Phase 3 では Packer テンプレート（`packer/golden-ami.pkr.hcl`）と
GitHub Actions の AMI ビルドパイプライン（`.github/workflows/ami-build.yml`）を実装する。