# aws-lsyncd-sync-infra 完全理解ドキュメント

---

## このプロジェクトを一言で言うと

> master EC2 でファイルを編集すると、5 秒以内に slave EC2 × 2 台に自動コピーされる仕組みを、Terraform + Ansible で一から構築するハンズオン。

---

## 実際に何が起きているか（同期のストーリー）

```
① 運用者が master の /var/www/html/index.html を編集

② lsyncd（master 上で常駐するデーモン）が
   inotify でファイル変更を即座に検知

③ 5 秒後（lsyncd_delay）、lsyncd が rsync を起動

④ rsync が SSH 経由で slave-1、slave-2 へ差分転送

⑤ ブラウザから slave の IP にアクセスすると
   更新されたページが表示される
```

これだけ。あとは「この仕組みをどうやって AWS 上に自動構築するか」の話。

---

## 全体構成図

```
  ┌──────────────────────────────────────────────────────┐
  │  VPC  10.0.0.0/16  (ap-northeast-1)                  │
  │  Public Subnet  10.0.1.0/24                          │
  │                                                      │
  │   ┌─────────────────────────┐                       │
  │   │  master  (t3.micro)     │                       │
  │   │  nginx + lsyncd 常駐    │                       │
  │   │  /var/www/html/ ← 編集  │                       │
  │   └───────┬─────────────────┘                       │
  │           │  rsync over SSH (プライベートIP)         │
  │     ┌─────┴──────────────────┐                      │
  │     ↓                        ↓                      │
  │  ┌──────────┐         ┌──────────┐                  │
  │  │ slave-1  │         │ slave-2  │  nginx のみ      │
  │  │(t3.micro)│         │(t3.micro)│                  │
  │  └──────────┘         └──────────┘                  │
  └──────────────────────────────────────────────────────┘
        ↑ HTTP:80 公開               ↑ HTTP:80 公開
   curl http://<slave-1-ip>/    curl http://<slave-2-ip>/

  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─

  [ 運用者 PC ]
       │  SSM Session Manager（ポート22を開けずにログイン）
       ↓
  AWS Systems Manager ── → master / slave
```

**ポイント**:
- 外部からの SSH（ポート22）は **一切開けていない**。運用者は SSM Session Manager でログインする
- master → slave の同期は **VPC 内プライベート IP** で通信する（インターネットに出ない）
- slave は nginx だけ動いていて、コンテンツは master から届く

---

## SSH 鍵が 2 種類ある（ここを最初に理解する）

このプロジェクトで混乱しやすいのが鍵の種類。用途が全く違う。

```
鍵①  ec2_key.pem
     生成: Terraform が apply 時に自動生成
     保存: ansible/keys/ec2_key.pem（ローカル）
     用途: 運用者の PC → EC2 への SSH（Ansible が使う）
     
鍵②  lsyncd_rsa
     生成: Ansible の ssh_key_dist role が master 上で生成
     保存: master の /home/ec2-user/.ssh/lsyncd_rsa
     用途: master → slave への rsync（lsyncd デーモンが使う）
     ※ パスフレーズなし（デーモンが自動実行するため）
```

なぜ分けるのか → 鍵②を slave の `authorized_keys` に登録することで、lsyncd だけが slave に rsync できる。運用者の鍵①が紛失しても、同期の仕組みは独立して守られる。

---

## Terraform が作るもの

`terraform apply` 一発でこれらが全部できる。

```
VPC
└── パブリックサブネット (10.0.1.0/24)
    └── インターネットゲートウェイ
        └── ルートテーブル（0.0.0.0/0 → IGW）

セキュリティグループ（master/slave 共用）
├── 受信: TCP 22  ← VPC 内のみ（lsyncd の rsync 用）
├── 受信: TCP 80  ← 全公開（nginx 確認用）
└── 送信: 全て許可

IAM ロール（EC2 用）
└── AmazonSSMManagedInstanceCore ポリシー
    └── これがあると SSM Session Manager でログインできる

EC2 インスタンス × 3
├── master（Tag: Role=master）
│   └── ホスト名: master
├── slave-1（Tag: Role=slave）
│   └── ホスト名: slave-1
└── slave-2（Tag: Role=slave）
    └── ホスト名: slave-2

SSH キーペア
└── 秘密鍵を ansible/keys/ec2_key.pem に保存（perm: 0600）
```

