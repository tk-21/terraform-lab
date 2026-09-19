package scaling

import (
	"math"

	inferencev1alpha1 "github.com/takuya/gpu-inference-operator-lab/api/v1alpha1"
)

const (
	// defaultPollingIntervalSeconds はPrometheusポーリングのデフォルト間隔
	// KEDAの15秒より短い5秒を基準にして反応速度比較の優位性を測定する
	DefaultPollingIntervalSeconds = 5

	// scaleDownThresholdRatio はスケールダウン判定の閾値係数(ヒステリシス)
	// targetValueの70%を下回った場合にのみスケールダウンを許可する。
	// 閾値ピッタリでのflapping(スケールアップ→ダウン→アップの繰り返し)を防ぐためで、
	// Prometheus alerting rulesが`for:`句で評価を安定させる発想と同じ。
	scaleDownThresholdRatio = 0.7
)

// ScalingDecision はスケーリング判定の結果を保持する
type ScalingDecision struct {
	// DesiredReplicas は計算された目標レプリカ数
	DesiredReplicas int32
	// CurrentMetric は判定に使用したメトリクスの実測値
	CurrentMetric float64
	// Reason は判定結果の理由(ログ・Eventに記録する)
	Reason string
	// ScaleChanged は前回から変化があったかどうか
	ScaleChanged bool
}

// CalculateDesiredReplicas はメトリクス実測値とSpec設定から目標レプリカ数を計算する
//
// スケーリングロジックの設計判断:
//  1. スケールアップ: ceil(currentMetric / targetValue)でレプリカ数を算出
//     例: GPU使用率=80%, targetValue=40 → ceil(80/40)=2レプリカ必要
//
//  2. スケールダウン(ヒステリシス): currentReplicasを1つ減らしたときの
//     予測負荷がscaleDownThresholdRatio(70%)を超える場合はダウンを見送る
//     例: 3台で使用率=75%, target=40 → 2台なら112.5%になるのでダウン抑制
//
//  3. scale-to-zero: metricValue=0のとき、MinReplicasが0であればゼロスケールを許可
//     KarpenterのConsolidationがGPUノードを自動的にdecommissionする
func CalculateDesiredReplicas(
	spec inferencev1alpha1.AIInferenceServiceSpec,
	currentReplicas int32,
	metricValue float64,
) ScalingDecision {
	target := float64(spec.ScalingMetric.TargetValue)
	minReplicas := spec.MinReplicas
	maxReplicas := spec.MaxReplicas

	if metricValue <= 0 {
		// 負荷ゼロ → MinReplicasまでスケールダウン(0ならscale-to-zero)
		desired := minReplicas
		return ScalingDecision{
			DesiredReplicas: desired,
			CurrentMetric:   metricValue,
			Reason:          "no load detected, scaling to minimum replicas",
			ScaleChanged:    currentReplicas != desired,
		}
	}

	// 必要レプリカ数の算出: 小数を切り上げてSLOを満たす最小台数を保証する
	rawDesired := math.Ceil(metricValue / target)
	desired := int32(rawDesired)

	// スケールダウン時のヒステリシス適用
	// 現在台数を1減らしたときの予測負荷を計算し、70%を超えるなら見送る
	if desired < currentReplicas && currentReplicas > 1 {
		projectedMetricPerReplica := metricValue / float64(currentReplicas)
		projectedWithOneLess := projectedMetricPerReplica * float64(currentReplicas-1)
		if projectedWithOneLess > target*scaleDownThresholdRatio {
			return ScalingDecision{
				DesiredReplicas: currentReplicas,
				CurrentMetric:   metricValue,
				Reason:          "hysteresis: scale-down suppressed to prevent flapping",
				ScaleChanged:    false,
			}
		}
	}

	// min/maxの範囲内にクランプする
	if desired < minReplicas {
		desired = minReplicas
	}
	if desired > maxReplicas {
		desired = maxReplicas
	}

	return ScalingDecision{
		DesiredReplicas: desired,
		CurrentMetric:   metricValue,
		Reason:          "proportional scaling",
		ScaleChanged:    currentReplicas != desired,
	}
}

// PollingInterval はAISのSpecから有効なポーリング間隔を取得する
// 未指定(0)の場合はデフォルト5秒を返す
func PollingInterval(spec inferencev1alpha1.AIInferenceServiceSpec) int32 {
	if spec.ScalingMetric.PollingIntervalSeconds > 0 {
		return spec.ScalingMetric.PollingIntervalSeconds
	}
	return DefaultPollingIntervalSeconds
}
