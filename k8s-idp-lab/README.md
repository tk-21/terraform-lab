# k8s-idp-lab

Crossplane × ArgoCD × Backstage で、AWS リソースをセルフサービス提供する内部開発者プラットフォーム（IDP）を体験するハンズオンです。

このリポジトリでは、開発者が `Storage` Claim を宣言し、それを ArgoCD が GitOps で同期し、Crossplane が AWS の S3 バケットや IAM リソースへ変換する流れを段階的に確認できます。

## このハンズオンで得られること

- Crossplane・ArgoCD・Backstage が IDP の中でどう役割分担するかを、手を動かしながら理解できます。
- `Claim -> Composition -> Managed Resource -> AWS` という変換の流れを、自分で確認できます。
- GitOps によって「Git の宣言が Kubernetes と AWS に反映される」運用イメージを掴めます。
- 開発者向けセルフサービス基盤を、どのように標準化して提供するかの基本パターンを学べます。
- 実務でも応用しやすい、`kind + Crossplane + ArgoCD + Backstage` の最小構成サンプルとして使えます。

## このハンズオンで到達するゴール

最終的に次の流れが動く状態を目指します。

```text
Backstage でフォーム入力
  ↓
GitHub に Claim YAML が commit される
  ↓
ArgoCD が crossplane/claims/ を同期
  ↓
Crossplane が Storage Claim を解釈
  ↓
AWS に S3 バケットが自動作成される
```

Backstage は任意フェーズです。Phase 5 まで進めれば、Backstage を使わずに `Claim -> Crossplane -> AWS` の自動化まで確認できます。

## 登場するコンポーネント

| コンポーネント | 役割 |
|---|---|
| `kind` | ローカル Kubernetes クラスター |
| `Crossplane` | Kubernetes API から AWS リソースを宣言的に管理 |
| `ArgoCD` | Git の状態を Kubernetes に同期 |
| `Backstage` | 開発者向けセルフサービスポータル |
| `Terraform` | Crossplane 用 AWS IAM ユーザーを初期セットアップ |

## 先に読んでおくと理解しやすい資料

- [ARCHITECTURE.md](/home/takuya/terraform-lab/k8s-idp-lab/ARCHITECTURE.md)
- [docs/crossplane-guide.md](/home/takuya/terraform-lab/k8s-idp-lab/docs/crossplane-guide.md)
- [docs/troubleshooting.md](/home/takuya/terraform-lab/k8s-idp-lab/docs/troubleshooting.md)

## フェーズ一覧

| Phase | 内容 | 必須 |
|---|---|---|
| 0 | AWS IAM の初期セットアップ | AWS を使う場合は必須 |
| 1 | kind クラスター作成 | 必須 |
| 2 | Crossplane インストール | 必須 |
| 3 | AWS 認証と Provider 設定 | AWS を使う場合は必須 |
| 4 | XRD / Composition 適用 | 必須 |
| 5 | Claim から S3 バケット作成 | 必須 |
| 6 | ArgoCD で GitOps 化 | 推奨 |
| 7 | ドリフト修復の確認 | 推奨 |
| 8 | Backstage でセルフサービス化 | 任意 |
| 9 | クリーンアップ | 必須 |

## 0. 前提条件

### 推奨スペック

- CPU 4 コア以上
- メモリ 8 GB 以上
- Docker が十分なメモリを使えること

### 必要ツール

```bash
docker version
kind version
kubectl version --client
helm version
terraform version
aws --version
aws sts get-caller-identity
git --version
node --version
npm --version
```

目安:

- `kind >= 0.22`
- `kubectl >= 1.28`
- `helm >= 3.12`
- `terraform >= 1.5`
- `node >= 18`（Phase 8 のみ）

### このリポジトリで使うローカルポート

| ポート | 用途 |
|---|---|
| `30080` | ArgoCD UI |
| `30000` | kind で Backstage を公開する場合の予約 |
| `3000` | ローカル起動した Backstage フロントエンド |
| `7007` | ローカル起動した Backstage バックエンド |

### 作業ディレクトリ

以降はすべてリポジトリルートで作業します。

```bash
cd /home/takuya/terraform-lab/k8s-idp-lab
pwd
```

