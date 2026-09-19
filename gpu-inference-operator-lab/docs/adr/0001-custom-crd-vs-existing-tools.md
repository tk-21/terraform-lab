# ADR 0001: 独自CRD (AIInferenceService) vs 既存ツール (KEDA / HPA)

**Status**: Accepted  
**Date**: 2026-07-22

---

## Context

AI推論ワークロード(vLLM on EKS)のライフサイクル管理において、以下の要件を単一のコントロールプレーンで実現する必要がある:

1. **カスタムオートスケーリング**: GPUキュー深度・GPU使用率に基づくスケーリング(DCGM Exporter連携)
2. **Bedrockフォールバック**: GPUノードのコールドスタート(3-5分)中にSLOを維持するための自動切替
3. **自己修復**: OOMKilled / CrashLoopBackOff の自動検知・再起動・状態管理
4. **状態の一元表現**: Running / Provisioning / Fallback / Degraded の各フェーズをKubernetes標準のStatus/Conditionで表現
5. **定量的な計測**: 独自実装することで反応速度・MTTR等を精密に計測・比較する

---

## Options

### Option A: KEDA ScaledObject (却下)

KEDAはキュー深度・Prometheusメトリクス等の外部スケーラーによるHPAの拡張を提供する。

**できること:**
- カスタムメトリクスによるDeploymentのスケーリング

**できないこと:**
- Bedrockフォールバックの制御ロジック
- OOMKilled検知・自己修復
- GPUプロビジョニング状態の追跡
- 単一リソースでのライフサイクル全体の表現

**問題点**: スケーリング機能のみを担当し、残りのフォールバック・自己修復は別途実装が必要になる。
結果として複数のコントローラーが同一リソースを監視する複雑な構成になる。

### Option B: HPA + カスタムメトリクスアダプター (却下)

HPAはKubernetes標準のスケーリング機構だが、カスタムメトリクスアダプターが必要で設定が複雑。

**できること:**
- Prometheus Adapter経由でGPU使用率によるスケーリング

**できないこと:**
- Option Aと同様の問題。さらにKEDAより設定の複雑度が高い

### Option C: 独自 CRD + Operator (採用)

`AIInferenceService` CRDを定義し、Reconcileループで全ライフサイクルを管理する。

**メリット:**
- スケーリング・フォールバック・自己修復を単一のreconcileループで処理
- Kubernetes標準のStatus/Conditionで状態を表現し、既存のモニタリングツールと統合可能
- 内部実装を制御できるため、反応速度・MTTR等の定量計測が精密に行える
- 面接で「なぜその設計にしたか」を語れる差別化になる

**デメリット:**
- 実装コストが高い(KEDAの数行設定 vs 数百行のGoコード)
- バグリスク・メンテナンスコストが増加する

---

## Decision

*(このセクションはユーザー自身が記述する)*

---

## Consequences

- Go / controller-runtime の習熟が必要
- テスト戦略としてenvtest + Kindを使用する
- Phase 2以降でReconcileループに段階的に機能を追加していく