**Tag: Role が重要な理由**: Ansible の Dynamic Inventory がこのタグを読んで、自動的に `master` グループと `slave` グループを作る。IP をハードコードしなくて済む。

---

## Ansible が設定するもの

Playbook は 4 つの role を **この順番で** 実行する。順番に意味がある。

### Step 1 — common（全台）
タイムゾーン（Asia/Tokyo）設定、パッケージ更新、rsync インストール、`/var/www/html` ディレクトリ作成（オーナー: ec2-user）

### Step 2 — nginx（全台）
nginx インストール＋起動。**master だけ** `index.html` を配置する。slave は後で lsyncd から届く。

### Step 3 — ssh_key_dist（全台対象・内部で分岐）
ここが一番複雑。なぜ `hosts: all` で実行するかというと、master で作った公開鍵を slave に配る際に `hostvars`（全ホストの情報）を参照する必要があるため。

```
master で実行:
  1. lsyncd 用 RSA 4096 鍵ペアを生成 (~/.ssh/lsyncd_rsa)
  2. 公開鍵を Ansible ファクト（変数）として保存

slave で実行:
  3. master の公開鍵を authorized_keys に追加
     ← これで master から rsync できるようになる

master で実行:
  4. slave のホスト鍵を known_hosts に登録
     ← これがないと rsync 時に「鍵確認」で止まる
```

### Step 4 — lsyncd（master のみ）
EPEL リポジトリ有効化 → lsyncd インストール → 設定ファイル生成 → 起動。

設定ファイル `/etc/lsyncd.conf` は Jinja2 テンプレートから生成される。slave が 3 台に増えてもテンプレートのループが自動対応する。

```lua
-- slave 台数分、このブロックが自動生成される
sync {
    default.rsyncssh,
    source    = "/var/www/html/",      -- 末尾の / が必須（中身を同期）
    host      = "10.0.1.xxx",          -- slave のプライベート IP
    targetdir = "/var/www/html/",
    rsync = {
        rsh    = "ssh -i ~/.ssh/lsyncd_rsa",  -- 専用鍵②を使う
        _delete = true,               -- master で消したら slave でも消す
    },
    delay   = 5,                       -- 変更検知から rsync 開始までの遅延
    exclude = { ".git", "*.swp", "*.tmp" },
}
```

---

## Ansible が EC2 に接続する仕組み

「ポート22を開けていないのに Ansible が接続できるのはなぜ？」

答えは `ansible.cfg` の ProxyCommand:

```
ssh → SSM Session Manager → EC2
```

接続先のホスト名としてインスタンス ID（`i-0abc...`）が使われる。Dynamic Inventory が EC2 の API から取得してくれる。

---

## セットアップの流れ

### Phase 1 — 事前準備（手動）

```bash
# S3 バケットを作成（tfstate の保存先）
aws s3 mb s3://<あなたのバケット名> --region ap-northeast-1

# DynamoDB テーブルを作成（tfstate のロック用）
aws dynamodb create-table \
  --table-name terraform-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-northeast-1

# backend.tf の YOUR_TFSTATE_BUCKET_NAME を上記バケット名に変更
```

### Phase 2 — Terraform（EC2 を作る）

```bash
cd terraform
terraform init      # バックエンド初期化
terraform plan      # 変更内容の確認
terraform apply     # ← ユーザーが実行する（Claude Code は実行しない）
```

apply 完了後、`ansible/keys/ec2_key.pem` が自動生成される。

### Phase 3 — Ansible（ミドルウェアを設定する）

```bash
cd ansible

# EC2 が認識されているか確認
ansible-inventory --list

# 全ロールを実行
ansible-playbook playbooks/site.yml
```

### Phase 4 — 動作確認

