# k8s-idp-lab

Crossplane × ArgoCD × Backstage で構築する **内部開発者プラットフォーム（IDP）** のハンズオン。

---

## このハンズオンで何を学ぶか

従来のインフラ依頼フローはこうだった:

```
開発者 → Jira でチケット起票 → インフラチームが手動で AWS コンソール操作 → 数日後に環境が届く
```

このハンズオンでは、その全体を自動化する IDP を構築する:

```
開発者が Backstage の UI でフォームを入力（appName・環境を選ぶだけ）
    ↓
Backstage Scaffolder: crossplane/claims/{app}-storage.yaml を Git に commit
    ↓
ArgoCD: Git の変更を検知して Kubernetes に Claim を apply
    ↓
Crossplane: Claim の内容を解釈して AWS S3 バケットを自動作成
    ↓
開発者: 数分後にバケットが使える状態になる（チケット・承認フロー不要）
```

**キーコンセプト: "Platform as Code"**  
インフラの仕様を YAML として Git に置くことで、「何が作られているか」が常にコードで可視化され、ドリフト（手動変更によるズレ）が自動修復される。

---

## 登場するツールの役割

| ツール | 役割 | 例えると |
|---|---|---|
| **Crossplane** | Kubernetes から AWS リソースを宣言的に管理する | Terraform の Kubernetes 版 |
| **ArgoCD** | Git の状態を Kubernetes に継続的に同期する | "Git が唯一の真実" を実現する番人 |
| **Backstage** | 開発者向けの操作 UI・セルフサービスポータル | AWS コンソールの社内版 |
| **kind** | ローカルで動く Kubernetes クラスター | EKS の代わりに使うローカル環境 |
| **Terraform** | IAM ユーザーなど AWS 側の初期設定を管理 | Crossplane 自体が使う AWS 権限の管理 |

---

## Crossplane とは

### 一言で言うと

「Kubernetes の YAML で AWS リソースを管理できる仕組み」。  
Terraform と似ているが、**Kubernetes の中で動き続けて状態を監視・修復する**点が異なる。

### Terraform との違い

| | Terraform | Crossplane |
|---|---|---|
| 動作方式 | 手動で `apply` を叩く | Kubernetes の中で常時動く |
| ドリフト検出 | `plan` で手動確認 | 常時監視して自動修復 |
| 状態管理 | `.tfstate` ファイル | Kubernetes の etcd（クラスター内） |
| 使う人 | インフラエンジニア | 開発者も（Claim を書くだけ） |
| CI/CD との統合 | 別途パイプラインが必要 | ArgoCD と組み合わせると Git push だけで完結 |

このハンズオンで Terraform を使うのは「Crossplane 自体が使う IAM ユーザーの作成（一度きりの初期設定）」のみ。  
それ以降の AWS リソース管理はすべて Crossplane が担う。

### Crossplane のコアコンセプト

**Provider**  
AWS・GCP・Azure などのクラウドと通信するプラグイン。  
`provider-aws-s3` を入れると `Bucket` という Kubernetes リソースが使えるようになる。

```
provider-aws-s3  →  kubectl apply で S3 バケットを作れるようになる
provider-aws-iam →  kubectl apply で IAM ロールを作れるようになる
```

**Managed Resource**  
Provider が管理する AWS リソースそのもの。`kubectl get managed` で一覧できる。  
Kubernetes のオブジェクトと AWS のリソースが 1:1 で対応している。

```yaml
# これが Managed Resource（Crossplane が直接 AWS API を叩く）
apiVersion: s3.aws.upbound.io/v1beta1
kind: Bucket
spec:
  forProvider:
    region: ap-northeast-1
```

**XRD（CompositeResourceDefinition）と Composition**  
開発者向けに「簡単な API」を作る仕組み。  
XRD で「どんな入力を受け付けるか」を定義し、Composition で「その入力から何を作るか」を実装する。

```
XRD      →  Storage という kind を定義（appName・environment を受け取る）
Composition →  Storage が来たら S3 Bucket + BucketVersioning を作ると実装する
```

