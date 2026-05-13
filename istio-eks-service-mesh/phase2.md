# ✅Phase 2 — Ansible: OS Hardening + Istio インストール

## Phase 1 からの引き継ぎ確認

このフェーズを開始する前に、以下が完了していること:
- EKS クラスタが起動中（`kubectl get nodes` で Ready）
- Terraform outputs から以下の値が取得済み

```bash
export EKS_CLUSTER_NAME=$(cd terraform && terraform output -raw eks_cluster_name)
export REPORT_BUCKET=$(cd terraform && terraform output -raw report_bucket_name)
export AWS_REGION="ap-northeast-1"
```

## このフェーズのゴール

1. Ansible Dynamic Inventory で EKS ワーカーノードを自動検出
2. CIS Amazon Linux 2023 Benchmark Level 1 準拠の OS hardening 適用
3. `istioctl` を使って Istio を EKS クラスタにインストール
4. mTLS STRICT モードを有効化

---

## Step 1: Ansible 設定ファイル

### `ansible/ansible.cfg`

```ini
[defaults]
# インベントリソースとしてAWS EC2ダイナミックインベントリを使用
inventory = inventory/aws_ec2.yaml
host_key_checking = False
retry_files_enabled = False
stdout_callback = yaml
# EKSワーカーノードはSSMで接続（SSH鍵不要）
[ssh_connection]
pipelining = True
```

### `ansible/inventory/aws_ec2.yaml`

```yaml
# AWS EC2 ダイナミックインベントリ設定
# EKSワーカーノードをタグで自動グルーピング
plugin: amazon.aws.aws_ec2
regions:
  - ap-northeast-1
filters:
  tag:Project: istio-eks-service-mesh
  instance-state-name: running
keyed_groups:
  - key: tags.role
    prefix: role
  - key: tags.env
    prefix: env
hostnames:
  - private-ip-address  # プライベートIPで接続（VPC内からのみ）
compose:
  ansible_host: private_ip_address
```

### `ansible/group_vars/all.yaml`

```yaml
# 全ホスト共通変数
ansible_user: ec2-user
ansible_connection: aws_ssm  # Session Manager経由接続
aws_region: "ap-northeast-1"

# OS hardening パラメータ
sysctl_hardening:
  net.ipv4.ip_forward: 1           # Kubernetes ルーティングに必要
  net.bridge.bridge-nf-call-iptables: 1  # コンテナネットワーク要件
  net.ipv4.conf.all.send_redirects: 0
  net.ipv4.conf.all.accept_redirects: 0
  net.ipv4.tcp_syncookies: 1
  kernel.dmesg_restrict: 1
  fs.suid_dumpable: 0

# Istio バージョン
istio_version: "1.21.0"
istio_install_dir: "/usr/local/bin"
```

---

## Step 2: OS Hardening ロール

`ansible/roles/os_hardening/` 以下を作成する。

### `ansible/roles/os_hardening/defaults/main.yaml`

```yaml
# CIS Amazon Linux 2023 Benchmark Level 1 デフォルト値
# 各設定の CIS ベンチマーク番号をコメントで記載
cis_enable_firewalld: false        # EKS環境ではiptables/ebpfを使用
cis_disable_usb_storage: true     # CIS 1.1.10: USBストレージ無効化
cis_set_umask: "027"              # CIS 5.4.4: デフォルトumask設定
cis_password_max_days: 365
cis_password_min_days: 7
cis_password_warn_days: 7
```

### `ansible/roles/os_hardening/tasks/main.yaml`

以下のタスクを実装する（各タスクに日本語 `name:` を付与）:

**1. パッケージ更新**
```yaml
# セキュリティパッチを最新化する（CIS 1.9）
- name: セキュリティパッチを含む全パッケージを更新する
  ansible.builtin.dnf:
    name: "*"
    state: latest
    security: true
```

**2. 不要なサービス停止**
```yaml
# CIS 2.x: 不要なサービスを停止・無効化する
# EKSワーカーノードでは以下のサービスは不要
対象サービス: telnet, rsh, ypserv, tftp（存在する場合のみ）
```

**3. SSH ハードニング**
```yaml
# CIS 5.2: SSH サーバー設定のハードニング
対象ファイル: /etc/ssh/sshd_config
設定項目:
  - PermitRootLogin: no
  - PasswordAuthentication: no
  - X11Forwarding: no
  - MaxAuthTries: 4
  - ClientAliveInterval: 300
  - ClientAliveCountMax: 0
  - AllowTcpForwarding: no
  - Protocol: 2
handlers で sshd restart をトリガー
```

