# ecs-dev 環境（ECS ハンズオン）
https://chatgpt.com/g/g-p-690ea2b2c5948191a108d07e18727e7f-terraform/c/69535266-0324-8324-ad1e-d2186169e8a9

## 1. 概要

本環境は Terraform を用いて ECS（Fargate）を中心とした AWS 構成を構築する
**学習・検証専用環境**です。

* 本番利用は禁止
* 破棄前提の環境（コスト発生あり）

---

## 2. 目的 / 学習テーマ

* ECS（Fargate）の基本構成を理解する
* ALB と ECS Service の連携を理解する
* Task Definition / IAM Role / CloudWatch Logs の関係を把握する
* ECR を用いた自作コンテナのデプロイを体験する
* ECS Service Auto Scaling（RequestCountPerTarget）を理解する
* Terraform による **環境分離・state 管理**に慣れる

---

## 3. 構成概要（論理）

### 作成される主なリソース

* VPC

  * Public Subnet（ALB / NAT）
  * Private Subnet（ECS Task）
* Application Load Balancer
* ECS Cluster（Fargate）
* ECS Service
* ECS Task Definition
* ECR（Lifecycle Policy 含む）
* CloudWatch Logs
* IAM

  * ECS Task Execution Role
  * ECS Task Role
* Application Auto Scaling

  * ALB RequestCountPerTarget ベース

※ すべて本環境専用リソースとして作成される

---

## 構成図（簡易ASCII）

```text
Internet
  |
  |  HTTP :80
  v
+-----------------------------+
|  ALB (Public Subnet)        |
|  handson-ecs-dev-alb        |
|                             |
|  SG: alb-sg                 |
|   - Ingress : 80 from 0.0.0.0/0
|   - Egress  : ALL           |
+---------------+-------------+
                |
                | forward (TargetGroup: ip)
                v
        +---------------------+
        | Target Group (ip)   |
        | HealthCheck: /healthz
        +----------+----------+
                   |
                   | SG reference
                   v
+--------------------------------------------------+
| VPC 10.0.0.0/16                                 |
|                                                  |
|  Public Subnets                                  |
|  ├─ 10.0.11.0/24 (ap-northeast-1a)               |
|  |    - ALB ENI                                  |
|  |    - NAT Gateway (1台構成)                    |
|  └─ 10.0.12.0/24 (ap-northeast-1c)               |
|       - ALB ENI                                  |
|                                                  |
|  Private Subnets                                 |
|  ├─ 10.0.21.0/24 (ap-northeast-1a)               |
|  |    - ECS Task (Fargate)                       |
|  |    SG: ecs-sg                                 |
|  |     - Ingress : 80 from alb-sg                |
|  |     - Egress  : ALL                           |
|  └─ 10.0.22.0/24 (ap-northeast-1c)               |
|       - ECS Task (Fargate)                       |
|                                                  |
|  Route                                          |
|   - Public RT : 0.0.0.0/0 -> IGW                 |
|   - Private RT: 0.0.0.0/0 -> NAT Gateway         |
+--------------------------------------------------+

ECS Task (Fargate)
  - Image pull : ECR (via NAT)
  - Logs       : CloudWatch Logs (via NAT)
  - AutoScale  : Application Auto Scaling
      metric = ALB RequestCountPerTarget
```

---

### 図の読み方（超短く）

* **ALB は Public Subnet** に配置（外部から到達可能）
* **ECS Task は Private Subnet**（Public IPなし）
* Private 側の外向き通信（ECR pull / Logs 送信）は **NAT 経由**
* スケールは **ALB の 1台あたりリクエスト数**で自動増減

## Security Group のポイント（README追記用・短文）

* **ALB SG**

  * 外部からの HTTP(80) を許可
  * ECS Task への通信元になる

* **ECS SG**

  * **ALB SG からの 80/TCP のみ許可**
  * Internet からの直接アクセス不可

👉 **「ALB を通らない通信は ECS に届かない」構成**

---

## この図で伝わる実務的ポイント

* Public / Private の責務分離
* SG を **CIDR ではなく SG 参照**で絞っている
* ECS は Public IP を持たず、外向き通信は NAT に限定
* スケール判断は **LB 視点（RequestCountPerTarget）**

---

これで README は
**「コードを見なくても構成と通信経路が理解できる」** 状態になりました。

次に仕上げるとしたらおすすめは：

* README に **「通信フロー（①〜⑤）」番号付き説明**
* modules/network 側にも **同じASCII図＋責務説明** を置く

どこまでドキュメントを磨きますか？




---