## 1. 最短で全体像を掴む実行順

時間がないときは次の順で進めると、最小構成で価値が見えます。

1. Phase 0: Terraform で Crossplane 用 IAM を作る
2. Phase 1: kind を起動する
3. Phase 2: Crossplane を入れる
4. Phase 3: AWS 認証と Provider を設定する
5. Phase 4: XRD / Composition を入れる
6. Phase 5: Claim から S3 バケットを作る
7. Phase 9: 片付ける

GitOps まで見たい場合は Phase 6-7、開発者体験まで見たい場合は Phase 8 へ進んでください。

## 2. Phase 0: Crossplane 用 AWS IAM の初期セットアップ

このフェーズでは、Crossplane が AWS API を呼ぶための IAM ユーザーとアクセスキーを作ります。Terraform の `apply` はユーザー自身が実行してください。

### 2-1. Terraform ディレクトリへ移動

```bash
cd terraform/crossplane-iam
ls
```

主要ファイル:

- `main.tf`: IAM ユーザーとアクセスキー
- `iam.tf`: S3 / IAM の最小権限ポリシー
- `outputs.tf`: Kubernetes Secret 登録用の出力

### 2-2. 初期化と計画確認

```bash
terraform init
terraform plan
```

確認ポイント:

- IAM ユーザー `idp-lab-crossplane`
- `/crossplane/` パス配下の IAM 権限
- `idp-*` バケットに対する S3 権限

### 2-3. `apply` はユーザー自身で実行

```bash
terraform apply
```

### 2-4. 出力値を確認

```bash
terraform output
terraform output -raw access_key_id
terraform output -raw secret_access_key
terraform output -raw k8s_secret_command
```

このあと使うのは:

- `access_key_id`
- `secret_access_key`
- `k8s_secret_command`

### 2-5. ここで成功していれば

- Crossplane 用 IAM ユーザーが AWS に存在する
- Kubernetes Secret 登録用のコマンドを取得できる

## 3. Phase 1: kind クラスター作成

リポジトリルートへ戻って kind クラスターを作ります。

```bash
cd /home/takuya/terraform-lab/k8s-idp-lab
kind create cluster --config kind-cluster.yaml
```

### 3-1. 状態確認

```bash
kubectl config current-context
kubectl cluster-info --context kind-idp-lab
kubectl get nodes
```

期待値:

- コンテキストが `kind-idp-lab`
- ノード 3 台が `Ready`

例:

```text
NAME                     STATUS   ROLES           AGE
idp-lab-control-plane    Ready    control-plane   1m
idp-lab-worker           Ready    <none>          1m
idp-lab-worker2          Ready    <none>          1m
```

### 3-2. ここで成功していれば

- ローカル Kubernetes 基盤が使える
- `30080` などのポートマッピングが有効

## 4. Phase 2: Crossplane をインストール

### 4-1. Helm リポジトリ追加

```bash
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update
```

### 4-2. Crossplane 本体のインストール

```bash
helm install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system \
  --create-namespace \
  --version 1.15.0
```

### 4-3. 起動待ち

```bash
kubectl get pods -n crossplane-system -w
```

確認ポイント:

- `crossplane-*` が `Running`
- `crossplane-rbac-manager-*` が `Running`

### 4-4. ここで成功していれば

- Crossplane コントローラーが kind 上で動いている
- まだ AWS には触れないが、Provider を受け入れる準備ができた

## 5. Phase 3: AWS 認証情報と Provider 設定

### 5-1. Terraform 出力から Kubernetes Secret を登録

`terraform output -raw k8s_secret_command` を使うのが一番簡単です。

```bash
cd terraform/crossplane-iam
terraform output -raw k8s_secret_command | bash
cd /home/takuya/terraform-lab/k8s-idp-lab
```

### 5-2. Secret 確認

```bash
kubectl get secret aws-credentials -n crossplane-system
kubectl describe secret aws-credentials -n crossplane-system
```

### 5-3. AWS Provider を適用

```bash
kubectl apply -f crossplane/providers/aws-provider.yaml
```

### 5-4. Provider が Healthy になるまで待つ

```bash
kubectl get providers -w
```

期待値:

