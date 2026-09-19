# ADR-0006: Operator自体のオブザーバビリティ設計

## Status

Accepted (Phase 6)

## Context

Phase 5までに実装したOperatorは「ワークロードを管理する機能」は完成しているが、
**Operator自体が正常に動いているかを外から確認する手段がなかった**。

具体的な問題:
- reconcileループが詰まっていても気づけない(ログを手動で見るまで分からない)
- フォールバックが何回/どの時間帯に発動しているか集計できない
- OOMKillによるmemory bumpが繰り返されていても、累積回数が見えない
- アラートがなく、運用者はダッシュボードを常時監視する必要がある

Phase 6での設計上の問いは「何をメトリクスとして公開すべきか、何を捨てるか」だった。

## Options

### Option A: controller-runtimeのデフォルトメトリクスのみ使う
- `controller-runtime`はすでに`controller_runtime_reconcile_total`等を公開している
- カスタムメトリクスの実装コストがゼロ
- **問題**: reconcile_errors_totalのreasonラベルがない。selfheal/fallbackの計測は不可能。
  Operator固有の挙動(フォールバック継続時間、memory bump回数)は汎用フレームワークでは観測できない。

### Option B: 全ての内部状態をメトリクス化する
- selfheal detector内、fallback detector内、webhook内、全てにメトリクスを埋め込む
- **問題**: Detector層はKubernetes APIを呼ばない純粋関数として設計されており、
  Prometheusレジストリ(グローバル状態)への依存を持ち込むと、
  ユニットテストの並列実行時にメトリクス重複登録でパニックが起きる。

### Option C (採用): Controller層でのみメトリクスを記録する
- `internal/metrics/metrics.go`でメトリクスを定義・登録
- Detector(純粋関数)は変更せず、Controllerがその判定結果を受け取った後にメトリクスを記録する
- init()でcontroller-runtimeのRegistryに登録することで起動前に確実に初期化される

## Decision

**(ここはtakuyaが自分の言葉で書く)**

## What We Chose to Measure (and Why)

以下の4カテゴリを選択した。**選ばなかったもの**に関する説明も含める。

### 選んだメトリクス

| メトリクス | 種別 | なぜ最優先か |
|---|---|---|
| `reconcile_duration_seconds` | Histogram | p95/p99の分布でスパイクを検知。平均値では見えない問題を可視化 |
| `reconcile_errors_total{reason}` | Counter | どのフェーズで詰まっているか即座に分かる。reasonラベルで原因を絞り込む |
| `selfheal_actions_total{action}` | Counter | memory_bumpの頻度でOOM設定の不備を早期発見。degradedは人間介入が必要なシグナル |
| `bedrock_fallback_total{direction}` | Counter | フォールバック発動・回復の頻度でKarpenterの性能を定量評価 |
| `bedrock_fallback_duration_seconds` | Histogram | SLO: p50 < 90sを目標とした継続時間の分布。コスト分析にも使える |

### 選ばなかったメトリクス(とその理由)

- **Webhook validation latency**: Admission Webhookのレイテンシはkube-apiserverが
  既に`apiserver_admission_webhook_admission_duration_seconds`として公開しており重複になる
- **Deployment ready replicas gauge**: `kube_deployment_status_replicas_ready`として
  kube-state-metricsが公開しており、Operator側で再実装する必要がない
- **Prometheus metrics fetch latency**: scaling層の内部実装詳細。
  メトリクス取得失敗は`reconcile_errors_total{reason=MetricsFetchFailed}`として捕捉できる
- **Memory bump後の新しいlimit値**: 時系列メトリクスより`kubectl describe`で見る方が適切

## Alert Threshold Design

### reconcileエラー率 > 0.1件/秒 (5分間)
ポーリング間隔5sで300秒あたり60reconcileのうち6件以上エラーがある状態。
一過性のネットワーク揺れでは到達しないはずの閾値なので、誤検知を抑えられる。

### Degraded発生 (for: 0m)
待機時間なしで即アラート。Degradedは自動修復を諦めた状態であり、
「評価期間待ち」を置く意味がない。

### フォールバック発動 (for: 0m)
SLO観点でGPUが使えない状態であり即通知が必要。一方で「フォールバック後のアラート連発」を
防ぐためrepeat_intervalを4時間に設定した。

## Consequences

- Operator再起動でカウンターはリセットされる。Counterベースのアラートは
  `increase()`や`rate()`を使うため、再起動後しばらくはエラー率が低く見える可能性がある。
  これは許容範囲と判断した(再起動直後は復旧フェーズであり、アラートより落ち着きを優先)。
- Detector層(純粋関数)のテストにPrometheusレジストリが混入しないため、
  並列テストの安定性を維持できる。
