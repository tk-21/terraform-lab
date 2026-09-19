# ADR-0003: カスタムスケーリングロジック vs KEDA

**Status**: Accepted  
**Date**: 2026-07-22  
**Author**: takuya

---

## Context

`AIInferenceService` のレプリカ数をGPU使用率またはSQSキュー深度に基づいて自動制御するメカニズムが必要。
既存の選択肢として KEDA (Kubernetes Event-Driven Autoscaler) と HPA (Horizontal Pod Autoscaler) がある。

### 検討した主なオプション

| 観点 | KEDA ScaledObject | HPA + カスタムメトリクスアダプター | 自作スケーリングロジック(本選択) |
|---|---|---|---|
| ポーリング間隔 | 15秒(デフォルト、最短5秒) | 15-30秒(metrics-server制約) | 自由(デフォルト5秒) |
| フォールバック連携 | 不可(CRD外の制御は別途必要) | 不可 | AISのreconcileループに統合可能 |
| scale-to-zero | ネイティブサポート | サポートなし | MinReplicas=0で実現 |
| ヒステリシス | CooldownPeriod/ScaleDown.StabilizationWindowSeconds | stabilizationWindowSeconds | 自前実装(scaleDownThresholdRatio=0.7) |
| Prometheus直接連携 | PrometheusスケーラーCRDで可 | カスタムアダプターが必要 | HTTP API直接呼び出し |
| SQSスケーラー | ネイティブサポート | 不可 | CloudWatch Exporter経由で可 |
| Operator内完結 | 否(別途KEDAのインストール必要) | 否 | 是 |

### なぜKEDAを採用しなかったか

> **⚠️ このDecisionセクションは人間が書く。AI生成禁止。**
>
> (CLAUDE.md Phase 3ルール: "ADRのDecisionセクションは必ず自分で書く")
>
> あなた自身の言葉で、なぜKEDAではなく自作を選んだかを以下に記入すること。
> 面接で語れる価値は「実測した上でのトレードオフの言語化」から生まれる。

```
[ここに自分の言葉でDecisionを記入する]

ヒント:
- 実際にKEDAと比較実験してみて何が分かったか
- ポーリング間隔の差は実際のSLOに影響したか
- フォールバックロジックとの統合で自作が有利だった具体的なシーン
- 自作のデメリット(KEDAに比べてテストが大変、バグリスク等)をどう考えたか
```

---

## Options

### Option A: KEDA ScaledObject

KEDAをクラスタにインストールし、各`AIInferenceService`に対応する`ScaledObject`を自動生成する。

**メリット:**
- 実績ある実装、エッジケースのバグが少ない
- SQSスケーラーがネイティブで存在する
- `spec.cooldownPeriod`でscale-downの安定化が設定できる

**デメリット:**
- ポーリング間隔の最短が約5秒(内部ループ)で設定変更にKEDA自体の再設定が必要
- `AIInferenceService`のBedrockフォールバック判定とスケーリング判定が別CRDに分離し、状態管理が複雑になる
- ScaledObjectのライフサイクルをOperatorが管理する必要があり、ownerReference設計が煩雑

### Option B: HPA + カスタムメトリクスアダプター

`external-metrics-apiserver`を実装してKubernetes HPAからカスタムメトリクスを参照させる。

**メリット:**
- Kubernetes標準のHPA機構を活用できる

**デメリット:**
- metrics-serverの評価間隔(15-30秒)に縛られる
- scale-to-zeroが不可(HPAの最小レプリカ数は1)
- フォールバックロジックとの統合は別途実装が必要

### Option C: Reconcilerに直接実装(採用)

`AIInferenceServiceReconciler`のreconcileループ内でPrometheusのHTTP APIを直接呼び出し、
スケーリング判定・Deployment更新・フォールバック判定を単一のループで管理する。

**メリット:**
- ポーリング間隔を`spec.scalingMetric.pollingIntervalSeconds`で自由に設定できる
- スケーリング判定結果を`status.conditions`に直接記録でき、フォールバック判定と同一コンテキストで処理できる
- KEDAのインストールが不要でクラスタの依存関係が減る

**デメリット:**
- ヒステリシス・クールダウンロジックを自前でテストする必要がある
- KEDAが吸収しているPrometheusのエラーハンドリング(接続断・タイムアウト)を自前実装

---

## Decision

> **ここを自分で書くこと**

---

## Consequences

### 実測比較データ

`docs/benchmarks/scaling-latency.md` に実験結果を記録する。

| コントローラー | ポーリング間隔 | 平均反応時間 | 分散(σ) |
|---|---|---|---|
| 自作(本実装) | 5秒 | TBD | TBD |
| KEDA | 15秒 | TBD | TBD |
| CloudWatch Alarm | 60秒 | TBD | TBD |

### ヒステリシス設計

`scaleDownThresholdRatio = 0.7`を採用。
スケールアップ閾値(targetValue)の70%を下回った場合のみスケールダウンを許可する。
この値の選択根拠は`docs/benchmarks/scaling-latency.md`のflapping観測データを参照のこと。