```text
NAME               INSTALLED   HEALTHY
provider-aws-s3    True        True
provider-aws-iam   True        True
```

`HEALTHY=False` のまま止まる場合:

```bash
kubectl describe provider provider-aws-s3
kubectl describe provider provider-aws-iam
kubectl get pods -n crossplane-system
```

### 5-5. ProviderConfig を適用

Provider が両方 `HEALTHY=True` になってから実行します。

```bash
kubectl apply -f crossplane/providers/provider-config.yaml
kubectl get providerconfig
```

### 5-6. ここで成功していれば

- Crossplane が AWS 認証情報を参照できる
- S3 / IAM の Managed Resource を作成できる状態になっている

## 6. Phase 4: XRD と Composition を適用

このフェーズでは、開発者向け API と、その API を AWS リソースへ変換する実装をクラスターへ登録します。

### 6-1. XRD を適用

```bash
kubectl apply -f crossplane/compositions/s3-bucket-xrd.yaml
kubectl get xrd xstorages.idp.example.com
```

確認ポイント:

- `ESTABLISHED=True`

### 6-2. Composition を適用

このリポジトリには 2 種類の Composition があります。両方入れておくと後で比較しやすいです。

```bash
kubectl apply -f crossplane/compositions/s3-bucket-composition.yaml
kubectl apply -f crossplane/compositions/app-environment-composition.yaml
kubectl get composition
```

期待値:

- `s3-storage`
- `app-environment`

### 6-3. Storage API が使えることを確認

```bash
kubectl api-resources | grep -E "storage|xstorage"
```

### 6-4. ここで成功していれば

- 開発者は `kind: Storage` を使える
- Crossplane は `Storage` を `Bucket` などへ展開できる

## 7. Phase 5: Claim から S3 バケットを作成

まずは最小構成の `s3-storage` Composition を使います。

### 7-1. 開発者用 namespace を作成

```bash
kubectl create namespace team-alpha
```

すでに存在する場合はそのままで構いません。

### 7-2. サンプル Claim を編集

[crossplane/claims/example-storage.yaml](/home/takuya/terraform-lab/k8s-idp-lab/crossplane/claims/example-storage.yaml) の `appName` を必ず変更してください。

理由:

- S3 バケット名は AWS 全体で一意
- `myapp` はほぼ確実に衝突しやすい

推奨例:

- `myapp-takuya`
- `myapp-takuya-20260508`

編集後のイメージ:

```yaml
spec:
  compositionRef:
    name: s3-storage
  parameters:
    appName: myapp-takuya
    environment: dev
    region: ap-northeast-1
    versioning: false
```

### 7-3. Claim を適用

```bash
kubectl apply -f crossplane/claims/example-storage.yaml
```

### 7-4. Claim / Composite / Managed Resource の状態確認

```bash
kubectl get storage -n team-alpha
kubectl get xstorages
kubectl get managed -A
```

期待値:

- `storage` の `READY=True`
- `Bucket` と `BucketVersioning` が作成されている

### 7-5. AWS 側で確認

`appName: myapp-takuya` にしたなら:

```bash
aws s3 ls | grep idp-myapp-takuya
```

期待値:

- `idp-myapp-takuya-dev` が見える

### 7-6. `READY=False` のときの確認手順

```bash
kubectl describe storage myapp-storage -n team-alpha
kubectl get events -n team-alpha --sort-by='.lastTimestamp'
kubectl logs -n crossplane-system -l pkg.crossplane.io/revision --tail=100
```

よくある原因:

- S3 バケット名の衝突
- ProviderConfig 未適用
- AWS 認証 Secret の不備
- IAM 権限不足

### 7-7. `app-environment` Composition も試す場合

同じ `Storage` API で IAM Role / Policy まで作らせたい場合は `compositionRef.name` を `app-environment` に変えます。

```yaml
spec:
  compositionRef:
    name: app-environment
```

その場合、作成対象は次になります。

- S3 Bucket
- BucketVersioning
- IAM Role
- IAM Policy
- RolePolicyAttachment

## 8. Phase 6: ArgoCD で GitOps 化

このフェーズからは、`kubectl apply` の代わりに Git を通して Claim をクラスターへ届ける流れを作ります。

### 8-1. ArgoCD をインストール