```bash
bash scripts/verify.sh
```

スクリプトの中身:
1. master にテストファイルを作成
2. 7 秒待つ（lsyncd の 5 秒遅延 + バッファ）
3. slave-1, slave-2 に curl でアクセスして同期確認
4. テストファイルを削除

---

## ファイルと役割の対応

```
terraform/
├── backend.tf         プロバイダのバージョン指定、S3/DynamoDB バックエンド設定
├── variables.tf       変数定義（変えたいときはここを変える）
├── vpc.tf             VPC/サブネット/IGW/ルートテーブル
├── security_group.tf  SG（インターネットから22番を開けない設計）
├── key_pair.tf        鍵①の生成と ansible/keys/ への保存
├── iam.tf             SSM 用の IAM ロール
├── ec2.tf             master/slave の EC2（Tag:Role でグループ化）
└── outputs.tf         apply 後に表示される接続コマンド等

ansible/
├── ansible.cfg                SSM 経由の SSH ProxyCommand 設定
├── inventory/aws_ec2.yml      Dynamic Inventory（Tag:Role → グループ名）
├── group_vars/all.yml         全台共通変数（lsyncd_delay, web_root 等）
├── group_vars/master.yml      master 専用（lsyncd のターゲットグループ名）
├── group_vars/slave.yml       slave 専用（rsync 受信先パス）
├── playbooks/site.yml         実行順序の定義（4 step）
└── roles/
    ├── common/                パッケージ/タイムゾーン/ディレクトリ
    ├── nginx/                 nginx 設定（index.html は master のみ）
    ├── ssh_key_dist/          鍵②の生成・配布・known_hosts 登録
    └── lsyncd/                lsyncd インストール・設定・起動
```

---

## よくある疑問

**Q. slave を 3 台に増やしたいときは？**

`variables.tf` の `slave_count` を 3 に変更して `terraform apply`。lsyncd.conf.j2 のループが自動的に 3 台分の sync ブロックを生成する。

**Q. lsyncd が動いているか確認するには？**

master に SSM でログインして:
```bash
sudo systemctl status lsyncd
sudo tail -f /var/log/lsyncd.log
```

**Q. 同期が遅い / 早くしたいときは？**

`ansible/group_vars/all.yml` の `lsyncd_delay: 5` を小さくして Ansible を再実行。ただし小さすぎると細かい操作のたびに rsync が走り負荷が増える。

**Q. ポート22を開けないのに Ansible が動くのはなぜ？**

`ansible.cfg` の `ssh_args` に SSM を ProxyCommand として設定してある。SSM Agent が EC2 内で動いていて、AWS API 経由でトンネルを張る。

---

## トラブルシューティング

| 症状 | 原因候補 | 確認コマンド |
|---|---|---|
| Ansible が接続できない | SSM Agent 未起動 / IAM ロール欠落 | `aws ssm describe-instance-information` |
| slave に同期されない | lsyncd が停止 / known_hosts 未登録 | `sudo tail -f /var/log/lsyncd.log`（master）|
| rsync が Permission denied | authorized_keys に公開鍵がない | `cat ~/.ssh/authorized_keys`（slave）|
| ansible-inventory が空 | EC2 が stopped / Tag 名が違う | `aws ec2 describe-instances` でタグ確認 |

---

## コストと後片付け

月額約 **$32**（t3.micro × 3 台 + EBS）。ハンズオン後は必ず削除:

```bash
cd terraform
terraform destroy   # ← 全リソースが削除される
```

---

## 設計判断のメモ（ADR-001）

NFS と lsyncd + rsync over SSH を比較して lsyncd を選んだ理由:

- NFS はサーバーが単一障害点になる。lsyncd なら slave は最後の同期内容を保持できる
- NFS はポートを開ける必要がある。lsyncd は SSH だけで完結
- rsync は差分のみ転送するので帯域が少ない

**トレードオフ**: lsyncd は非同期（5 秒遅延）。NFS はファイルシステムとして即時反映される。ハンズオン用途では 5 秒は許容範囲と判断した。
