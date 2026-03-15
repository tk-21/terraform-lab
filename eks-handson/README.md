以下に **このまま README.md を置き換えできる完全版**として更新しました。
今回の更新ポイントは：

* **infra → kubeconfig → platform** の順序を「クイックスタート」「詳細手順」両方に明示
* **Makefile の TAB 必須**＆よくある `missing separator` を README 側で先に潰す
* あなたが実際に踏んだトラブル（`cluster not found` / webhook `no endpoints` / `StorageClass gp3 not found` / `localhost:80`）を「調査→復旧」込みで整理
* **gp3 StorageClass を “毎回手動で作らない” 方針**（Git 管理して `kubectl apply` or platform 側で管理）を README に明記
* kustomize の `remove` patch エラー（存在しないキー削除）も対処方針を追加

---

# EKS Terraform × Kubernetes 実務ハンズオン
（作って・壊して・理解する）

このリポジトリは、Terraform で **EKS を構築**し、Kubernetes（Helm / Argo CD / Kustomize）を用いて  
**「作って → 動かして → 壊して → 直す」** を一気通貫で体験する **実務想定ハンズオン**です。

単なる構築手順ではなく、

* なぜその構成が必要なのか
* 壊れると何が起きるのか
* どう調査・復旧するのか

を **体感ベースで理解する**ことを目的としています。

---

## このハンズオンの学習ゴール

### A. Kubernetes基礎（壊して理解）
* Pod / Deployment / ReplicaSet の責務と関係
* readiness / liveness の違いと実務影響
* Service / Ingress の役割と責務分離
* Ingress Controller / Webhook が無いと “作れない/壊れる” を理解

### B. ストレージ完全理解（EBS CSI）
* PVC → PV → EBS のライフサイクル
* Pod 再作成時にデータがどう扱われるか
* IAM（IRSA/Node Role）と CSI Driver の依存関係
* 障害再現 → 調査 → 復旧フローを一通り体験

---

## 前提条件

### ローカル環境
* AWS CLI v2
* Terraform >= 1.5
* kubectl
* helm
* kustomize
* Make
* AWS 認証済み（以下が成功すること）

```bash
aws sts get-caller-identity
```

---

## ディレクトリ構成（重要）

このリポジトリは **Terraform が2段構成**です。

* `infra/`：EKS/VPC/NodeGroup/Add-on など「土台」
* `platform/`：ALB Controller / Argo CD / StorageClass など「クラスタ上に載るもの」


```
.
├── infra/
│   └── envs/dev/                  # Terraform（VPC/EKS/NodeGroup/Add-ons）
├── platform/
│   └── envs/dev/                  # Terraform（ALB Controller / ArgoCD など）
├── apps/
│   └── demo-web/
│       ├── base/                  # Kubernetes 基本リソース（Deployment/Service/Ingress/PVC）
│       └── overlays/
│           ├── dev/               # 通常（健全）
│           ├── dev-break-readiness/
│           ├── dev-break-liveness/
│           └── dev-pvc2/          # CSI破壊で Pending を確実に出す用（新規PVC + deploy切替）
├── Makefile                        # 実行・観察を自動化（推奨）
└── README.md
```



---

## まず結論：実行の正しい順番

**必ずこの順で実行します。**

1. `infra/envs/dev` で apply（EKS が無いと platform は失敗する）
2. kubeconfig を更新（kubectl / helm がクラスタに接続できるようにする）
3. `platform/envs/dev` で apply（ALB Controller / ArgoCD 等を載せる）
4. アプリを apply（Kustomize）

---

## クイックスタート（迷ったらこれ）

```bash
make tf-init
make tf-apply
make wait-core
make wait-alb
make pvc-apply
make app-apply
make obs-all
```

> ✅ **Makefile 注意（超重要）**
> `Makefile: *** missing separator` は **TAB がスペースに置換**されているのが原因です。
> Makefile のレシピ行は必ず TAB で始まる必要があります（エディタ設定に注意）。

---

# ① 作る（EKS 構築）

## 1) Terraform 初期化（2箇所）

```bash
terraform -chdir=infra/envs/dev init -upgrade
terraform -chdir=platform/envs/dev init -upgrade
```

## 2) EKS 作成（infra）

```bash
terraform -chdir=infra/envs/dev apply
```

作成される主なリソース（想定）：

* VPC / Subnet / NAT
* EKS Cluster
* Managed Node Group
* EKS Add-ons（例：aws-ebs-csi-driver）
* OIDC Provider（IRSA 用）

## 3) kubectl 接続（kubeconfig）

```bash
aws eks update-kubeconfig --region ap-northeast-1 --name eks-handson-dev
kubectl get nodes -o wide
```

## 4) platform の適用（ALB Controller / Argo CD）

```bash
terraform -chdir=platform/envs/dev apply
```