このリポジトリでは [argocd/install/install.sh](/home/takuya/terraform-lab/k8s-idp-lab/argocd/install/install.sh) を使います。README の説明よりもスクリプトの挙動を優先してください。

```bash
bash argocd/install/install.sh
```

このスクリプトは:

1. `argocd` namespace を作成
2. 公式マニフェストを `kubectl apply`
3. Pod が Ready になるまで待機
4. 初期管理者パスワードを表示

### 8-2. ArgoCD UI を公開

```bash
kubectl apply -f argocd/apps/argocd-nodeport.yaml
kubectl get svc -n argocd argocd-server-nodeport
```

その後、ブラウザで `http://localhost:30080` を開きます。

### 8-3. 初期ログイン情報の取得

`install.sh` の最後でも表示されますが、再確認したい場合は次です。

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

ログイン情報:

- Username: `admin`
- Password: 上記コマンドの出力

### 8-4. `platform-app.yaml` の `repoURL` を自分の GitHub に変更

[argocd/apps/platform-app.yaml](/home/takuya/terraform-lab/k8s-idp-lab/argocd/apps/platform-app.yaml) の次の行を編集します。

```yaml
repoURL: https://github.com/YOUR_GITHUB_USERNAME/k8s-idp-lab.git
```

自分の fork または自分の管理するリポジトリ URL に変更してください。

### 8-5. ArgoCD Application を作成

```bash
kubectl apply -f argocd/apps/platform-app.yaml
kubectl get application -n argocd
```

期待値:

- `crossplane-platform` が作成される
- `SYNC STATUS=Synced`
- `HEALTH STATUS=Healthy`

### 8-6. GitOps で Claim を管理する

ここからは `crossplane/claims/` に置いた YAML を GitHub に push すると、ArgoCD が `team-alpha` namespace へ自動同期します。

確認例:

```bash
kubectl get application -n argocd -w
kubectl get storage -n team-alpha -w
```

## 9. Phase 7: ドリフト修復を体験

ArgoCD の `selfHeal: true` が効いていることを確認します。

### 9-1. Git に存在する Claim を手動削除

```bash
kubectl delete storage myapp-storage -n team-alpha
```

### 9-2. 自動復旧を監視

```bash
kubectl get storage -n team-alpha -w
```

期待値:

- 数秒から数分で Claim が再作成される

理由:

- Git にはまだ Claim が存在している
- ArgoCD が差分を検知して再適用する

### 9-3. さらに理解したい場合

次の 2 つの修復の違いを見ると理解が深まります。

1. Claim を消す
2. AWS 側で S3 バージョニングを手動変更する

前者は ArgoCD が修復し、後者は Crossplane が修復します。

## 10. Phase 8: Backstage でセルフサービス化

このフェーズは任意です。完成形の開発者体験を見たいときに進めてください。

### 10-1. GitHub Personal Access Token を用意

Backstage から GitHub へ commit するために必要です。

必要権限:

- `Contents: Read and write`

環境変数へ設定:

```bash
export GITHUB_TOKEN=ghp_xxxxxxxxxxxx
```

### 10-2. Backstage アプリを新規作成

```bash
cd /home/takuya/terraform-lab/k8s-idp-lab
npx @backstage/create-app@latest --path backstage-app
cd backstage-app
```

### 10-3. このリポジトリの設定とテンプレートを取り込む

```bash
cp ../backstage/app-config.yaml ./app-config.yaml
cp -r ../backstage/templates ./templates
```

### 10-4. `app-config.yaml` のテンプレート参照先を直す

このリポジトリの `backstage/app-config.yaml` は、元のリポジトリ構成前提の相対パスになっています。`backstage-app` 直下にコピーして使う場合は、次のように変更してください。

変更前:

```yaml
target: ../../backstage/templates/aws-environment/template.yaml
```

変更後:

```yaml
target: ./templates/aws-environment/template.yaml
```

### 10-5. Backstage を起動

```bash
yarn dev
```

ブラウザで次を開きます。

- `http://localhost:3000`

### 10-6. Scaffolder テンプレートを確認

起動後、`Create...` 画面または `Catalog Import` から `AWS アプリ環境作成` テンプレートが見えることを確認します。

