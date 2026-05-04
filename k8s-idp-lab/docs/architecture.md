# アーキテクチャ概要

## 全体構成

```
┌─────────────────────────────────────────────────────────────────┐
│ 開発者の操作                                                      │
│                                                                   │
│   Backstage UI でフォームを入力                                    │
│   （appName・environment・versioning）                            │
└───────────────────────────┬─────────────────────────────────────┘
                            │ Scaffolder が YAML 生成 & Git push
┌───────────────────────────▼─────────────────────────────────────┐
│ Git リポジトリ（GitHub）                                          │
│                                                                   │
│   crossplane/claims/myapp-takuya-storage.yaml が追加される        │
└───────────────────────────┬─────────────────────────────────────┘
                            │ ArgoCD が変更を検知（3 分ごとにポーリング）
┌───────────────────────────▼─────────────────────────────────────┐
│ kind クラスター（ローカル）                                        │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ ArgoCD（argocd namespace）                                │   │
│  │  Application: crossplane-platform                        │   │
│  │  → crossplane/claims/ を監視・自動 apply                  │   │
│  └───────────────────────┬──────────────────────────────────┘   │
│                          │ kubectl apply                         │
│  ┌───────────────────────▼──────────────────────────────────┐   │
│  │ Crossplane（crossplane-system namespace）                 │   │
│  │  provider-aws-s3 / provider-aws-iam                      │   │
│  │  Claim → XRD → Composition → Managed Resource            │   │
│  └───────────────────────┬──────────────────────────────────┘   │
└──────────────────────────┼──────────────────────────────────────┘
                           │ AWS API 呼び出し
┌──────────────────────────▼──────────────────────────────────────┐
│ AWS（ap-northeast-1）                                            │
│                                                                   │
│   S3 Bucket: idp-myapp-takuya-dev                                │
│   （app-environment Composition の場合は IAM Role も作成）        │
└─────────────────────────────────────────────────────────────────┘
```

## コンポーネント詳細

### kind クラスター

| ノード | 役割 | ポートマッピング |
|---|---|---|
| control-plane | K8s API サーバー・etcd | - |
| worker | ArgoCD・Crossplane の Pod が動く | - |
| worker2 | 同上 | - |

ホストからのアクセス:
- `http://localhost:30080` → ArgoCD UI
- `http://localhost:3000` → Backstage UI（Phase 8）

### Crossplane の Composition 一覧

| Composition | 用途 | 作成されるリソース |
|---|---|---|
| `s3-storage` | S3 バケットのみ | Bucket + BucketVersioning |
| `app-environment` | アプリ環境フルセット | Bucket + BucketVersioning + IAM Role + IAM Policy + RolePolicyAttachment |

Claim 作成時に `compositionRef.name` で選択する。

### IAM 設計

```
IAM ユーザー: idp-lab-crossplane（Terraform で作成、Phase 0）
  ├── ポリシー: idp-lab-crossplane-s3
  │     → s3:* on arn:aws:s3:::idp-*
  └── ポリシー: idp-lab-crossplane-iam
        → iam:* on arn:aws:iam::*:role/crossplane/*
              arn:aws:iam::*:policy/crossplane/*

IAM ロール: idp-<appName>-<env>-role（Crossplane が作成、Phase 5 以降）
  → /crossplane/ パス配下
  → アプリが S3 バケットにアクセスするために使う
```

## データフロー詳細

### Claim が S3 バケットになるまで

```
1. 開発者が kubectl apply -f example-storage.yaml
   または Backstage の Submit ボタンを押す

2. K8s API が Storage(Claim) リソースを team-alpha namespace に作成

3. Crossplane が Claim を検知
   → compositionRef: s3-storage を参照
   → XStorage(Composite Resource) を作成

4. Composition の patches が変換:
   appName=myapp-takuya + environment=dev
   → external-name = "idp-myapp-takuya-dev"

5. Managed Resource を作成:
   - Bucket.s3.aws.upbound.io
   - BucketVersioning.s3.aws.upbound.io

6. provider-aws-s3 が AWS API を呼び出し:
   - s3:CreateBucket → バケット作成
   - s3:PutBucketVersioning → バージョニング設定
   - s3:PutBucketTagging → タグ付け

7. Managed Resource の READY=True、Claim の READY=True になる
```

### ドリフト検出と自動修復

```
Crossplane: 定期的に AWS API で実際の状態を確認
  → 差分があれば AWS API で修復

ArgoCD: 定期的に K8s クラスターの状態と Git を比較
  → Claim が削除されていれば再 apply（selfHeal: true）
```

## 技術的な選択と理由

| 選択 | 理由 |
|---|---|
| kind（EKS でなく） | コスト削減（EKS は $0.10/時間）、即時起動 |
| Upbound provider-aws（公式 AWS provider でなく） | CRD が細かく分かれておりバイナリサイズが小さい、機能が豊富 |
| NodePort（Ingress でなく） | kind 環境では Ingress Controller の追加設定が不要 |
| SQLite（PostgreSQL でなく） | Backstage のローカル起動をシンプルにする |