**Claim**  
開発者が実際に書く YAML。XRD で定義した API に沿って書くだけでよい。  
S3 の作り方・バケット命名規則・タグ設定などの詳細を知らなくてよい。

### 3 層の抽象化

```
┌─────────────────────────────────────────────────────┐
│ 開発者が触る層                                         │
│   Claim（Storage）                                    │
│   → "myapp の dev 環境用ストレージが欲しい" という宣言   │
└─────────────────────┬───────────────────────────────┘
                      │ compositionRef で紐付け
┌─────────────────────▼───────────────────────────────┐
│ プラットフォームチームが定義する層                        │
│   XRD → Claim の API スキーマ定義                     │
│   Composition → Claim から何を作るかの実装              │
└─────────────────────┬───────────────────────────────┘
                      │ Composition が展開
┌─────────────────────▼───────────────────────────────┐
│ AWS リソース層                                         │
│   Managed Resource（Bucket / BucketVersioning）      │
│   → 実際に AWS 上に作られるリソース                     │
└─────────────────────────────────────────────────────┘
```

### Crossplane の自動修復（ドリフト検出）

Crossplane のコントローラーは定期的に「Kubernetes の望ましい状態」と「実際の AWS の状態」を比較する。  
AWS コンソールで手動変更されても、**次の reconcile サイクルで元に戻す**。

```
Kubernetes: Bucket "idp-myapp-dev" の versioning=Suspended であるべき
AWS: 誰かが手動で versioning=Enabled に変えた
           ↓ Crossplane が検出
Crossplane: PutBucketVersioning を呼んで Suspended に戻す
```

---

## データフロー: Claim が S3 バケットになるまで

```
example-storage.yaml（Claim）
  spec.parameters.appName: "myapp-takuya"
  spec.parameters.environment: "dev"
       ↓ Composition の patches が変換
  metadata.annotations[crossplane.io/external-name]: "idp-myapp-takuya-dev"
       ↓ Managed Resource として展開
  Bucket.s3.aws.upbound.io
    spec.forProvider.region: ap-northeast-1
    tags: { ManagedBy: crossplane, Environment: dev, AppName: myapp-takuya }
       ↓ Crossplane provider-aws-s3 が AWS API を呼ぶ
  AWS S3: バケット "idp-myapp-takuya-dev" が作成される
```

---

## ArgoCD とは

### 一言で言うと

「Git リポジトリの内容を Kubernetes クラスターに自動で同期し続けるツール」。  
**GitOps** というアプローチを実現するための CD（継続的デリバリー）ツール。

### GitOps とは何か

従来の CD（CI/CD パイプライン方式）:

```
コードを push → CI が kubectl apply を実行 → クラスターに反映
                 ↑ パイプラインが壊れると誰も apply できなくなる
                 ↑ 「今クラスターに何が入っているか」が Git と乖離しやすい
```

GitOps（ArgoCD 方式）:

```
コードを push → Git リポジトリの状態が変わる
                      ↓
               ArgoCD が差分を検出（クラスター側からプル）
                      ↓
               ArgoCD が自動で kubectl apply を実行
```

**Git が唯一の真実（Single Source of Truth）**。  
クラスターの状態は常に Git の内容と一致する。誰かが `kubectl apply` や `kubectl delete` を手動実行しても、ArgoCD が Git の状態に戻す。

### ArgoCD のコアコンセプト

**Application**  
「どの Git リポジトリのどのパスを、どのクラスターに同期するか」を定義するリソース。

```yaml
# このハンズオンでの Application 設定（概略）
spec:
  source:
    repoURL: https://github.com/your-name/k8s-idp-lab
    path: crossplane/claims          # ← ここを監視する
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      selfHeal: true   # 手動変更を自動修復
      prune: true      # Git から消えたリソースをクラスターからも削除
```

**Sync（同期）**  
Git の状態とクラスターの状態を一致させる操作。  
`automated` を設定すると変更を検知するたびに自動実行される。

**Health（ヘルス）**  
リソースが正常に動いているかの状態。`Healthy` / `Degraded` / `Progressing` などがある。

