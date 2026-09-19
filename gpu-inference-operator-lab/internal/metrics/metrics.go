// Package metrics はOperator自体の健全性を計測するカスタムPrometheusメトリクスを定義する。
//
// 「ワークロードの観測(DCGM Exporter等)」と「Operator自体の観測」を分離する理由:
// DCGM ExporterはGPU使用率・温度などインフラ層を見るが、Operatorが正しく動いているか
// (reconcileが遅延していないか、フォールバックが何回起きているか)は別の観点であり、
// Operator自身が公開しなければ外部から把握する手段がない。
package metrics

import (
	"github.com/prometheus/client_golang/prometheus"
	"sigs.k8s.io/controller-runtime/pkg/metrics"
)

// ReconcileDuration はreconcile 1回あたりの所要時間を計測する。
// Histogramを選ぶ理由: 平均値だけでなくp50/p95/p99分布を見ることで
// 「ほとんどは速いが一部が極端に遅い」スパイクを検知できるため。
var ReconcileDuration = prometheus.NewHistogramVec(
	prometheus.HistogramOpts{
		Namespace: "gpu_inference_operator",
		Name:      "reconcile_duration_seconds",
		Help:      "reconcileループ1回あたりの処理時間(秒)",
		// 5ms〜30sのレンジ: 通常は<1s、Kubernetes API呼び出し遅延でも<10sが期待値
		Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30},
	},
	[]string{"namespace", "name", "phase"},
)

// ReconcileErrors はreconcileエラーの発生回数をエラー種別で計測する。
// labelの"reason"にはエラーの種別(DeploymentFailed/StatusUpdateFailed等)を入れ、
// ダッシュボードで「どのフェーズで詰まっているか」を一目で分かるようにする。
var ReconcileErrors = prometheus.NewCounterVec(
	prometheus.CounterOpts{
		Namespace: "gpu_inference_operator",
		Name:      "reconcile_errors_total",
		Help:      "reconcileエラーの累計発生回数(エラー種別ラベル付き)",
	},
	[]string{"namespace", "name", "reason"},
)

// SelfHealActions は自己修復アクションの発動回数をアクション種別で計測する。
// "action"ラベルの値: memory_bump / crash_loop_detected / degraded
// memory_bumpが急増 → OOM設定が不適切
// degradedが増加 → 人間介入が必要なCRが溜まっている
var SelfHealActions = prometheus.NewCounterVec(
	prometheus.CounterOpts{
		Namespace: "gpu_inference_operator",
		Name:      "selfheal_actions_total",
		Help:      "自己修復アクションの累計発生回数",
	},
	[]string{"namespace", "name", "action"},
)

// BedrockFallbackTotal はBedrockフォールバックの切替回数を計測する。
// "direction"ラベル: to_bedrock(GPUタイムアウト→Bedrock) / to_gpu(Bedrock→GPU回復)
// to_bedrockが頻発する時間帯 → Karpenterプロビジョニングが遅い問題の可能性
var BedrockFallbackTotal = prometheus.NewCounterVec(
	prometheus.CounterOpts{
		Namespace: "gpu_inference_operator",
		Name:      "bedrock_fallback_total",
		Help:      "Bedrockフォールバック切替の累計回数",
	},
	[]string{"namespace", "name", "direction"},
)

// BedrockFallbackDuration はBedrockフォールバックが継続した時間を計測する。
// GPU回復時(to_gpu)のタイミングで、フォールバック開始からの経過時間を記録する。
// SLO: フォールバック継続時間の中央値が90s以下を目安とする。
var BedrockFallbackDuration = prometheus.NewHistogramVec(
	prometheus.HistogramOpts{
		Namespace: "gpu_inference_operator",
		Name:      "bedrock_fallback_duration_seconds",
		Help:      "Bedrockフォールバックが継続した時間(秒) - GPU回復時に記録",
		// 30s〜30min: GPUコールドスタートは通常3-5分、ノードが来なければ15分超えも
		Buckets: []float64{30, 60, 90, 120, 180, 300, 600, 900, 1800},
	},
	[]string{"namespace", "name"},
)

// init はcontroller-runtimeのPrometheus registryにカスタムメトリクスを登録する。
// init()で登録する理由: main()より前に確実に実行され、
// メトリクス登録前にReconcileが呼ばれる競合状態を防ぐ。
func init() {
	metrics.Registry.MustRegister(
		ReconcileDuration,
		ReconcileErrors,
		SelfHealActions,
		BedrockFallbackTotal,
		BedrockFallbackDuration,
	)
}