## 4. ディレクトリ構成

```text
ecs-dev/
├── README.md          # 本ファイル
├── backend.tf         # Terraform backend 定義（state 分離）
├── provider.tf        # AWS provider
├── versions.tf        # Terraform / provider バージョン
├── main.tf            # エントリーポイント
├── variables.tf       # 変数定義
├── terraform.tfvars   # 環境固有の値（※Git管理しない）
├── alb.tf             # ALB / Listener / TargetGroup
├── ecs.tf             # ECS Cluster / Service
├── taskdef.tf         # Task Definition
├── iam.tf             # IAM Role
├── logs.tf            # CloudWatch Logs
└── autoscaling.tf     # ECS Service Auto Scaling
```

※ network は `modules/network` として共通化済み

---

## 5. 事前準備

### 必要ツール

* Terraform
* AWS CLI
* Docker（ECR push 用）

### AWS 認証

```bash
aws configure
```

または

```bash
export AWS_PROFILE=your-profile
```

---

## 6. Terraform 実行手順

### 6.1 初期化

```bash
cd ecs-dev
terraform init
```

### 6.2 構文チェック

```bash
terraform validate
```

### 6.3 実行計画の確認

```bash
terraform plan
```

### 6.4 構築

```bash
terraform apply
```

---

## 7. 動作確認

### 7.1 ALB の URL 取得

```bash
terraform output alb_dns_name
```

### 7.2 アクセス確認

```bash
curl http://$(terraform output -raw alb_dns_name)/
curl http://$(terraform output -raw alb_dns_name)/healthz
```

---

## 8. ECR + 自作コンテナ（任意）
⚠️ 初回構築時の注意  
ECS Task は ECR 上のイメージを参照するため、
**ECR にイメージを push する前に Service が起動すると失敗する**。

初回は以下の順で実行すること：
1. terraform apply（ECR 作成）
2. ECR に v1 イメージを push
3. terraform apply（ECS 再デプロイ）


### 8.1 ECR ログイン

```bash
aws ecr get-login-password \
  | docker login --username AWS --password-stdin $(terraform output -raw ecr_repository_url | cut -d/ -f1)
```

### 8.2 イメージ build & push
※ Task Definition では `image_tag = "v1"` を参照しているため、
ECR には必ず `:v1` タグのイメージを push すること。

```bash
# v1 タグで build & push（Terraform が参照するタグ）

# 変数定義
REPO=$(terraform output -raw ecr_repository_url)
TAG=v1

# ----------------------------------------
# ① ローカル用の名前で Docker イメージを作成
#   - ecs-dev-app:${TAG} はローカルでの識別名
#   - 実体（IMAGE ID）はこの時点で作られる
docker build -t ecs-dev-app:${TAG} app/

# ----------------------------------------
# ② 同じ IMAGE ID に、ECR 用の正式な名前（タグ）を付ける
#   - docker tag はコピーではなく「別名（エイリアス）を付ける」だけ
#   - ecs-dev-app:${TAG} と ${REPO}:${TAG} は中身が同じ
docker tag ecs-dev-app:${TAG} ${REPO}:${TAG}

# ----------------------------------------
# ③ ECR 用の名前（タグ）を使って ECR に push
#   - ECS はこの ${REPO}:${TAG} を参照してイメージを pull する
docker push ${REPO}:${TAG}
```
※ docker tag はイメージをコピーするのではなく、同じ IMAGE ID に別名を付ける操作です。


### 8.3 ECS 再デプロイ

```bash
terraform apply
```

---

## 9. Auto Scaling 動作確認（負荷テスト）

### curl 並列ループ（ツール不要）

```bash
ALB="http://$(terraform output -raw alb_dns_name)/"

while true; do
  for i in {1..100}; do
    curl -s "$ALB" >/dev/null &
  done
  wait
done
```

### スケール状態確認

```bash
aws ecs describe-services \
  --cluster $(terraform output -raw ecs_cluster_name) \
  --services $(terraform output -raw ecs_service_name) \
  --query "services[0].{desired:desiredCount,running:runningCount,pending:pendingCount}" \
  --output table
```

---

## 10. 破棄（必ず実施）

⚠️ **NAT Gateway などの課金リソースが含まれるため、検証後は必ず破棄すること**

```bash
terraform destroy
```

---

## 11. 注意事項

* 本環境は **学習・検証用途のみ**
* 長時間放置しない（特に NAT Gateway）
* terraform.tfvars は Git 管理しない

---

## 12. 次のステップ（発展）