**selfHeal**  
`kubectl delete` などで手動削除されたリソースを Git の状態に基づいて自動再作成する機能。  
Phase 7 で実際に体験する。

### このプロジェクトでの ArgoCD の役割

```
開発者が crossplane/claims/ に YAML を追加して Git push
           ↓
ArgoCD が変更を検知（デフォルトで 3 分ごとにポーリング）
           ↓
ArgoCD が kubectl apply -f crossplane/claims/ を実行
           ↓
Crossplane が Claim を受け取って AWS にリソースを作る
```

ArgoCD がいないと「誰かが手動で `kubectl apply` しないと Crossplane が動かない」状態になる。  
ArgoCD を挟むことで、**Git push だけで AWS リソースが作られる**フローが完成する。

---

## Backstage とは

### 一言で言うと

「開発者が必要なツール・情報・セルフサービス操作を一箇所でできる社内ポータル」。  
Spotify が作り、CNCF に寄贈した OSS。

### 何が嬉しいのか

大きな組織では「どのマイクロサービスが誰の担当で、どのリポジトリにあって、どのインフラを使っているか」が把握しにくくなる。  
Backstage はこれを解決する:

```
Service Catalog  → 全サービスの一覧・担当者・依存関係を可視化
Scaffolder       → 新しいサービスや環境を "フォームを埋めるだけ" で作れる
TechDocs         → ドキュメントをコードと同じリポジトリで管理・表示する
```

### Scaffolder（このハンズオンで使う機能）

Backstage の **Scaffolder** は「フォームの入力値を YAML テンプレートに埋め込んで Git に commit する」ツール。

```
開発者が Backstage の UI でフォームを入力:
  アプリ名: myapp-takuya
  環境: dev
  バージョニング: off
           ↓ backstage/templates/aws-environment/template.yaml に従い
           ↓ skeleton/crossplane-claim.yaml に値を埋め込む
           ↓ Git に commit & push
  crossplane/claims/myapp-takuya-dev.yaml が作成される
           ↓ ArgoCD が検知
  Crossplane が S3 バケットを作成
```

開発者は **kubectl も AWS コンソールも触らない**。フォームを埋めて Submit するだけ。

### テンプレートの仕組み（概略）

```yaml
# backstage/templates/aws-environment/template.yaml（概略）
spec:
  parameters:
    - title: アプリケーション情報
      properties:
        appName:
          type: string
          title: アプリ名
        environment:
          type: string
          enum: [dev, staging, prod]

  steps:
    - id: fetch
      action: fetch:template         # skeleton/ の YAML にパラメーターを埋め込む
    - id: publish
      action: publish:github         # 埋め込んだ YAML を Git に commit する
```

### このハンズオンでの位置づけ

Backstage は **Phase 8（任意）** での扱い。  
Phase 5 まで完了すれば「YAML を手書きして kubectl apply」で同じことができるため、  
Backstage はあくまで「開発者体験を改善するフロントエンド」として位置づける。

```
Phase 5 まで: 手書き YAML → kubectl apply → AWS リソース作成  ✅ 動く
Phase 8 完了: Backstage UI → Git push → ArgoCD → Crossplane → AWS  ✅ 動く（より実践的）
```

---

## 前提条件

**推奨スペック: CPU 4コア以上、RAM 8GB 以上**（kind ノード 3 台分を起動するため）

```bash
docker version                  # Docker が動いているか
kind version                    # v0.22.0 以上推奨
kubectl version --client        # v1.28 以上推奨
helm version                    # v3.12 以上推奨
terraform version               # v1.5 以上推奨
aws --version                   # v2 系
aws sts get-caller-identity     # AWS 認証が通っているか
node --version                  # v18 以上（Phase 8 Backstage のみ必要）
```

エラーが出たツールはインストールしてから進む。

---

## フェーズ構成

