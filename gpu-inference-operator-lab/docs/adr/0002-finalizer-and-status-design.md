# ADR-0002: Finalizer と Status Condition の設計判断

## Status

Accepted

## Context

Phase 2でReconcileループの基本実装を行うにあたり、以下の2点について設計判断が必要だった。

### 1. Finalizer の要否

`AIInferenceService` CRを削除した場合、OwnerReferenceによってDeployment/ServiceはKubernetesのGCで自動削除される。
しかし本Operatorが将来管理する予定のリソースには、Kubernetesが関知しない外部状態が含まれる:

- Bedrockフォールバックセッション (Phase 4)
- GPU memory fragmentやpersistent inference cache (将来)
- Chatwork通知の送信 (Phase 4)

これらはOwnerReferenceのGCでは解放されないため、CR削除のタイミングをOperatorが「知る」仕組みが必要だった。

### 2. Status Condition の表現方法

Kubernetesでは `kubectl get` で状態が見える `status.conditions` が慣例だが、
以下の選択肢があった:

**Option A: `status.phase` のみ**
- シンプルだが、「なぜそのフェーズになったか」が分からない
- トラブルシューティング時に `kubectl describe` してもエラー理由が見えない

**Option B: `status.conditions` (Kubernetes標準 condition pattern)**
- `type`, `status`, `reason`, `message`, `lastTransitionTime` の5フィールドで詳細状態を表現
- `kubectl get ais -o wide` で定量的な状態遷移ログが残る
- StatusがTrueからFalseに変化した場合のみ `lastTransitionTime` が更新される(ノイズ抑制)

**Option C: カスタムフィールド**
- 独自フォーマットは `kubectl` のプラグインや外部ツールとの互換性を失う

## Options

| 案 | Finalizer | Status |
|---|---|---|
| 1 | なし | phase のみ |
| 2 | `inference.takuya.dev/cleanup` | phase + conditions |
| 3 | `inference.takuya.dev/cleanup` | カスタムフィールド |

## Decision

> **⚠️ このセクションは自分で書く(AI生成禁止)**
>
> なぜ上記Optionsの中でその選択をしたか、実装中に感じたトレードオフを自分の言葉で書く。
> 以下の問いへの回答を含めること:
> - Finalizerを今のPhaseで入れた理由(Phase 4以降に入れても良かったのでは?)
> - `status.conditions` に `Ready` / `Provisioning` / `Degraded` の3種類を選んだ理由
> - `setStatusCondition` ヘルパーを自前実装した理由(`apimeta.SetStatusCondition`を使わなかった理由)

---

## Consequences

### Finalizer

- CR削除時に `handleDeletion` が呼ばれ、外部リソースのクリーンアップを実行できる
- クリーンアップが失敗した場合、finalizerが残ったままになりCRが削除されない(意図的な安全策)
- Phase 4以降で `cleanupExternalResources` に実装を追加していく

### Status Conditions

- `kubectl get ais -o wide` で Phase/Backend/ReadyReplicas がひと目で分かる
- `kubectl describe ais <name>` の Conditions セクションで遷移履歴と理由が確認できる
- `lastTransitionTime` はStatusが変化した場合のみ更新されるため、
  ポーリング間隔でのreconcileが大量の更新を発生させない

### Leader Election

- `--leader-elect` フラグのデフォルトを `true` に変更した
- Operator を1レプリカで動かしても問題ない(leader electionのオーバーヘッドは軽微)
- HA構成(2レプリカ以上)で安全に動作するデフォルト設定を優先した