> **補足（重要）**
> platform は Kubernetes API を叩く（Namespace 作成 / Helm install）ため、
> **ALB Controller の Webhook endpoints が 0 の瞬間**に走ると
> `failed calling webhook ... no endpoints available` で落ちます。
> そのため Makefile に `wait-alb`、または platform 側に wait 処理を入れています。

---

# ② Argo CD 確認（UI ログイン）

## ポートフォワード

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80
```

## 初期 admin パスワード取得

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

* URL: [http://localhost:8080](http://localhost:8080)
* User: `admin`

---

# ③ アプリデプロイ（Kustomize）

```bash
kubectl apply -k apps/demo-web/overlays/dev
kubectl -n demo get deploy,svc,ingress -o wide
```

---

# A. Kubernetes基礎ハンズオン（壊して理解）

## A-1 Pod / Deployment / ReplicaSet

```bash
kubectl -n demo get deploy,rs,pod -o wide
kubectl -n demo scale deploy demo-web --replicas=3
kubectl -n demo delete pod -l app=demo-web
kubectl -n demo get rs,pod -o wide
```

理解ポイント：

* **Pod は使い捨て**
* Desired State（望ましい状態）は Deployment が持つ
* 実体の Pod 群は ReplicaSet が管理する

---

## A-2 readiness を壊す（Running だが “サービス提供不可”）

```bash
make app-break-rdy
make obs-readiness
```

観察ポイント：

* Pod は `Running` だが Ready にならない
* Service の endpoints から外れる（= ルーティングされない）
* ALB/Ingress 側から到達できない（または 502/503）

復旧：

```bash
make app-recover
```

---

## A-3 liveness を壊す（CrashLoopBackOff）

```bash
make app-break-liv
make obs-liveness
```

観察ポイント：

* Pod が再起動ループ（CrashLoopBackOff）
* Events に `BackOff` / `Unhealthy` が出る
* `kubectl logs` の末尾が復旧のヒントになる

復旧：

```bash
make app-recover
```

---

## A-4 Service / Ingress の責務理解

```bash
make obs-net
```

理解ポイント：

* Service：Pod の集合に対する **安定した接点**
* Ingress：L7 ルーティングの **宣言**
* 実際に ALB を作るのは **Controller**
* Webhook が死ぬと「Ingress/Service の作成が拒否/失敗」になる

---

# B. ストレージ完全理解（EBS CSI）

## まず重要：StorageClass（gp2/gp3）は「毎回手動？」問題

結論：

* **毎回手動は不要**です。
* ただし **どこで管理するか**を決める必要があります。

おすすめは次のどちらか：

### 方式1（おすすめ）：Git 管理の YAML として `kubectl apply`

* `apps/cluster/storageclass/gp3.yaml` などに置く
* `make sc-apply` のように一発適用にする
* Terraform state に持たない（運用が軽い）

### 方式2：platform 側で Terraform 管理（kubernetes provider）

* `kubernetes_storage_class_v1` で作る
* ただし **kubeconfig/接続順**を間違えると `localhost:80` のような事故が起きやすい

このリポジトリは “壊して学ぶ” 目的なので、まずは **方式1**（kubectl apply）を推奨します。

---

## B-1 PVC → PV → EBS 作成（通常）

```bash
make pvc-apply
make obs-storage
```

理解ポイント：

* PVC は「欲しいボリュームの要求」
* PV は「確保された実体（CSI では動的作成）」
* EBS は AWS 側の実体（Volume）

---

## B-2 データ書き込み → Pod 再作成（永続化の確認）

```bash
make pvc-write
make pvc-recreate
```

理解ポイント：

* Pod を消してもデータは残る（= state はストレージが担う）

---

## B-3 AWS 側の EBS 実体確認

```bash
make pvc-ebs
```

理解ポイント：

* CSI Driver が AWS API を呼んで EBS を作っている
* IAM が足りないと 403 で死ぬ（IRSA/Node Role のどちらか）

---

## B-4 障害再現：EBS CSI を壊す（Pending を “確実” に出す）

### なぜ `pvc2` を使うのか

既存 PVC はすでに PV/EBS を持っているため、CSI を削除しても
「既存 PV に再接続できてしまう」ケースがあり、**Pending が再現しづらい**ことがあります。

そこで、CSI 削除後に **新規 PVC（demo-pvc2）** を作り、
Provision ができず **Pending を確実に観測**します。

### 手順

```bash
make csi-delete
make pvc2-apply
```

観察：

```bash
kubectl -n demo get pvc,pv
kubectl -n demo describe pvc demo-pvc2 | tail -n 80
kubectl -n demo get events --sort-by=.lastTimestamp | tail -n 50
```

復旧：

```bash
make csi-restore
make pvc2-apply
```

---

# ⑥ よくあるトラブルと対処（実務あるある）

## ❌ platform apply が「EKS cluster が見つからない」

例：

```
Error: reading EKS Cluster (eks-handson-dev): couldn't find resource
```

原因：

* **infra を apply していない**
* cluster 名/region がズレている

対処：

```bash
terraform -chdir=infra/envs/dev apply
aws eks update-kubeconfig --region ap-northeast-1 --name eks-handson-dev
terraform -chdir=platform/envs/dev apply
```

---

## ❌ helm_release が webhook エラーで失敗（no endpoints）

例：

```
failed calling webhook "mservice.elbv2.k8s.aws": ... no endpoints available
```

確認：

```bash
kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-load-balancer-controller -o wide
kubectl -n kube-system get endpoints aws-load-balancer-webhook-service -o wide
```

対処：

```bash
make wait-alb
terraform -chdir=platform/envs/dev apply
```

---

## ❌ PVC が Pending（StorageClass が無い / 名前が違う）

あなたが踏んだ例：

* `storageclass.storage.k8s.io "gp3" not found`

対処：

* まず StorageClass を確認して、PVC の `storageClassName` と一致させる

```bash
kubectl get sc -o wide
kubectl -n demo get pvc demo-pvc -o yaml | egrep -n 'storageClassName:'
```

暫定復旧（すぐ動かす）：

* PVC を `gp2` にする or `gp3` StorageClass を作る

---

## ❌ kubernetes provider が `localhost:80` を見に行って死ぬ

例：

```
Post "http://localhost/apis/...": dial tcp 127.0.0.1:80: connect: connection refused
```

原因：

* Terraform の kubernetes provider が「接続情報を持っていない」
* kubeconfig が更新されていない / context が違う
* `provider "kubernetes"` が data参照ではなくデフォルトのまま

対処（基本）：

1. 先に kubeconfig を更新し、kubectl が繋がることを確認
2. platform を apply する（kubernetes provider を使うのは platform 側に寄せる）

```bash
aws eks update-kubeconfig --region ap-northeast-1 --name eks-handson-dev
kubectl get nodes
terraform -chdir=platform/envs/dev apply
```

---

## ❌ kustomize の remove patch が “存在しないキー削除” で失敗

例：

```
Unable to remove nonexistent key: kubernetes.io/ingress.class
```

原因：

* その Ingress に annotation がそもそも無い

対処方針：

* **remove patch をやめる**（= 最初から annotation を入れない）
* もしくは、annotation を base に入れて「必ず存在する」状態にしてから remove する（あまりおすすめしない）

推奨：

* Ingress は `spec.ingressClassName` を使い、annotation は使用しない

---

## ❌ destroy 時の provider lock エラー

例：

```
Inconsistent dependency lock file ...
```

対処：

```bash
terraform -chdir=infra/envs/dev init -upgrade
terraform -chdir=platform/envs/dev init -upgrade
make destroy
```

---

# ⑦ 壊す（完全削除）

**逆順が鉄則**（platform → infra）です。

```bash
make destroy
```

---

# このハンズオンで身につくこと（最終まとめ）

* Terraform による **EKS 構築と破棄（2段構成の責務分離）**
* Pod / Deployment / ReplicaSet の関係を “壊して理解”
* readiness / liveness の実務的意味（SLO/障害影響の違い）
* Service / Ingress / Controller / Webhook の依存関係
* PVC / PV / EBS / CSI Driver のライフサイクル理解
* IAM の不足が **即障害になる**ことの体感
* apply → 失敗 → 調査 → 修正 → 再 apply の実務フロー

---

# 次の発展案（おすすめ）

* Argo CD を Application 化して GitOps 完全化
* Ingress を複数ルールに拡張（パス/host/weighted）
* PodDisruptionBudget / HPA を入れて “落ちにくさ” を検証
* Node を 1台落とす・AZ障害を想定して挙動確認
* CSI を IRSA 完全設計にして “本番想定” を完成させる


---

必要なら次に、README と整合するように **Makefile に StorageClass 管理（方式1：kubectl apply）を追加**します。  
（例：`make sc-apply` / `make sc-status` / `make sc-gp3-default` など）


---

## クイックスタート（迷ったらこれ）

```bash
make tf-init
make tf-apply
make wait-core
make wait-alb
make pvc-apply
make app-apply
make obs-all
```

---


---

## 使い方（この環境で “作って→壊して→戻す” 最短コース）

### 作る

```bash
make tf-init
make tf-apply
make wait-core
make wait-alb
make status
```

### アプリ + 永続化

```bash
make pvc-apply
make app-apply
make pvc-write
make pvc-recreate
make pvc-ebs
```

### 壊して理解（readiness / liveness）

```bash
make app-break-rdy
make obs-readiness
make app-recover

make app-break-liv
make obs-liveness
make app-recover
```

### 片付け

```bash
make destroy
```

---