見えない場合は:

- `app-config.yaml` の `catalog.locations.target`
- `GITHUB_TOKEN`
- 起動ログ

を確認してください。

### 10-7. フォームから Claim を作る

入力例:

- `appName`: `myapp-takuya`
- `environment`: `dev`
- `versioning`: `false`
- `region`: `ap-northeast-1`
- `repoUrl`: 自分の `k8s-idp-lab` リポジトリ

### 10-8. 期待する結果

1. GitHub に `crossplane/claims/` 配下の YAML が commit される
2. ArgoCD が変更を検知して同期する
3. Crossplane が S3 バケットを作る

確認コマンド:

```bash
kubectl get application -n argocd -w
kubectl get storage -n team-alpha
aws s3 ls | grep idp-myapp-takuya
```

補足:

- `catalog:register` は optional です
- `catalog-info.yaml` が無くても、Claim の Git 反映自体は確認できます

## 11. Phase 9: クリーンアップ

ハンズオン後は AWS リソースを消しておきます。

### 11-1. まず Claim から削除

```bash
kubectl delete storage myapp-storage -n team-alpha
kubectl get managed -A -w
```

重要:

- `Managed Resource` を直接削除しない
- `Claim -> Composite -> Managed Resource` の順で消させる

### 11-2. AWS 側で消えたことを確認

```bash
aws s3 ls | grep idp-
```

何も出なければ OK です。

### 11-3. kind クラスターを削除

```bash
kind delete cluster --name idp-lab
```

### 11-4. Terraform の IAM を不要なら削除

Terraform で作った IAM ユーザーも不要なら、ユーザー自身で Terraform の `destroy` を実行してください。

## 12. 途中で詰まりやすいポイント

### Provider が `HEALTHY=True` にならない

```bash
kubectl describe provider provider-aws-s3
kubectl describe provider provider-aws-iam
kubectl get pods -n crossplane-system
```

よくある原因:

- Docker ネットワーク
- イメージ pull 中
- ローカルメモリ不足

### Claim が `READY=True` にならない

```bash
kubectl describe storage myapp-storage -n team-alpha
kubectl describe xstorage
kubectl get managed -A
kubectl logs -n crossplane-system -l pkg.crossplane.io/revision --tail=100
```

よくある原因:

- S3 バケット名の競合
- ProviderConfig 未適用
- AWS Secret 不備
- IAM 権限不足

### ArgoCD が `OutOfSync` のまま

```bash
kubectl describe application crossplane-platform -n argocd
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller --tail=50
```

よくある原因:

- `repoURL` の書き換え漏れ
- private repo なのに認証未設定
- `team-alpha` namespace 周りの不整合

### Backstage でテンプレートが見えない

確認ポイント:

- `GITHUB_TOKEN` が設定されているか
- `app-config.yaml` の `catalog.locations.target` が `./templates/...` になっているか
- `yarn dev` 起動ログにエラーがないか

## 13. ディレクトリ構成

```text
k8s-idp-lab/
├── README.md
├── ARCHITECTURE.md
├── kind-cluster.yaml
├── argocd/
│   ├── apps/
│   └── install/
├── backstage/
│   ├── app-config.yaml
│   └── templates/
├── crossplane/
│   ├── claims/
│   ├── compositions/
│   └── providers/
├── docs/
└── terraform/
    ├── crossplane-iam/
    └── eks-cluster/
```

責務の要約:

- `terraform/crossplane-iam/`: Crossplane 用 AWS 権限
- `crossplane/compositions/`: 開発者 API と実装
- `crossplane/claims/`: 開発者が追加する宣言
- `argocd/apps/`: GitOps 同期設定
- `backstage/templates/`: セルフサービス UI の雛形

## 14. このハンズオンの理解ポイント

このリポジトリの本質は、責務が 3 段に分かれていることです。

1. 開発者は `Storage` Claim だけを書く
2. ArgoCD が Git の宣言をクラスターへ同期する
3. Crossplane がその宣言を AWS リソースへ変換する

Terraform はその前段で、Crossplane が AWS を触るための土台だけを用意します。

この分離が見えると、なぜ IDP が「セルフサービス」と「標準化」を両立できるのかが掴みやすくなります。