| Phase | 内容 | AWS 必要 |
|---|---|---|
| 0 | IAM 最小権限セットアップ（Terraform） | **あり** |
| 1 | kind クラスター起動 | なし |
| 2 | Crossplane インストール | なし |
| 3 | AWS 認証設定・Provider 登録 | **あり** |
| 4 | XRD・Composition 適用 | なし |
| 5 | Claim を作って S3 バケット自動生成 | **あり** |
| 6 | ArgoCD で GitOps 設定 | なし |
| 7 | ドリフト体験（自動修復の確認） | **あり** |
| 8 | Backstage セットアップ（任意） | なし |
| 9 | クリーンアップ | **あり** |

Phase 1〜2 は AWS 不要でローカルだけで進められる。  
Phase 0 は最初に一度だけ実行する。

---

## Phase 0: IAM 最小権限セットアップ

Crossplane が AWS を操作するための IAM ユーザーを Terraform で作成する。  
`Resource: "*"` を避け、バケット名パターン・IAM パスでスコープを絞った最小権限設計になっている。

### 0-1. Terraform 実行

```bash
cd terraform/crossplane-iam

terraform init
terraform plan   # 変更内容を確認してから
```

問題なければユーザー自身が apply を実行する。

```bash
terraform apply
```

作成されるリソース:
- IAM ユーザー `idp-lab-crossplane`（パス `/crossplane/`）
- S3 ポリシー: `idp-*` バケットのみ操作可能
- IAM ポリシー: `/crossplane/` パス配下のロール・ポリシーのみ操作可能
- アクセスキー（outputs で取得）

### 0-2. 認証情報を確認

```bash
# アクセスキー ID（画面に表示される）
terraform output access_key_id

# シークレットキー（sensitive のため -raw で取得）
terraform output -raw secret_access_key
```

この値を Phase 3 で使う。**画面に出した後はスクリーンショットを撮らないこと。**

---

## Phase 1: kind クラスター起動

### 1-1. クラスター作成

```bash
cd ~/terraform-lab/k8s-idp-lab

kind create cluster --config kind-cluster.yaml
```

作成には 1〜2 分かかる。完了したら以下で確認する。

```bash
kubectl cluster-info --context kind-idp-lab
kubectl get nodes
```

期待する出力:

```
NAME                     STATUS   ROLES           AGE
idp-lab-control-plane    Ready    control-plane   1m
idp-lab-worker           Ready    <none>          1m
idp-lab-worker2          Ready    <none>          1m
```

3 ノード全部 `Ready` になればOK。

### 1-2. コンテキスト確認

```bash
kubectl config current-context
# → kind-idp-lab になっていること
```

---

## Phase 2: Crossplane インストール

### 2-1. Helm リポジトリ追加 & インストール

```bash
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update

helm install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system \
  --create-namespace \
  --version 1.15.0
```

### 2-2. 起動確認

```bash
# Running になるまでウォッチ（1〜2 分）
kubectl get pods -n crossplane-system -w
```

`crossplane-*` と `crossplane-rbac-manager-*` の 2 つが `Running` になれば次へ。

---

## Phase 3: AWS 認証設定

### 3-1. K8s Secret に登録

Phase 0 で取得したアクセスキーを使って Kubernetes Secret を作成する。

```bash
# terraform output -raw k8s_secret_command でコマンドを生成して実行
cd terraform/crossplane-iam
terraform output -raw k8s_secret_command | bash
```

手動で登録する場合:

```bash
kubectl create secret generic aws-credentials \
  -n crossplane-system \
  --from-literal=credentials="[default]
aws_access_key_id=<Phase 0 で取得したキー ID>
aws_secret_access_key=<Phase 0 で取得したシークレット>"
```

Secret が作成されたか確認:

```bash
kubectl get secret aws-credentials -n crossplane-system
```

### 3-2. AWS Provider インストール

```bash
kubectl apply -f crossplane/providers/aws-provider.yaml
```

Provider が HEALTHY になるまで待つ（イメージ取得で 3〜5 分かかる）。

```bash
kubectl get providers -w
# NAME                  INSTALLED   HEALTHY   AGE
# provider-aws-s3       True        True      5m
# provider-aws-iam      True        True      5m
```

