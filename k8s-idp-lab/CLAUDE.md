# k8s-idp-lab

## プロジェクト概要

Crossplane × ArgoCD × Backstage で「開発者が YAML 1枚書くだけで AWS リソースが自動プロビジョニングされる内部開発者プラットフォーム（IDP）」を構築するハンズオン。

**ゴール:** 開発者が Backstage の UI でフォームを埋める → Git に YAML が commit される → ArgoCD が検知 → Crossplane が AWS にリソースを作る、という一気通貫フローを動かす。

## ディレクトリ構成

```
k8s-idp-lab/
├── CLAUDE.md
├── kind-cluster.yaml
├── crossplane/
│   ├── providers/
│   │   ├── aws-provider.yaml
│   │   └── provider-config.yaml
│   ├── compositions/
│   │   ├── s3-bucket-xrd.yaml
│   │   ├── s3-bucket-composition.yaml       # S3 バケットのみ
│   │   └── app-environment-composition.yaml # S3 + IAM ロールのセット
│   └── claims/
│       └── example-storage.yaml
├── argocd/
│   ├── install/
│   │   └── install.sh
│   └── apps/
│       ├── platform-app.yaml
│       └── argocd-nodeport.yaml
├── backstage/
│   ├── app-config.yaml
│   └── templates/
│       └── aws-environment/
│           ├── template.yaml
│           └── skeleton/
│               └── crossplane-claim.yaml
├── terraform/
│   └── crossplane-iam/                      # Crossplane 用 IAM（Phase 0）
│       ├── main.tf
│       ├── iam.tf
│       ├── variables.tf
│       ├── locals.tf
│       ├── outputs.tf
│       └── versions.tf
└── docs/
    ├── architecture.md
    ├── crossplane-guide.md
    └── troubleshooting.md
```

## 技術スタック・バージョン

| ツール | バージョン | 用途 |
|---|---|---|
| Kubernetes | 1.28+ | 実行基盤（kind または EKS） |
| Crossplane | 1.15.0 | K8s から AWS リソースを宣言的管理 |
| Crossplane AWS Provider | 1.1.0 | S3 / IAM / EC2 操作 |
| ArgoCD | stable | GitOps 同期 |
| Backstage | latest | 開発者ポータル |
| Terraform | 1.6+ | EKS クラスター構築 |
| AWS CLI | v2 | AWS 操作 |
| kubectl | 1.28+ | K8s 操作 |
| Helm | 3.12+ | K8s パッケージ管理 |
| Node.js | 18+ | Backstage 実行 |

## AWS 設定

- **リージョン**: ap-northeast-1（東京）固定
- **認証**: `terraform/crossplane-iam/` で作成した IAM ユーザーのアクセスキーを使用
- **タグ戦略**: 全リソースに `ManagedBy: crossplane`、`Environment: <env>`、`Project: k8s-idp-lab` を付与

## コーディング規約

### YAML
- インデント: スペース 2 つ
- コメント: 日本語 OK。意図（なぜそう書くか）を説明する
- `metadata.labels` には必ず `app` と `managed-by` を含める

### Kubernetes リソース
- namespace は用途別に分ける: `crossplane-system` / `argocd` / `team-<name>`
- Claim は必ず namespace スコープで作成する（Cluster スコープにしない）
- `compositionRef` は明示的に指定する

### Terraform
- モジュール構成を使う
- `variable` には必ず `description` を書く
- `output` には `sensitive = true` を適切に設定する

## よく使うコマンド

```bash
# Crossplane の状態確認
kubectl get crossplane                          # 全 Crossplane リソース一覧
kubectl get managed                             # AWS リソースの同期状態
kubectl get composite                           # Composite Resource の状態
kubectl get claim -A                            # 全 namespace の Claim

# Crossplane のデバッグ
kubectl describe <resource> <name>              # イベントと状態を確認
kubectl get events --sort-by='.lastTimestamp'   # 最近のイベント

# ArgoCD の状態確認
kubectl get application -n argocd
argocd app get <app-name>
argocd app sync <app-name>

# ログ確認
kubectl logs -n crossplane-system -l app=crossplane --tail=50
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --tail=50
```

## 進め方のルール

1. **ファイルを作る前に必ずこの CLAUDE.md を参照して** ディレクトリ構成・命名規則を確認する
2. **各ステップの後に動作確認コマンドを実行**して READY=True を確認してから次に進む
3. **エラーが出たら `kubectl describe` と `kubectl get events` を必ず確認**してから修正する
4. **Crossplane リソースを削除するときは Claim から削除**する（Managed Resource を直接消さない）
5. **コストを意識する**: ハンズオン中は不要なリソースを作らない。終了後は必ずクリーンアップする

## トラブルシューティングの基本手順

```
READY=False または SYNCED=False が出たら:
  1. kubectl describe <resource> <name> でイベントを確認
  2. kubectl logs -n crossplane-system でコントローラーログを確認
  3. AWS IAM 権限が不足していないか確認
  4. Provider が HEALTHY かどうか確認: kubectl get providers

ArgoCD が Sync されない:
  1. kubectl get application -n argocd で状態確認
  2. argocd app get <name> で詳細確認
  3. Git リポジトリへの接続情報（Secret）を確認
```

## 参考ドキュメント

- Crossplane: https://docs.crossplane.io/latest/
- ArgoCD: https://argo-cd.readthedocs.io/
- Backstage: https://backstage.io/docs/
- AWS Provider: https://marketplace.upbound.io/providers/upbound/provider-aws