**4. sysctl ハードニング**
```yaml
# CIS 3.x: カーネルパラメータのハードニング
# Kubernetes 動作に必要なパラメータ（ip_forward等）は有効のまま
- name: Kubernetesと互換性を保ちながらカーネルパラメータをハードニングする
  ansible.posix.sysctl:
    name: "{{ item.key }}"
    value: "{{ item.value }}"
    state: present
    reload: true
    sysctl_file: /etc/sysctl.d/99-cis-hardening.conf
  loop: "{{ sysctl_hardening | dict2items }}"
```

**5. ファイルパーミッション修正**
```yaml
# CIS 6.1: 重要なファイルのパーミッション設定
対象:
  - /etc/passwd: mode 0644, owner root
  - /etc/shadow: mode 0000, owner root
  - /etc/group: mode 0644, owner root
  - /etc/gshadow: mode 0000, owner root
  - /etc/crontab: mode 0600, owner root
```

**6. auditd 設定**
```yaml
# CIS 4.x: 監査ログの設定
# Kubernetes API サーバーのアクセスを記録
- name: auditdをインストールして設定する
  tasks:
    - dnf install audit
    - /etc/audit/rules.d/hardening.rules を作成:
        -w /etc/passwd -p wa -k identity
        -w /etc/shadow -p wa -k identity
        -w /etc/sudoers -p wa -k scope
        -a always,exit -F arch=b64 -S execve -k exec
    - auditd を enable + start
```

**7. umask 設定**
```yaml
# CIS 5.4.4: デフォルト umask を 027 に設定
- name: デフォルトumaskを027に設定する
  ansible.builtin.lineinfile:
    path: /etc/profile
    regexp: '^umask'
    line: 'umask 027'
```

### `ansible/roles/os_hardening/handlers/main.yaml`

```yaml
- name: sshd を再起動する
  ansible.builtin.service:
    name: sshd
    state: restarted

- name: auditd を再起動する
  ansible.builtin.service:
    name: auditd
    state: restarted
```

---

## Step 3: Istio インストールロール

`ansible/roles/istio_install/` 以下を作成する。

### `ansible/roles/istio_install/defaults/main.yaml`

```yaml
istio_version: "1.21.0"
istio_install_dir: "/usr/local/bin"
# Istio インストールプロファイル
# defaultプロファイル: istiod + ingress gateway を含む標準構成
istio_profile: "default"
istio_namespace: "istio-system"
```

### `ansible/roles/istio_install/tasks/main.yaml`

以下のタスクを実装する（コントロールノード=ローカルPC 上で実行する `delegate_to: localhost` タスク群）:

**注意**: Istio のインストールは EKS ワーカーノードではなく、`kubectl` が使えるローカル環境から実施する。
`delegate_to: localhost` と `run_once: true` を活用すること。

```yaml
# istioctl バイナリをローカルにダウンロードする
- name: istioctl バイナリをダウンロードする
  ansible.builtin.get_url:
    url: "https://github.com/istio/istio/releases/download/{{ istio_version }}/istioctl-{{ istio_version }}-linux-amd64.tar.gz"
    dest: "/tmp/istioctl-{{ istio_version }}.tar.gz"
  delegate_to: localhost
  run_once: true

# アーカイブを展開する
- name: istioctl を展開する
  ansible.builtin.unarchive:
    src: "/tmp/istioctl-{{ istio_version }}.tar.gz"
    dest: "{{ istio_install_dir }}"
    remote_src: false
    creates: "{{ istio_install_dir }}/istioctl"
  delegate_to: localhost
  run_once: true

# Istio の事前チェック
- name: EKS クラスタへの Istio インストール事前チェックを実行する
  ansible.builtin.command:
    cmd: "{{ istio_install_dir }}/istioctl x precheck"
  delegate_to: localhost
  run_once: true
  register: istio_precheck
  changed_when: false

- name: 事前チェック結果を表示する
  ansible.builtin.debug:
    var: istio_precheck.stdout_lines
  delegate_to: localhost
  run_once: true

# Istio をインストールする
- name: Istio を {{ istio_profile }} プロファイルでインストールする
  ansible.builtin.command:
    cmd: >
      {{ istio_install_dir }}/istioctl install
      --set profile={{ istio_profile }}
      --set values.global.proxy.resources.requests.cpu=100m
      --set values.global.proxy.resources.requests.memory=128Mi
      -y
  delegate_to: localhost
  run_once: true
  register: istio_install_result

# インストール結果の確認
- name: istio-system の Pod が全て Running になるまで待機する
  ansible.builtin.command:
    cmd: kubectl wait --for=condition=ready pod --all -n istio-system --timeout=300s
  delegate_to: localhost
  run_once: true

# mesh-apps Namespace を作成して自動インジェクションを有効化
- name: mesh-apps Namespace を作成する
  ansible.builtin.command:
    cmd: kubectl apply -f k8s/namespaces/mesh-apps.yaml
  delegate_to: localhost
  run_once: true

# mTLS STRICT モード適用
- name: mesh-apps Namespace に mTLS STRICT モードを適用する
  ansible.builtin.command:
    cmd: kubectl apply -f k8s/istio/peer-authentication.yaml
  delegate_to: localhost
  run_once: true
```