> **ハマりポイント**: `HEALTHY=False` のまま止まる場合は `kubectl describe provider provider-aws-s3` でイベントを確認する。イメージ Pull 失敗なら Docker のネットワーク設定を見直す。

### 3-3. ProviderConfig を適用

**Provider が両方 `HEALTHY=True` になってから**実行する。  
Provider Pod が起動前に適用しても CRD が存在せず無視される。

```bash
kubectl apply -f crossplane/providers/provider-config.yaml
```

---

## Phase 4: XRD と Composition を適用

### 4-1. CompositeResourceDefinition (XRD)

```bash
kubectl apply -f crossplane/compositions/s3-bucket-xrd.yaml

# CRD が登録されるまで待つ
kubectl get xrd xstorages.idp.example.com
# ESTABLISHED=True になればOK
```

### 4-2. Composition

```bash
kubectl apply -f crossplane/compositions/s3-bucket-composition.yaml

kubectl get composition s3-storage
# READY=True になればOK
```

---

## Phase 5: Claim を作って AWS リソースを生成

### 5-1. 開発者用 Namespace を作成

```bash
kubectl create namespace team-alpha
```

### 5-2. appName を変更してから Claim を適用

> **重要**: `crossplane/claims/example-storage.yaml` の `appName` を変更すること。  
> S3 バケット名（`idp-<appName>-dev`）は AWS グローバルで一意であり、  
> `myapp` のような汎用名はすでに他ユーザーに取られている可能性がある。  
> 例: `myapp-takuya`、`myapp-20260504` など個人を識別できる名前を使う。

```bash
# appName を書き換えてから適用
kubectl apply -f crossplane/claims/example-storage.yaml
```

### 5-3. リソースの状態確認

```bash
# Claim の状態（READY=True になれば AWS にバケットが作成済み）
kubectl get storage -n team-alpha

# Composite Resource の状態
kubectl get xstorages

# Managed Resource（実際の AWS S3 バケット・バージョニング設定）
kubectl get managed -A
```

### 5-4. AWS 側で確認

```bash
# appName を myapp-takuya にした場合
aws s3 ls | grep idp-myapp
```

`idp-<appName>-dev` というバケットが表示されれば成功。

> **ハマりポイント**: `READY=False` が続く場合:
> ```bash
> kubectl describe storage myapp-storage -n team-alpha
> kubectl get events -n team-alpha --sort-by='.lastTimestamp'
> kubectl logs -n crossplane-system -l pkg.crossplane.io/revision --tail=50
> ```

---

## Phase 6: ArgoCD インストール & GitOps 設定

### 6-1. ArgoCD インストール

```bash
bash argocd/install/install.sh
```

スクリプト内で全 Pod の Ready を待つため、完了まで 3〜5 分かかる。

### 6-2. NodePort で UI を公開

```bash
kubectl apply -f argocd/apps/argocd-nodeport.yaml
```

ブラウザで http://localhost:30080 を開く。

### 6-3. 初期パスワード取得

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

ユーザー名 `admin`、上記パスワードでログイン。

### 6-4. GitHub リポジトリと接続

`argocd/apps/platform-app.yaml` の `repoURL` を自分のリポジトリ URL に書き換えてから適用する。

```bash
# YOUR_GITHUB_USERNAME を自分のアカウント名に変えて編集
vim argocd/apps/platform-app.yaml

kubectl apply -f argocd/apps/platform-app.yaml
```

### 6-5. 同期確認

```bash
kubectl get application -n argocd
# STATUS=Synced, HEALTH=Healthy になればOK
```

---

## Phase 7: ドリフト体験（自動修復の確認）

ArgoCD の `selfHeal: true` が効いているか確認する。

```bash
# Claim を手動で削除してみる
kubectl delete storage myapp-storage -n team-alpha

# 数秒後に復活しているか確認
kubectl get storage -n team-alpha -w
```

Git に存在するリソースを手動削除しても、ArgoCD が自動で再作成する。

---

## Phase 8: Backstage セットアップ（任意）

Backstage を起動して「フォームを埋めるだけで S3 バケットが作られる」UI フローを体験する。