* VPC Endpoint 導入による NAT コスト削減
* Blue/Green デプロイ（CodeDeploy）
* ECS Service / Task Definition の module 化
* 環境追加（ecs-stg / ecs-prod）

---



  


了解。**この環境（Terraform + ECR + ECS）で「壊して学ぶ」**を、**各フェーズごとに「どのファイルのどこを変える→何を打つ→何を見る→戻し方」**まで、手順書として出します。
（`hey/ab` なし前提で、負荷は `curl` ループでいきます）

前提：ディレクトリは `ecs-dev/`、ECR へ push → `terraform apply` で更新、という流れ。

---

# 0) 共通：観察用コマンド（最初に用意）

## 0-1) 変数（毎回使う）

```bash
cd ecs-dev
export ALB="http://$(terraform output -raw alb_dns_name)/"
export CLUSTER="$(terraform output -raw ecs_cluster_name)"
export SERVICE="$(terraform output -raw ecs_service_name)"
export ECR_URL="$(terraform output -raw ecr_repository_url)"
```

## 0-2) サービス状態を継続観察（別ターミナル推奨）

```bash
watch -n 5 '
aws ecs describe-services \
  --cluster '"$CLUSTER"' \
  --services '"$SERVICE"' \
  --query "services[0].{desired:desiredCount,running:runningCount,pending:pendingCount}" \
  --output table
'
```

## 0-3) ECSイベント（何が起きてるかのログ）

```bash
aws ecs describe-services \
  --cluster "$CLUSTER" \
  --services "$SERVICE" \
  --query "services[0].events[0:15].message" \
  --output text
```

## 0-4) ALB 健康確認

```bash
curl -i "$ALB"
curl -i "${ALB}healthz"
```

---

# 1) Phase1：タスク即死（再起動ループを体感）

## 変更するファイル

* **アプリ側**：`app/Dockerfile`（あなたの自作コンテナの Dockerfile）

  * もしルートに Dockerfile があるなら `./Dockerfile`

## どこをどう変える？

最後の `CMD`（または `ENTRYPOINT`）を次に置き換え：

```dockerfile
CMD ["sh", "-c", "echo BOOM && sleep 5 && exit 1"]
```

## 実行コマンド（push → 反映）

```bash
# 変数定義
REPO=$(terraform output -raw ecr_repository_url)
TAG=v1

docker build -t ecs-dev-app:${TAG} app
docker tag ecs-dev-app:${TAG} ${REPO}:${TAG}
docker push ${REPO}:${TAG}
terraform apply
```

## 何を見る？

* 観察ウィンドウで `running` が安定しない（0↔1）
* ECS events に「task stopped」「restarted」系

```bash
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query "services[0].events[0:10].message" --output text
```

## 元に戻す

Dockerfile の CMD を正常に戻して同じ手順で push → apply。

---

# 2) Phase2：ヘルスチェック失敗（起動してるのに 503）

## 変更するファイル（2択）

### (A) アプリで `/healthz` を 500 にする（おすすめ）

* `app/` のアプリ実装（例：nginx設定 or アプリコード）

  * 例：nginxなら `app/nginx.conf` や `default.conf`

### (B) Terraform 側で health check path を間違える（手軽）

* **Terraform**：`alb.tf` の TargetGroup health_check.path

---

## (B) でやる：どこをどう変える？

`ecs-dev/alb.tf` の **aws_lb_target_group.this**（または同等）で

```hcl
health_check {
  path = "/healthz"
}
```

を

```hcl
health_check {
  path = "/badhealth"
}
```

に変更。

## 実行コマンド

```bash
terraform apply
```

## 何を見る？

* `curl "$ALB"` が **503** になったり不安定
* ECS は running 1 のままのことが多い（ここが学び）

確認：

```bash
curl -i "$ALB"
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query "services[0].{desired:desiredCount,running:runningCount}" --output table
```

## 元に戻す

`/healthz` に戻して `terraform apply`

---

# 3) Phase3：CPU 暴走（遅くなるが落ちない）

## 変更するファイル

* `app/Dockerfile`

## どこをどう変える？

CMD をこれに：

```dockerfile
CMD ["sh", "-c", "yes > /dev/null"]
```

## 実行（push → apply）

```bash
# 変数定義
REPO=$(terraform output -raw ecr_repository_url)
TAG=v1

docker build -t ecs-dev-app:${TAG} app
docker tag ecs-dev-app:${TAG} ${REPO}:${TAG}
docker push ${REPO}:${TAG}
terraform apply
```

## 負荷を当てる（curl 並列）

```bash
while true; do
  for i in {1..50}; do
    curl -s "$ALB" >/dev/null &
  done
  wait
done
```

