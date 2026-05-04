# Crossplane 操作ガイド

## よく使うコマンド早見表

```bash
# ─ 状態確認 ─────────────────────────────────
kubectl get crossplane                          # 全 Crossplane リソース一覧
kubectl get providers                           # Provider の INSTALLED / HEALTHY 確認
kubectl get managed -A                          # AWS 上のリソース同期状態
kubectl get composite -A                        # Composite Resource (XStorage) の状態
kubectl get storage -A                          # Claim の状態（全 namespace）
kubectl get storage -n team-alpha               # 特定 namespace の Claim

# ─ デバッグ ──────────────────────────────────
kubectl describe provider provider-aws-s3       # Provider のイベント確認
kubectl describe storage myapp-storage -n team-alpha   # Claim のイベント確認
kubectl describe xstorage                       # Composite Resource のイベント確認
kubectl get events --sort-by='.lastTimestamp' -A | tail -30  # 最近のイベント

# ─ ログ ──────────────────────────────────────
kubectl logs -n crossplane-system -l app=crossplane --tail=50
kubectl logs -n crossplane-system -l pkg.crossplane.io/revision --tail=50
```

## リソースの状態フィールド

Crossplane リソースには `SYNCED` と `READY` の 2 つのステータスがある。

| フィールド | 意味 | True の条件 |
|---|---|---|
| `SYNCED` | Crossplane が最後の reconcile を問題なく実行できたか | AWS API の呼び出しにエラーがない |
| `READY` | AWS 上のリソースが期待通りの状態か | バケットが実際に使える状態になった |

`SYNCED=True` でも `READY=False` の場合は、AWS 側でリソースが作成中または設定中。

## Composition の選び方

このプロジェクトには 2 つの Composition がある。Claim 作成時に `compositionRef.name` で選ぶ。

### s3-storage（シンプル版）

S3 バケットとバージョニング設定のみ作成する。学習・動作確認用途に向いている。

```yaml
spec:
  compositionRef:
    name: s3-storage   # ← これを指定
  parameters:
    appName: myapp-takuya
    environment: dev
    versioning: false
```

### app-environment（フルセット版）

S3 バケット + IAM ロール + IAM ポリシーをセットで作成する。  
アプリが S3 にアクセスする権限も同時にプロビジョニングされる。

```yaml
spec:
  compositionRef:
    name: app-environment   # ← これを指定
  parameters:
    appName: myapp-takuya
    environment: dev
    versioning: true
```

作成されるリソース:
- `S3 Bucket`: `idp-myapp-takuya-dev`
- `IAM Role`: `idp-myapp-takuya-dev-role`（パス `/crossplane/`）
- `IAM Policy`: `idp-myapp-takuya-dev-policy`（パス `/crossplane/`）
- `RolePolicyAttachment`: ロールにポリシーをアタッチ

## Claim を作る

### 最小構成の Claim

```yaml
apiVersion: idp.example.com/v1alpha1
kind: Storage
metadata:
  name: myapp-storage
  namespace: team-alpha
spec:
  compositionRef:
    name: s3-storage
  parameters:
    appName: myapp-takuya    # 他ユーザーと重複しない名前にすること
    environment: dev
```

### パラメーター一覧

| パラメーター | 型 | 必須 | デフォルト | 説明 |
|---|---|---|---|---|
| `appName` | string | ✓ | - | S3 バケット名の一部。`^[a-z][a-z0-9-]{2,30}$` |
| `environment` | string | ✓ | - | `dev` / `staging` / `prod` のいずれか |
| `region` | string | | `ap-northeast-1` | AWS リージョン |
| `versioning` | boolean | | `false` | S3 バージョニングの有効/無効 |

## リソースの削除

**必ず Claim から削除すること。** Managed Resource を直接削除すると Crossplane が再作成しようとする。

```bash
# ✅ 正しい削除方法（Claim → Composite → Managed Resource の順に自動削除）
kubectl delete storage myapp-storage -n team-alpha

# Managed Resource が消えるまで確認（1〜2 分）
kubectl get managed -A -w

# ❌ やってはいけない削除方法
kubectl delete bucket idp-myapp-takuya-dev   # Crossplane が再作成する
```

## XRD と Composition の関係

```
XRD (s3-bucket-xrd.yaml)
  → kind: Storage / XStorage の API スキーマを定義
  → パラメーターの型・バリデーションを定義

Composition (s3-bucket-composition.yaml)
  → XStorage が作成されたとき何の Managed Resource を作るか定義
  → patches でパラメーターを各リソースにマッピング

Composition (app-environment-composition.yaml)
  → 同じ XStorage を使うが、S3 + IAM を作る別実装
  → compositionRef.name で使い分ける
```

## patches の仕組み

Composition の `patches` はパラメーターを各 Managed Resource に転送する変換ルール。

### よく使うパッチタイプ

**FromCompositeFieldPath**: Claim のフィールドを Managed Resource にそのままコピー

```yaml
- type: FromCompositeFieldPath
  fromFieldPath: spec.parameters.region
  toFieldPath: spec.forProvider.region
```

**CombineFromComposite**: 複数フィールドを組み合わせて文字列を生成

```yaml
- type: CombineFromComposite
  combine:
    variables:
      - fromFieldPath: spec.parameters.appName
      - fromFieldPath: spec.parameters.environment
    strategy: string
    string:
      fmt: "idp-%s-%s"   # → "idp-myapp-dev"
  toFieldPath: metadata.annotations[crossplane.io/external-name]
```

**transforms**: 値を変換してから適用する

```yaml
- type: FromCompositeFieldPath
  fromFieldPath: spec.parameters.versioning   # bool
  toFieldPath: spec.forProvider.versioningConfiguration[0].status
  transforms:
    - type: convert
      convert:
        toType: string      # bool → string ("true"/"false")
    - type: map
      map:
        "true": Enabled     # "true" → "Enabled"
        "false": Suspended  # "false" → "Suspended"
```