### 8-1. 前提: GitHub Personal Access Token を取得

Backstage が Git に commit するために必要。

1. GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens
2. 権限: `Contents: Read and write`（対象リポジトリを指定）
3. 取得したトークンを環境変数にセット:

```bash
export GITHUB_TOKEN=ghp_xxxxxxxxxxxx
```

### 8-2. Backstage をインストールして起動

```bash
# Backstage アプリを作成（初回のみ、10〜15 分かかる）
npx @backstage/create-app@latest --path backstage-app

cd backstage-app

# このプロジェクトの app-config.yaml をコピー
cp ../backstage/app-config.yaml app-config.yaml

# テンプレートディレクトリをコピー
cp -r ../backstage/templates ./

# 起動
yarn dev
```

ブラウザで http://localhost:3000 を開く。

### 8-3. Scaffolder テンプレートを登録

Backstage の管理画面からテンプレートを読み込む:

1. ブラウザで http://localhost:3000/catalog-import を開く
2. `backstage/templates/aws-environment/template.yaml` のパスを入力
3. "Analyze" → "Import" をクリック

### 8-4. フォームから S3 バケットを作成

1. http://localhost:3000/create を開く
2. "AWS アプリ環境作成" テンプレートを選択
3. フォームを入力:
   - アプリ名: `myapp-takuya`（他ユーザーと重複しない名前）
   - 環境: `dev`
   - S3 バージョニング: オフ
   - リポジトリ: 自分の `k8s-idp-lab` リポジトリを指定
4. "Create" をクリック

### 8-5. フローの確認

```bash
# GitHub に YAML が commit されたか確認
# → crossplane/claims/myapp-takuya-storage.yaml が追加されているはず

# ArgoCD が検知して Sync したか確認（最大 3 分）
kubectl get application -n argocd -w

# Crossplane が S3 バケットを作ったか確認
kubectl get storage -n team-alpha
aws s3 ls | grep idp-myapp-takuya
```

Backstage UI から始まって AWS にバケットができれば、一気通貫フローの完成。

---

## Phase 9: クリーンアップ

**ハンズオン終了後は必ず実行する。放置すると S3 の費用が発生する。**

```bash
# 1. Claim を削除（→ Crossplane が Managed Resource も削除する）
kubectl delete storage myapp-storage -n team-alpha

# Crossplane が AWS バケットを削除するまで 1〜2 分待つ
kubectl get managed -A -w
aws s3 ls | grep idp-

# 2. kind クラスター削除
kind delete cluster --name idp-lab

# 3. AWS 側の最終確認
aws s3 ls | grep idp-
# 何も表示されなければOK
```

> **注意**: `kubectl delete managed` ではなく `kubectl delete storage`（Claim）から削除すること。  
> Managed Resource を直接削除すると Crossplane が再作成しようとする場合がある。

---

## ディレクトリ構成