## 何を見る？

* レスポンスが遅くなる
* Auto Scaling が効いて `desired/running` が増える

---

# 4) Phase4：Memory OOM（落ちる・再起動ループ）

## 変更するファイル

* `app/Dockerfile`

## どこをどう変える？

CMD をこれに：

```dockerfile
CMD ["sh", "-c", "python - <<EOF\nx=[]\nwhile True: x.append(\"a\"*1024*1024)\nEOF"]
```

## 実行（push → apply）

```bash
# 変数定義
REPO=$(terraform output -raw ecr_repository_url)
TAG=v1

docker build -t ecs-dev-app:${TAG} app
docker tag ecs-dev-app:${TAG} ${REPO}:${TAG}
docker push ${REPO}:${TAG}
terraform apply
```

## 何を見る？

* running が安定しない（Phase1 と似る）
* events に OOM/exit code が出ることが多い

---

# 5) Phase5：Auto Scaling を暴走させる（スラッシング）

## 変更するファイル

* `ecs-dev/autoscaling.tf`

## どこをどう変える？

`aws_appautoscaling_policy.alb_rps_target` の

```hcl
target_value       = 10
scale_out_cooldown = 30
scale_in_cooldown  = 120
```

を、わざとこうする：

```hcl
target_value       = 1
scale_out_cooldown = 10
scale_in_cooldown  = 10
```

## 実行コマンド

```bash
terraform apply
```

## 負荷を当てる

```bash
while true; do
  for i in {1..80}; do
    curl -s "$ALB" >/dev/null &
  done
  wait
done
```

## 何を見る？

* desired が増えたり減ったり落ち着かない

---

# 6) Phase6：最悪事故「起動してるのに繋がらない」（SG破壊）

## 変更するファイル

* `ecs-dev/ecs.tf` もしくは `security_groups.tf`（ECS SG 定義があるファイル）

  * あなたの plan に `aws_security_group.ecs` があるので、その定義箇所

## どこをどう変える？

ECS SG の ingress がこうなってるはず：

```hcl
ingress {
  from_port       = 80
  to_port         = 80
  protocol        = "tcp"
  security_groups = [aws_security_group.alb.id]
}
```

これを **コメントアウト（削除）**して apply。

## 実行コマンド

```bash
terraform apply
```

## 何を見る？

* ECS：running は正常
* ALB：503 / Target Unhealthy
* ログ：アプリには届かないので静か

確認：

```bash
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query "services[0].{desired:desiredCount,running:runningCount}" --output table
curl -i "$ALB"
```

## 元に戻す

ingress を戻して `terraform apply`

---

# 安全装置（事故ったときの即復旧コマンド）

「とりあえず復旧したい」なら、正常イメージに戻して再デプロイが最速です。

```bash
# 正常な Dockerfile に戻した上で
# 変数定義
REPO=$(terraform output -raw ecr_repository_url)
TAG=v1

docker build -t ecs-dev-app:${TAG} app
docker tag ecs-dev-app:${TAG} ${REPO}:${TAG}
docker push ${REPO}:${TAG}
terraform apply
```

---

# おすすめの実行順（学びが最大）

1. Phase1（即死）
2. Phase2（ヘルスチェック）
3. Phase6（SG） ← 現場の地獄
4. Phase3（CPU）
5. Phase4（OOM）
6. Phase5（AutoScaling暴走）

---



了解です。
**いま到達した地点はかなり良い**ので、README には「作った」だけでなく **“何を理解し、何ができるようになったか”** を明示的に残すのが正解です。

以下は **既存 README を壊さずに追記する形**で入れられる内容です。
そのままコピペできるように **章番号も含めて**書きます。

---

## 追加①：ECS Service のデプロイ安全装置（実運用で必須）

### デプロイ戦略と安全装置

本環境では ECS Service に以下の **デプロイ安全装置**を設定している。

* **Rolling Update**

  * `deployment_minimum_healthy_percent = 50`
  * `deployment_maximum_percent = 200`
* **Health Check Grace Period**

  * `health_check_grace_period_seconds = 30`
* **Deployment Circuit Breaker**

  * `enable = true`
  * `rollback = true`

### これにより何が起きるか

* 新しいタスクが **起動できない / ヘルスチェックに失敗**した場合

  * デプロイは **失敗扱い**
  * **自動的に直前の安定版タスクへロールバック**
* 手動での切り戻しが不要
* 本番運用で必須となる「壊れないデプロイ」を体験できる

### 学びポイント