---

## Step 4: Kubernetes マニフェスト（Namespace と PeerAuthentication）

### `k8s/namespaces/mesh-apps.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mesh-apps
  labels:
    # Istio サイドカー自動インジェクションを有効化
    istio-injection: enabled
    env: dev
    managed-by: ansible
```

### `k8s/istio/peer-authentication.yaml`

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: mesh-apps
  labels:
    # mTLS STRICT: サービス間通信を全て相互TLS認証必須にする
    # これにより平文通信を完全に排除する
spec:
  mtls:
    mode: STRICT
```

---

## Step 5: Playbook

### `ansible/playbooks/hardening.yaml`

```yaml
---
# EKS ワーカーノードに CIS Level 1 OS ハードニングを適用する
- name: EKS ワーカーノードの OS ハードニング
  hosts: role_worker
  become: true
  gather_facts: true
  roles:
    - os_hardening
```

### `ansible/playbooks/istio_setup.yaml`

```yaml
---
# Istio を EKS クラスタにインストールし mTLS を有効化する
# 実際の操作はローカルから kubectl 経由で実施（delegate_to: localhost）
- name: Istio セットアップと mTLS 有効化
  hosts: role_worker
  gather_facts: false
  roles:
    - istio_install
```

---

## Step 6: ADR ドキュメント

`docs/adr/003-s3-html-report.md` を作成する:

- Context: 可視化ダッシュボードの選択（Kiali、Grafana、S3 HTML）
- Decision: S3 HTML レポートを選択
- Reasons: 外部ダッシュボードサービスのコストゼロ、署名付きURLで安全共有、ポートフォワード不要
- Consequences: リアルタイム性の欠如（バッチ生成）

---

## 実行手順

```bash
# 1. ansible-galaxy コレクションインストール
ansible-galaxy collection install amazon.aws community.general ansible.posix

# 2. Dynamic Inventory 疎通確認
ansible-inventory -i ansible/inventory/aws_ec2.yaml --list

# 3. OS ハードニング適用（dry-run）
ansible-playbook ansible/playbooks/hardening.yaml --check

# 4. OS ハードニング本適用
ansible-playbook ansible/playbooks/hardening.yaml

# 5. Istio インストール
ansible-playbook ansible/playbooks/istio_setup.yaml

# 6. Istio 動作確認
kubectl get pods -n istio-system
kubectl get peerauthentication -n mesh-apps
```

---

## Phase 2 完了条件

- [ ] `ansible-playbook hardening.yaml` がエラーなく完了（冪等性確認のため2回実行）
- [ ] `kubectl get pods -n istio-system` で全 Pod が `Running`
- [ ] `istioctl analyze` で warning/error なし
- [ ] `kubectl get peerauthentication -A` で `STRICT` が確認できる
- [ ] `kubectl get ns mesh-apps --show-labels` で `istio-injection=enabled` が確認できる

## Phase 3 への引き継ぎ情報

Phase 3 の冒頭で以下を確認すること:
- Istio ingress gateway の EXTERNAL-IP: `kubectl get svc -n istio-system istio-ingressgateway`
- mesh-apps Namespace が存在し istio-injection=enabled であること
- `REPORT_BUCKET` 環境変数が設定されていること