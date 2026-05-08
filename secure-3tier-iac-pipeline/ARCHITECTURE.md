# secure-3tier-iac-pipeline 完全理解ドキュメント

> 作成日: 2026-05-05

---

## このプロジェクトで何を学ぶか

「本番で使えるAWSインフラを、コードだけで作る」のがゴール。

具体的には、以下の3つを組み合わせてセキュアな Web アプリ基盤を構築する:

- **Terraform** — インフラをコードで定義・管理
- **Ansible** — サーバーの設定・アプリのデプロイを自動化
- **AWS セキュリティサービス群** — IAM / KMS / Secrets Manager / SSM / VPC など

---

## 目次

1. [作るものの全体像](#1-作るものの全体像)
2. [ファイル構成と役割](#2-ファイル構成と役割)
3. [ネットワーク設計 — なぜこの構成か](#3-ネットワーク設計--なぜこの構成か)
4. [セキュリティ設計 — 6つの防御層](#4-セキュリティ設計--6つの防御層)
5. [Terraform モジュール詳細](#5-terraform-モジュール詳細)
6. [Ansible 実装詳細](#6-ansible-実装詳細)
7. [フェーズ別 実装チェックリスト](#7-フェーズ別-実装チェックリスト)
8. [運用・監視の全体像](#8-運用監視の全体像)
9. [よく使うコマンド集](#9-よく使うコマンド集)

---

## 1. 作るものの全体像

### システム構成図

```
【ユーザーのブラウザ】
        |
        | HTTPS (443) / HTTP (80)
        ↓
┌─────────────────────────────────────────┐
│           パブリックサブネット            │ ← インターネットに面している唯一の層
│   [ ALB: Application Load Balancer ]    │
│     172.16.0.0/24  (1a)                 │
│     172.16.1.0/24  (1c)                 │
│     172.16.2.0/24  (1d)                 │
└────────────────┬────────────────────────┘
                 |
                 | :8080 (ALB → EC2 のみ許可)
                 ↓
┌─────────────────────────────────────────┐
│          プライベートサブネット           │ ← インターネットから直接見えない
│   [ EC2 Auto Scaling Group ]            │
│     Nginx → Gunicorn → Python Flask     │
│     172.16.10.0/24 (1a)                 │
│     172.16.11.0/24 (1c)                 │
│     172.16.12.0/24 (1d)                 │
└────────────────┬────────────────────────┘
                 |
                 | :3306 (EC2 → RDS のみ許可)
                 ↓
┌─────────────────────────────────────────┐
│           データサブネット               │ ← インターネットへのルートなし
│   [ RDS Aurora MySQL Serverless v2 ]    │
│     Writer + Reader (自動スケーリング)   │
│     172.16.20.0/24 (1a)                 │
│     172.16.21.0/24 (1c)                 │
│     172.16.22.0/24 (1d)                 │
└─────────────────────────────────────────┘
```

**3層にする理由:** 役割が違うものを分離すると、一か所が侵害されても他に波及しにくい。ALB だけがインターネットに面していれば、EC2 や RDS は攻撃者から直接見えない。

---

### 技術スタック早見表

| 何をするか | 使う技術 | なぜ |
|---|---|---|
| インフラ定義 | Terraform >= 1.7 | コードで管理 = 再現性・レビュー可能 |
| OS 強化・アプリ配置 | Ansible | 冪等な自動化、SSH不要(SSM経由) |
| ネットワーク | VPC / Subnet / NACL / SG | 多層防御 |
| コンピュート | EC2 ASG + ALB | 可用性・自動スケール |
| データベース | Aurora Serverless v2 | 負荷に応じた自動スケール |
| 暗号化キー | KMS CMK | EBS/RDS/S3 を同じキーで暗号化 |
| パスワード管理 | Secrets Manager | 自動ローテーション、コードに書かない |
| サーバーアクセス | SSM Session Manager | SSH ポート 22 を開けない |
| インスタンスタイプ | t4g.small (Graviton arm64) | x86 比 20% 安い |

---

## 2. ファイル構成と役割

```
secure-3tier-iac-pipeline/
│
├── phase1.md 〜 phase4.md   ← Claude Code への実装指示書
│
├── terraform/
│   ├── envs/prod/           ← 「本番環境」の設定をまとめる場所
│   │   ├── main.tf          ← 全モジュールを呼び出す司令塔
│   │   ├── kms.tf           ← 暗号化キー(全モジュール共通)
│   │   ├── secrets_manager.tf ← RDS パスワードと自動ローテーション
│   │   ├── backend.tf       ← tfstate の保存先(S3 + DynamoDB)
│   │   ├── variables.tf     ← 入力変数の定義
│   │   └── outputs.tf       ← 25 以上のアウトプット
│   │
│   └── modules/             ← 再利用可能なモジュール群
│       ├── network/         ← VPC・サブネット・NACL・Flow Logs
│       ├── security/        ← IAM ロール・セキュリティグループ・S3
│       ├── compute/         ← ALB・Launch Template・ASG
│       ├── database/        ← RDS Aurora Serverless v2
│       └── ssm/             ← Session Manager・Parameter Store
│
├── ansible/
│   ├── site.yml             ← フルセット実行(hardening + deploy)
│   ├── hardening.yml        ← OS 強化だけ
│   ├── drift_check.yml      ← 設定ズレの検出
│   ├── inventories/
│   │   └── aws_ec2.yml      ← EC2 タグから自動でホスト一覧を作る
│   ├── group_vars/
│   │   └── all/vault.yml    ← Ansible Vault で暗号化したシークレット
│   └── roles/
│       ├── os_hardening/    ← CIS Benchmark Level 1 準拠
│       ├── app_deploy/      ← Nginx + Python + systemd
│       └── drift_detection/ ← ドリフト検出 + Chatwork 通知
│
└── scripts/
    ├── bootstrap.sh         ← S3 バケット + DynamoDB を最初に作る
    ├── run_ansible.sh       ← Ansible 実行のラッパー
    └── run_drift_check.sh   ← ドリフト検出の実行ラッパー
```

### モジュール間の依存関係

```
  kms.tf (暗号化キー)
  secrets_manager.tf (RDS パスワード)
       │
       ├──────────────┐
       ↓              ↓
  [network]      (VPC ID / Subnet IDs)
       │
       ↓
  [security]     (SG IDs / IAM Profile)
       │
       ├──→ [compute]   (ALB + ASG)
       │
       └──→ [database]  (Aurora)
                │
                ↓
             [ssm]      (Parameter Store に DB 接続情報を登録)
```

上から順に作らないとエラーになる。`terraform apply` は依存関係を自動解決してくれるが、手動で作業する場合はこの順番を意識する。

---

## 3. ネットワーク設計 — なぜこの構成か

### サブネットの設計思想

```
インターネット
    ↓ (Internet Gateway)
パブリックサブネット (172.16.0-2.0/24)
  → ALB だけ置く。EC2 は絶対に置かない。
    ↓ (NAT Gateway 経由でアウトバウンドのみ)
プライベートサブネット (172.16.10-12.0/24)
  → EC2 を置く。インターネットから見えない。
  → AWS API (SSM, Secrets Manager 等) には VPC Endpoint 経由でアクセス
    ↓ (アウトバウンドルートなし)
データサブネット (172.16.20-22.0/24)
  → RDS だけ置く。インターネットへの経路が存在しない。
```

**なぜ AZ を 3 つ使うか:**
1a / 1c / 1d に分散することで、1 つの AZ で障害が起きても残り 2 つで稼働継続できる。

**なぜ NAT Gateway を AZ ごとに用意するか:**
NAT を 1 台にまとめると、その AZ が落ちた瞬間にプライベートサブネット全体のアウトバウンドが止まる。AZ ごとに 1 台ずつ置くと障害が局所化できる(コストは 3 倍になる)。

---

### フィルタリングの二重防御

```
外部 → [NACL] → [Security Group] → EC2 / RDS

NACL:            ステートレス。インバウンドとアウトバウンドを両方書く必要がある。
Security Group:  ステートフル。インバウンドを許可するとレスポンスは自動で通る。
```

| NACL の種類 | 何を許可するか |
|---|---|
| パブリック NACL | 外部からの 80/443、エフェメラルポートの返り |
| プライベート NACL | VPC 内部からの通信、443 アウトバウンド (AWS API 用) |
| データ NACL | プライベートサブネットからの 3306 のみ |

---

### VPC Endpoint — NAT を使わず AWS サービスへ

```
【NAT 経由 (Endpoint なし)】
  EC2 → NAT Gateway → Internet → S3 / SSM / Secrets Manager
  問題: インターネット経由、NAT 費用がかかる

【VPC Endpoint 経由】
  EC2 → VPC Endpoint → S3 / SSM / Secrets Manager
  利点: AWS バックボーン内で完結、セキュア、NAT 不要
```

| Endpoint の種類 | 対象サービス | 費用 |
|---|---|---|
| Gateway 型 | S3, DynamoDB | 無料 |
| Interface 型 | SSM / SSMMessages / EC2Messages / Secrets Manager / CloudWatch Logs / KMS | 約 $7.5/月 × 6 本 |

---

## 4. セキュリティ設計 — 6つの防御層

### 全体図

```
┌──────────────────────────────────────────────┐
│ Layer 1: ネットワーク境界                     │
│   VPC / NACL / Security Group による隔離      │
├──────────────────────────────────────────────┤
│ Layer 2: アクセス制御                         │
│   IAM 最小権限 / SSM Session Manager / IMDSv2 │
├──────────────────────────────────────────────┤
│ Layer 3: 暗号化                               │
│   KMS CMK (EBS・RDS・S3・Secrets Manager)     │
├──────────────────────────────────────────────┤
│ Layer 4: シークレット管理                     │
│   Secrets Manager / Parameter Store / Vault  │
├──────────────────────────────────────────────┤
│ Layer 5: 監査ログ                             │
│   VPC Flow Logs / ALB Logs / RDS Audit / SSM │
├──────────────────────────────────────────────┤
│ Layer 6: OS 強化 (Ansible)                    │
│   CIS Benchmark / auditd / ドリフト検出       │
└──────────────────────────────────────────────┘
```

---

### Layer 1: セキュリティグループの連鎖

```
インターネット
  → ALB SG (80/443 のみ受け付け)
       ↓ 8080 のみ EC2 SG に転送
  → EC2 SG (ALB SG からの 8080 のみ受け付け。SSH は存在しない)
       ↓ 3306 のみ RDS SG に転送
  → RDS SG (EC2 SG からの 3306 のみ受け付け)
```

**重要:** EC2 の SG には SSH ポート(22)の記述がない。サーバーに入るには必ず SSM Session Manager を使う。

---

### Layer 2: IMDSv2 の強制とは

EC2 には「インスタンスメタデータ」という機能がある。これは `http://169.254.169.254/` にアクセスすると IAM の一時クレデンシャルを取得できる仕組みだ。

**問題 (IMDSv1):**
Web アプリに SSRF 脆弱性があると、攻撃者はアプリ経由でこの URL を叩き、IAM キーを盗める。

**解決 (IMDSv2):**
```hcl
metadata_options {
  http_tokens                 = "required"  # セッショントークンがないと応答しない
  http_put_response_hop_limit = 1           # コンテナ内からのアクセスをブロック
}
```
セッショントークンの取得には PUT リクエストが必要。SSRF は GET しか使えないため、攻撃できない。

---

### Layer 3: KMS CMK — 1 本のキーで全部暗号化

```
KMS CMK (alias/s3t-prod-main)
    ├── EBS ボリューム暗号化
    ├── RDS Aurora 暗号化
    ├── S3 バケット (セッションログ・ALB ログ・アプリデータ) 暗号化
    └── Secrets Manager 暗号化
```

**なぜ CMK を使うか:**
AWS デフォルトキー (aws/xxx) では「誰がいつキーを使ったか」のログが取れない。CMK なら CloudTrail で全アクセスを追跡できる。

**誤削除防止:**
```hcl
lifecycle {
  prevent_destroy = true  # terraform destroy でもエラーになる
}
```
KMS キーを削除すると、暗号化していたデータが永久に復号できなくなる。

---

### Layer 4: シークレット管理の流れ

```
【RDS パスワード】
  random_password (Terraform)
        ↓ 保存
  Secrets Manager (ata-prod/rds/master-password)
        ↓ 30 日ごとに自動ローテーション (AWS Lambda)
  RDS Aurora ← Terraform: ignore_changes = [master_password]
        ↓ EC2 が取得
  EC2 IAM ロール → GetSecretValue → パスワード取得

【DB 接続情報】
  Terraform → Parameter Store (SecureString)
  EC2 → GetParameter → DB エンドポイント・ポート・DB 名

【Ansible シークレット】
  Ansible Vault で暗号化 → Git に安全にコミット可能
```

---

### Layer 5: ログ一覧

| ログ | 保存先 | 保持期間 | 何を記録するか |
|---|---|---|---|
| VPC Flow Logs | CloudWatch Logs | 90 日 | VPC 内の全通信 (許可・拒否) |
| ALB Access Logs | S3 | 90 日 | HTTP リクエスト・レスポンス |
| Session Manager Logs | S3 + CloudWatch | 90 日 | サーバーにした操作コマンド |
| RDS Audit Logs | CloudWatch | 90 日 | DB 操作ログ (誰が何をしたか) |
| RDS Error Logs | CloudWatch | 90 日 | DB エラー |
| RDS Slow Query | CloudWatch | 30 日 | 遅いクエリ (パフォーマンス分析) |

---

## 5. Terraform モジュール詳細

### network モジュール

主なリソース:
- VPC (172.16.0.0/16)
- サブネット 9 個 (3 層 × 3AZ)
- Internet Gateway
- NAT Gateway × 3 (AZ ごと)
- Route Table (public / private / data の 3 種)
- NACL (public / private / data の 3 種)
- VPC Flow Logs (CloudWatch Logs)
- VPC Endpoints (S3・DynamoDB・SSM・SecretsManager 等 8 本)

---

### security モジュール

**EC2 IAM ロール (`s3t-prod-ec2-role`) の権限:**

| 何のために | 許可するアクション | スコープ |
|---|---|---|
| SSM 基本動作 | マネージドポリシー | AmazonSSMManagedInstanceCore |
| Session Manager | ssm:StartSession 等 | 必要なアクションのみ |
| DB パスワード取得 | secretsmanager:GetSecretValue | `ata-prod/rds/*` のみ |
| メトリクス送信 | cloudwatch:PutMetricData 等 | 全リージョン |
| 暗号化 | kms:Decrypt / GenerateDataKey | CMK ARN 指定 |
| セッションログ保存 | s3:PutObject | `sessions/*` prefix のみ |

**ポイント:** `iam:*` や `*` は一切使わない。アクションもリソースも必ず明示する。

---

### compute モジュール

**Launch Template の重要設定:**

```hcl
# コスト最適化: Graviton arm64 (x86 比 20% 安い)
instance_type = "t4g.small"

# セキュリティ: IMDSv2 強制
metadata_options {
  http_tokens = "required"
}

# セキュリティ: パブリック IP なし
network_interfaces {
  associate_public_ip_address = false
}

# 暗号化: KMS CMK で EBS を暗号化
ebs_block_device {
  encrypted  = true
  kms_key_id = var.kms_key_arn
}
```

**ASG のスケーリング動作:**

```
通常時: min=2, desired=2 (2台で稼働)
         ↓ CPU が 60% を超えると
自動増加: desired が増える (最大 6 台まで)
         ↓ CPU が下がると
自動減少: desired が減る (最小 2 台まで)

デプロイ時 (Instance Refresh):
  50% 以上の健全なインスタンスを保ちながらローリング更新
  新インスタンスは 120 秒のウォームアップ後にトラフィックを受ける
```

**ALB のリスナー動作:**

```
HTTP (80):
  enable_https = true  → 301 リダイレクト → HTTPS
  enable_https = false → そのまま転送 → EC2:8080

HTTPS (443):
  TLS ポリシー: TLS13-1-2-2021-06 (TLS 1.3 対応)
  → EC2:8080 に転送
```

---

### database モジュール

**Aurora Serverless v2 のスケーリング:**

```
0.5 ACU (最小) ←→ 4.0 ACU (最大)
  ↑負荷に応じて自動で変化
  
ACU = Aurora Capacity Unit
0.5 ACU ≈ 0.5 vCPU + 1 GB RAM 相当
```

**忘れずに設定するポイント:**

```hcl
# Secrets Manager でパスワードを変えても Terraform が上書きしないようにする
lifecycle {
  ignore_changes = [master_password]
}
```

**DB ログの保持期間を分けている理由:**
- Audit (90日): 誰が操作したかの証跡 → コンプライアンス要件のため長め
- Slow Query (30日): パフォーマンス分析用 → 解析したらすぐ不要になるため短め

---

### ssm モジュール

**Session Manager の動作:**

```
開発者の PC
    ↓ (aws ssm start-session --target i-xxxx)
AWS Systems Manager
    ↓ (HTTPS 443 経由 / VPC Endpoint 使用)
EC2 インスタンス (SSM Agent)
    ↓ セッションを記録
S3 + CloudWatch Logs
```

22 番ポートを一切使わないのがポイント。セキュリティグループに SSH の記述がなくてもサーバーに入れる。

**Parameter Store に入れる値:**

```
/ata-prod/app/db_endpoint        → Aurora Writer のエンドポイント
/ata-prod/app/db_reader_endpoint → Aurora Reader のエンドポイント
/ata-prod/app/db_port            → 3306
/ata-prod/app/db_name            → appdb
```

これらは Terraform が Aurora を作った後に自動で書き込む。EC2 は起動時にここから値を取得する。

---

## 6. Ansible 実装詳細

### 動的インベントリの仕組み

「どのサーバーに対して実行するか」をタグで自動決定する。

```
Terraform (asg.tf) で EC2 に付けるタグ:
  Role        = "webserver"
  Environment = "prod"
  Project     = "secure-3tier-iac-pipeline"
        ↓
Ansible (aws_ec2.yml) がタグを読んでグループを自動生成:
  role_webserver グループ → このグループに対してプレイブックを実行
```

手動でホスト一覧を管理しなくてよい。インスタンスが増減しても自動で追従する。

---

### 3 つのプレイブック

| 実行コマンド | 何をするか | いつ使うか |
|---|---|---|
| `site.yml` | OS 強化 + アプリデプロイ | 初回構築・フルリセット |
| `hardening.yml` | OS 強化のみ | セキュリティ設定の再適用 |
| `drift_check.yml` | 設定ズレの検出 | 定期チェック (変更はしない) |

---

### os_hardening ロール — 何を強化するか

**kernel.yml (sysctl で OS の動作を変える):**

| 設定 | 何を防ぐか |
|---|---|
| rp_filter = 1 | IP スプーフィング攻撃 |
| accept_redirects = 0 | ICMP リダイレクト攻撃 |
| tcp_syncookies = 1 | SYN Flood (DoS 攻撃の一種) |
| ip_forward = 0 | EC2 がルーターになることを防ぐ |
| randomize_va_space = 2 | メモリアドレスをランダム化 (ROP 攻撃対策) |

**users.yml:**
- パスワード: 14 文字以上、英数大小+記号必須
- root 直接ログイン: 禁止
- アプリ用 OS ユーザー: `/sbin/nologin` (シェルに入れない system アカウント)

**audit.yml:**
- auditd でカーネルレベルの操作を記録
- `-e 2` フラグ: 再起動するまでルール変更をロック (auditd のルール改ざん防止)

---

### app_deploy ロール — アプリの構成

```
外部リクエスト → Nginx (ポート 80)
                  ↓ リバースプロキシ
               Gunicorn (ポート 8080)  ← systemd で管理
                  ↓
             Python Flask アプリ
                  ↓
             Aurora MySQL (ポート 3306)
```

**Nginx の役割:**
- `/health` エンドポイントで 200 OK を返す → ALB のヘルスチェック用
- セキュリティヘッダーを付与 (X-Frame-Options, HSTS 等)
- `server_tokens off` → Nginx のバージョンを外に見せない

**systemd サービスのセキュリティ設定:**

```ini
NoNewPrivileges=true    # プロセスが特権昇格できない
ProtectSystem=strict    # OS のシステムディレクトリを書き換えられない
PrivateTmp=true         # /tmp を専用の空間に隔離
ProtectHome=true        # /home にアクセスできない
```

これらは systemd レベルでプロセスを「箱に入れる」設定。アプリが侵害されても被害を最小化できる。

---

### drift_detection ロール — 設定ズレの検出

**「ドリフト」とは何か:**
Terraform・Ansible でコードとして定義した状態から、実際のサーバーの設定がズレてしまうこと。手動変更や予期しない更新で発生する。

**検出の仕組み:**

```
ansible-playbook drift_check.yml --check --diff
  → 実際には変更しない (--check)
  → 差分だけ表示する (--diff)

差分があれば → Chatwork API に通知
          ホスト名・タイムスタンプ・ドリフトした箇所を報告
```

---

## 7. フェーズ別 実装チェックリスト

### Phase 1: tfstate バックエンド + ネットワーク

```bash
bash scripts/bootstrap.sh   # 最初に 1 回だけ実行
```

- [ ] S3 バケット (`s3t-prod-tfstate-{account_id}`) が作成された
- [ ] DynamoDB テーブル (`s3t-prod-tfstate-lock`) が作成された
- [ ] `terraform init` が通る
- [ ] VPC (172.16.0.0/16) が作成された
- [ ] パブリック・プライベート・データの 9 サブネットが作成された
- [ ] NAT Gateway が 3 台 (AZ ごとに 1 台) 作成された
- [ ] NACL が 3 種類 (public / private / data) 設定された
- [ ] VPC Flow Logs が有効になった
- [ ] VPC Endpoints (S3・SSM 等) が作成された

---

### Phase 2: セキュリティ層 + コンピュート層

- [ ] KMS CMK が作成された (年次ローテーション有効)
- [ ] Secrets Manager に RDS パスワードが保存された
- [ ] EC2 IAM ロール + インスタンスプロファイルが作成された
- [ ] ALB / EC2 / RDS の 3 つのセキュリティグループが作成された
- [ ] Session Manager ログ用 S3 バケットが作成された
- [ ] ALB が作成された (アクセスログ → S3)
- [ ] Launch Template が作成された (IMDSv2 強制・Graviton)
- [ ] ASG が作成された (min:2, max:6, CPU 60% スケーリング)

---

### Phase 3: データ層 + SSM

- [ ] Aurora クラスターが作成された (Serverless v2, 0.5〜4.0 ACU)
- [ ] Writer / Reader インスタンスが作成された
- [ ] RDS の監査・エラー・スロークエリログが CloudWatch に出力された
- [ ] Secrets Manager の自動ローテーションが設定された (30 日間隔)
- [ ] Session Manager ドキュメントが作成された
- [ ] Parameter Store に 4 つのパラメーターが登録された

**動作確認:**

```bash
# SSM でサーバーに入れるか確認
aws ssm start-session --target <instance-id>

# DB 接続情報が取れるか確認
aws ssm get-parameter --name /ata-prod/app/db_endpoint --with-decryption
```

---

### Phase 4: Ansible 全実装

**前提確認:**

```bash
# 動的インベントリでインスタンスが見えるか確認
ansible-inventory -i ansible/inventories/aws_ec2.yml --graph
# 期待値: role_webserver グループに EC2 が表示される
```

- [ ] 動的インベントリで EC2 インスタンスが `role_webserver` グループに自動検出された
- [ ] `os_hardening` ロールが完了した (kernel / users / services / audit)
- [ ] `app_deploy` ロールが完了した (nginx / python_app / systemd)
- [ ] ALB のヘルスチェック (`/health`) が 200 OK を返している
- [ ] `drift_detection` ロールが動作した
- [ ] ドリフトがある状態で Chatwork に通知が届いた

---

## 8. 運用・監視の全体像

### サーバーへの接続方法

```bash
# インスタンス ID を確認
aws ec2 describe-instances \
  --filters "Name=tag:Role,Values=webserver" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" --output text

# SSM で接続 (SSH 不要)
aws ssm start-session --target i-xxxxxxxxxxxxxxxxx

# RDS に接続したい場合 (ポートフォワード)
aws ssm start-session \
  --target i-xxxxxxxxxxxxxxxxx \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=<aurora-endpoint>,portNumber=3306,localPortNumber=13306"
# → localhost:13306 で Aurora に接続できる
```

---

### ドリフト検出の自動化フロー

```
EventBridge (毎日 09:00 など)
    ↓ トリガー
run_drift_check.sh
    ↓ 実行
ansible-playbook drift_check.yml --check --diff
    ↓ 差分を検出
Chatwork API に通知
  「host: i-xxxx / 2026-05-05 09:00 / nginx.conf がズレています」
```

---

### スケーリングの動作フロー

```
[通常] 2 台稼働
    ↓ CPU が 60% を超える
[スケールアウト] 3 台 → 4 台 → 最大 6 台
  新インスタンス起動 → ALB ヘルスチェック通過 → トラフィック受信
    ↓ CPU が下がる
[スケールイン] 徐々に削減 → 最小 2 台に戻る
```

---

### コスト最適化ポイント一覧

| 施策 | どこで設定 | 効果 |
|---|---|---|
| Graviton arm64 (t4g.small) | Launch Template | x86 比 20% 安い |
| Aurora Serverless v2 (min 0.5 ACU) | database モジュール | 低負荷時に自動縮小 |
| S3 Gateway Endpoint | network/endpoints.tf | S3 通信の NAT 費用ゼロ |
| gp3 EBS (vs gp2) | Launch Template | 約 20% ストレージ安い |
| S3 Glacier IR 移行ルール | security モジュール | 90 日後のログを自動で安くする |

---

## 9. よく使うコマンド集

### Terraform

```bash
cd terraform/envs/prod

terraform init          # 初回 or .terraform を消した後
terraform validate      # 構文チェック
terraform fmt -recursive # コードフォーマット
terraform plan          # 変更内容のプレビュー (実際には変更しない)
# apply / destroy / import はユーザー自身が実行すること
```

### Ansible

```bash
cd ansible

# インベントリ確認
ansible-inventory -i inventories/aws_ec2.yml --graph
ansible-inventory -i inventories/aws_ec2.yml --list

# プレイブック実行
bash ../scripts/run_ansible.sh site.yml       # OS 強化 + デプロイ
bash ../scripts/run_ansible.sh hardening.yml  # OS 強化のみ
bash ../scripts/run_drift_check.sh            # ドリフト検出

# Vault 操作
ansible-vault encrypt group_vars/all/vault.yml   # 暗号化
ansible-vault view    group_vars/all/vault.yml   # 内容確認
ansible-vault edit    group_vars/all/vault.yml   # 編集
```

### AWS CLI

```bash
# SSM でサーバーに接続
aws ssm start-session --target <instance-id>

# Parameter Store の値を確認
aws ssm get-parameter --name /ata-prod/app/db_endpoint --with-decryption

# Secrets Manager のシークレットを確認
aws secretsmanager get-secret-value --secret-id ata-prod/rds/master-password

# 稼働中の webserver インスタンス一覧
aws ec2 describe-instances \
  --filters "Name=tag:Role,Values=webserver" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].[InstanceId,PrivateIpAddress]" \
  --output table
```

---

## 禁止パターンまとめ (なぜダメか付き)

| やってはいけないこと | なぜダメか |
|---|---|
| SG の全インバウンドに `0.0.0.0/0` を設定 | 全インターネットから直接アクセス可能になる |
| IMDSv1 を使う (`http_tokens = "optional"`) | SSRF 脆弱性があると IAM キーが盗まれる |
| EC2 をパブリックサブネットに置く | インターネットから直接見えてしまう |
| SSH ポート(22)を SG で開ける | Brute force 攻撃のターゲットになる |
| コードに AWS クレデンシャルをハードコード | Git に流出すると即座に悪用される |
| `iam:*` や `*` を IAM ポリシーに書く | 権限昇格されると全 AWS リソースを操作される |
| Vault なしでシークレットを YAML に書く | Git にパスワードが残る |
| KMS キーを削除する | 暗号化したデータが永久に復号できなくなる |