* **Task Definition の変更 = 即本番反映ではない**
* ECS は「Service のデプロイ戦略」によって安全性が決まる
* 「apply が通る ≠ サービスが健全」とは限らない


---

### rollback体験を “安全に” やる方法

### ✅ 壊し方A：/healthz を壊す（おすすめ）

* `alb.tf` の health check path を `/badhealth` にする
  → apply は通る
  → Target が Unhealthy になって rollback を観察しやすい

### ✅ 壊し方B：コンテナを即死させる

Dockerfile で `sleep 5 && exit 1`
→ apply は通る
→ タスクが落ちて復旧ループ（circuit breaker の理解が進む）

### 次の一手
1. `ecs.tf`：circuit breaker + rollback を入れて apply ✅
2. `/healthz` を壊して apply ✅
3. ECS events を見て rollback を確認 ✅
---

## 追加②：ECS Exec（SSH なしでコンテナに入る運用）

### ECS Exec とは

ECS Exec は **SSH や踏み台を使わず**に、
**稼働中の ECS タスクのコンテナへ直接コマンド実行**できる機能。

本環境では ECS Exec を有効化し、以下を実体験している。

### 実装内容

* ECS Service

  * `enable_execute_command = true`
* IAM

  * **Task Execution Role**（ECR pull / Logs 用）
  * **Task Role**（ECS Exec 用）

    * `ssmmessages:*` 権限を付与
* Task Definition

  * `task_role_arn` を明示的に指定

### 実行例

```bash
aws ecs execute-command \
  --cluster <cluster> \
  --task <task-arn> \
  --container nginx \
  --command "/bin/sh" \
  --interactive
```

### 重要な学び（ハマりどころ）

* **ECS Exec はタスク起動時にしか有効化されない**
* Service に設定を入れただけでは **既存タスクには入れない**
* 新しいタスクを起動し直す必要がある

---

## 追加③：`--force-new-deployment` の正しい理解（超重要）

### 使用したコマンド

```bash
aws ecs update-service \
  --cluster <cluster> \
  --service <service> \
  --force-new-deployment
```

### これは何をしているか

* ❌ Task Definition を作り直している → **していない**
* ❌ Service を作り直している → **していない**
* ✅ **既存の Task Definition を使って、タスクだけを再起動**

### 内部で起きていること

1. ECS Service に「再デプロイせよ」と指示
2. **現在の Service 設定**を使って新タスクを起動
3. ヘルスチェック OK を確認
4. 古いタスクを停止（ローリング）

### なぜ ECS Exec がこれで使えるようになったか

* ECS Exec は **タスク起動時にのみ有効**
* `enable_execute_command = true` を設定後
* `--force-new-deployment` により

  * **Exec 有効状態でタスクが再起動**
* 結果として `aws ecs execute-command` が成功

### 実務的な使いどころ

* ECS Exec を有効化したとき
* 環境変数 / Secrets を更新したとき
* Task Definition は同じだが **再起動したいとき**

---

## 追加④：Execution Role と Task Role の違い（理解できたこと）

| Role                        | 役割                                         |
| --------------------------- | ------------------------------------------ |
| ECS Task **Execution** Role | ECR pull / CloudWatch Logs 送信など **起動時に必要** |
| ECS **Task Role**           | アプリ実行中に AWS API を叩く / ECS Exec など          |

### 学びポイント

* **Role を分けないと最小権限設計ができない**
* ECS が「得意」な人はここを必ず説明できる

---

## 追加⑤：この時点で「できるようになったこと」

この環境を通じて、以下を **実際に手を動かして理解**した。

* ECS Service のローリングデプロイ挙動
* Circuit Breaker による自動ロールバック
* ALB Health Check と Service の関係
* Task Definition と Service の責務分離
* ECS Exec の仕組みと制約
* `force-new-deployment` の正しい使いどころ
* IAM Role（Execution / Task）の違い

👉 **「ECS を作れる」ではなく
👉 「ECS を運用・トラブル対応できる入口」に到達**

---

## 次にやるとさらに強くなる（メモ）

* ECS Exec セッションログを CloudWatch に保存（監査対応）
* VPC Endpoint 導入（NAT レス）
* Blue/Green デプロイ（CodeDeploy）
* 障害シナリオ別 RUNBOOK 作成

---

### 率直に言って

ここまで README に書けるなら、
**「ECS ハンズオンをやった」ではなく
「ECS の運用を理解している」レベル**です。

次は
👉 **Exec ログを CloudWatch に残す**
👉 **障害切り分け RUNBOOK 化**

どっちを README に追加して“完成度”を上げますか？