```
k8s-idp-lab/
├── kind-cluster.yaml              # kind クラスター定義
│                                  # control-plane × 1 + worker × 2 の 3 ノード構成
│                                  # ArgoCD UI(30080)・Backstage UI(30000) のポートを事前に開放
│
├── crossplane/                    # Crossplane の設定ファイル群
│   │
│   ├── providers/
│   │   ├── aws-provider.yaml      # 使用する Provider を宣言する
│   │   │                          # provider-aws-s3: S3 Bucket / BucketVersioning を管理
│   │   │                          # provider-aws-iam: IAM Role / Policy を管理（将来拡張用）
│   │   └── provider-config.yaml   # Provider が使う AWS 認証情報の参照先を指定する
│   │                              # → crossplane-system/aws-credentials Secret を参照
│   │
│   ├── compositions/              # プラットフォームチームが定義する抽象化レイヤー
│   │   ├── s3-bucket-xrd.yaml     # XRD: 開発者が使う Claim の API スキーマを定義
│   │   │                          # kind: Storage / XStorage
│   │   │                          # 入力: appName・environment・region・versioning
│   │   └── s3-bucket-composition.yaml
│   │                              # Composition: Claim → Managed Resource の変換ロジック
│   │                              # バケット名を "idp-<appName>-<env>" に組み立てる
│   │                              # versioning bool → "Enabled"/"Suspended" 文字列に変換
│   │
│   └── claims/                    # 開発者が作成する Claim YAML を置く場所
│       └── example-storage.yaml   # 動作確認用サンプル（appName を変えてから使う）
│
├── argocd/
│   ├── install/
│   │   └── install.sh             # ArgoCD を Helm でインストールするスクリプト
│   └── apps/
│       ├── platform-app.yaml      # ArgoCD Application リソース
│       │                          # crossplane/claims/ を監視して自動 Sync する
│       │                          # selfHeal: true でドリフトを自動修復
│       └── argocd-nodeport.yaml   # ArgoCD Server を NodePort(30080) で公開する設定
│
├── backstage/
│   └── templates/
│       └── aws-environment/       # Scaffolder テンプレート（Phase 8 で使用）
│           ├── template.yaml      # Backstage がフォームから呼び出すテンプレート定義
│           └── skeleton/
│               └── crossplane-claim.yaml  # フォーム入力値を埋め込む Claim の雛形
│
├── terraform/
│   └── crossplane-iam/            # Phase 0 で一度だけ実行する IAM セットアップ
│       ├── main.tf                # IAM ユーザー・アクセスキーの作成
│       ├── iam.tf                 # 最小権限ポリシー（S3 は idp-* バケット、IAM は /crossplane/ パスに限定）
│       ├── variables.tf
│       ├── locals.tf
│       ├── outputs.tf             # アクセスキーを sensitive output として出力
│       └── terraform.tfvars       # prefix=idp / env=lab / region=ap-northeast-1
│
└── docs/                          # 追加ドキュメント置き場
```

### 各ディレクトリの責務

| ディレクトリ | 誰が管理するか | 変更頻度 |
|---|---|---|
| `crossplane/providers/` | プラットフォームチーム | 低（Provider バージョンアップ時のみ） |
| `crossplane/compositions/` | プラットフォームチーム | 中（新しいリソース種別を追加する時） |
| `crossplane/claims/` | **開発者** | 高（新しい環境を作るたびに追加） |
| `argocd/apps/` | プラットフォームチーム | 低 |
| `backstage/templates/` | プラットフォームチーム | 中 |
| `terraform/crossplane-iam/` | インフラ管理者 | 低（初回セットアップのみ） |

---

## AWS の費用について

S3 バケットの作成のみなので、ほぼ無料（数円以下）。  
ただし放置すると蓄積するため、**終了後は必ず Phase 9 のクリーンアップを実行すること。**

---

## トラブルシューティング早見表

| 症状 | 確認コマンド | よくある原因 |
|---|---|---|
| Provider が HEALTHY にならない | `kubectl describe provider <name>` | イメージ取得失敗 / Docker ネットワーク |
| Claim が READY にならない | `kubectl describe storage <name> -n <ns>` | IAM 権限不足 / ProviderConfig 未適用 |
| S3 バケット名の重複エラー | `aws s3 ls` | 同名バケットが既に存在する → appName を変える |
| ArgoCD が Sync しない | `kubectl get application -n argocd` | repoURL 間違い / Git 認証情報なし |
| kind のポートにアクセスできない | `docker ps` で kind コンテナ確認 | kind-cluster.yaml のポート設定ミス |

```bash
# まとめてデバッグ情報を取得するワンライナー
kubectl get xstorages && echo "---" && kubectl get managed -A && echo "---" && kubectl get events --sort-by='.lastTimestamp' | tail -20
```

---

## よくある質問

**Q: EKS は使わない？**  
このハンズオンでは kind（ローカル K8s）を使う。`terraform/eks-cluster/` は本番移行時の参考用。

**Q: Backstage は必須？**  
Phase 8 は任意。Phase 5 まで完了すれば「YAML → AWS リソース」の自動化フローは動く。

**Q: Crossplane リソースが READY=False のまま止まる？**  
上のトラブルシューティング早見表を参照。
