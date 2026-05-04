# トラブルシューティング

## 症状別の対処手順

### Provider が HEALTHY にならない

```bash
kubectl get providers
# NAME                  INSTALLED   HEALTHY   AGE
# provider-aws-s3       True        False     5m  ← ここが False
```

**確認手順:**

```bash
kubectl describe provider provider-aws-s3
# Events セクションを確認する
```

**よくある原因と対処:**

| 原因 | 確認方法 | 対処 |
|---|---|---|
| イメージ Pull 失敗 | Events に `ImagePullBackOff` | Docker のネットワーク・プロキシ設定を確認 |
| イメージ Pull 中（正常） | Events に `Pulling` | 3〜5 分待つ（イメージが大きい） |
| メモリ不足 | `kubectl top nodes` | Docker に割り当てるメモリを増やす（8GB 以上推奨） |

---

### Claim が READY にならない

```bash
kubectl get storage -n team-alpha
# NAME             READY   SYNCED   AGE
# myapp-storage    False   False    2m  ← READY/SYNCED が False
```

**確認手順:**

```bash
# 1. Claim のイベントを確認
kubectl describe storage myapp-storage -n team-alpha

# 2. Composite Resource のイベントを確認
kubectl describe xstorage

# 3. Managed Resource のイベントを確認
kubectl describe bucket -l crossplane.io/composite

# 4. crossplane-system のログを確認
kubectl logs -n crossplane-system -l pkg.crossplane.io/revision --tail=100
```

**よくある原因と対処:**

| 原因 | 症状 | 対処 |
|---|---|---|
| IAM 権限不足 | `AccessDenied` エラー | `terraform/crossplane-iam/` の apply を確認、権限の再確認 |
| ProviderConfig 未適用 | `no matching ProviderConfig` | `kubectl apply -f crossplane/providers/provider-config.yaml` |
| aws-credentials Secret なし | `secret not found` | Phase 3 の手順を再実行 |
| S3 バケット名の重複 | `BucketAlreadyExists` | `appName` を変更して再 apply |
| Provider が HEALTHY でない | Provider の状態が False | Provider が HEALTHY になるまで待つ |
| ProviderConfig を Provider より先に apply | CRD が存在しないエラー | Provider が HEALTHY になってから ProviderConfig を apply |

---

### S3 バケット名の重複エラー

```
BucketAlreadyExists: The requested bucket name is not available
```

S3 バケット名は AWS 全体でグローバルに一意である必要がある。

```bash
# 既存バケットを確認
aws s3 ls | grep idp-

# appName を変更して再 apply（例: myapp → myapp-takuya-20260504）
kubectl edit storage myapp-storage -n team-alpha
```

---

### ArgoCD が Sync しない

```bash
kubectl get application -n argocd
# NAME                   SYNC STATUS   HEALTH STATUS
# crossplane-platform    OutOfSync     Degraded
```

**確認手順:**

```bash
# アプリの詳細を確認
kubectl describe application crossplane-platform -n argocd

# ArgoCD のログを確認
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller --tail=50
```

**よくある原因と対処:**

| 原因 | 対処 |
|---|---|
| `repoURL` が `YOUR_GITHUB_USERNAME` のまま | `argocd/apps/platform-app.yaml` の URL を自分のリポジトリに変更 |
| リポジトリが Private で認証情報なし | ArgoCD に GitHub Token を登録する（下記参照） |
| `team-alpha` namespace が存在しない | `kubectl create namespace team-alpha` |

**GitHub 認証情報を ArgoCD に登録する:**

```bash
kubectl create secret generic github-credentials \
  -n argocd \
  --from-literal=username=YOUR_GITHUB_USERNAME \
  --from-literal=password=ghp_YOUR_GITHUB_TOKEN \
  --from-literal=type=git \
  --from-literal=url=https://github.com/YOUR_GITHUB_USERNAME/k8s-idp-lab.git

kubectl label secret github-credentials \
  -n argocd \
  argocd.argoproj.io/secret-type=repository
```

---

### kind のポートにアクセスできない

`http://localhost:30080` にアクセスしても繋がらない。

```bash
# kind コンテナが動いているか確認
docker ps | grep kind

# ArgoCD の NodePort Service が作成されているか確認
kubectl get svc -n argocd argocd-server-nodeport
```

**対処:**

```bash
# NodePort Service が存在しない場合
kubectl apply -f argocd/apps/argocd-nodeport.yaml

# kind が起動していない場合
kind create cluster --config kind-cluster.yaml
```

---

### Backstage が起動しない

```bash
cd backstage
yarn dev
```

**よくある原因と対処:**

| 原因 | 症状 | 対処 |
|---|---|---|
| Node.js バージョンが古い | `engine "node" is incompatible` | Node.js 18 以上をインストール |
| GITHUB_TOKEN が未設定 | GitHub API 認証エラー | `export GITHUB_TOKEN=ghp_xxx` を実行してから再起動 |
| ポート 3000 が使用中 | `EADDRINUSE` | `lsof -i :3000` で確認、使用中プロセスを終了 |

---

### Terraform apply でエラーが出る

```bash
cd terraform/crossplane-iam
terraform apply
```

**よくある原因と対処:**

| 原因 | エラーメッセージ例 | 対処 |
|---|---|---|
| AWS 認証情報が未設定 | `NoCredentialProviders` | `aws configure` または環境変数を設定 |
| 既存リソースとの競合 | `EntityAlreadyExists` | `terraform import` で既存リソースを取り込む |
| S3 バケットへの権限なし | `AccessDenied` | 実行している IAM ユーザーに `s3:CreateBucket` 権限を付与 |

---

## まとめてデバッグ情報を取得するワンライナー

```bash
echo "=== Providers ===" && kubectl get providers && \
echo "=== Claims ===" && kubectl get storage -A && \
echo "=== Managed Resources ===" && kubectl get managed -A && \
echo "=== ArgoCD Apps ===" && kubectl get application -n argocd && \
echo "=== Recent Events ===" && kubectl get events --sort-by='.lastTimestamp' -A | tail -20
```
