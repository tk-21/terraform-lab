package scaling_test

import (
	"testing"

	inferencev1alpha1 "github.com/takuya/gpu-inference-operator-lab/api/v1alpha1"
	"github.com/takuya/gpu-inference-operator-lab/internal/scaling"
)

func makeSpec(minReplicas, maxReplicas, targetValue int32) inferencev1alpha1.AIInferenceServiceSpec {
	return inferencev1alpha1.AIInferenceServiceSpec{
		ModelImage:     "test-image",
		GPUNodePoolRef: "test-pool",
		MinReplicas:    minReplicas,
		MaxReplicas:    maxReplicas,
		ScalingMetric: inferencev1alpha1.ScalingMetric{
			Type:        inferencev1alpha1.ScalingMetricGPUUtilization,
			TargetValue: targetValue,
		},
	}
}

// TestCalculate_ScaleUp はメトリクスがtargetを超えた場合にスケールアップすることを検証する
func TestCalculate_ScaleUp(t *testing.T) {
	spec := makeSpec(0, 4, 40)
	// GPU使用率=80%, target=40 → 2レプリカ必要
	decision := scaling.CalculateDesiredReplicas(spec, 1, 80.0)

	if decision.DesiredReplicas != 2 {
		t.Errorf("expected 2 replicas, got %d", decision.DesiredReplicas)
	}
	if !decision.ScaleChanged {
		t.Error("expected ScaleChanged=true")
	}
}

// TestCalculate_ScaleToZero はメトリクスがゼロのときscale-to-zeroになることを検証する
func TestCalculate_ScaleToZero(t *testing.T) {
	spec := makeSpec(0, 4, 40)
	decision := scaling.CalculateDesiredReplicas(spec, 2, 0.0)

	if decision.DesiredReplicas != 0 {
		t.Errorf("expected 0 replicas (scale-to-zero), got %d", decision.DesiredReplicas)
	}
	if !decision.ScaleChanged {
		t.Error("expected ScaleChanged=true")
	}
}

// TestCalculate_MinReplicasFloor はMinReplicas=1の場合にゼロスケールしないことを検証する
func TestCalculate_MinReplicasFloor(t *testing.T) {
	spec := makeSpec(1, 4, 40)
	decision := scaling.CalculateDesiredReplicas(spec, 2, 0.0)

	if decision.DesiredReplicas != 1 {
		t.Errorf("expected 1 replica (minReplicas floor), got %d", decision.DesiredReplicas)
	}
}

// TestCalculate_MaxReplicasCap はMaxReplicasを超えないことを検証する
func TestCalculate_MaxReplicasCap(t *testing.T) {
	spec := makeSpec(0, 3, 10)
	// GPU使用率=100%, target=10 → 10レプリカ必要だがMaxは3
	decision := scaling.CalculateDesiredReplicas(spec, 1, 100.0)

	if decision.DesiredReplicas != 3 {
		t.Errorf("expected 3 replicas (maxReplicas cap), got %d", decision.DesiredReplicas)
	}
}

// TestCalculate_HysteresisSupressesScaleDown はスケールダウンが抑制されることを検証する
//
// ヒステリシスの動作確認:
//   3台で使用率=75%, target=40 → 計算上は2台(ceil(75/40)=2)だが
//   2台に減らすと1台あたり37.5%→2台で75%: target*0.7=28を超えるためダウン抑制
func TestCalculate_HysteresisSupressesScaleDown(t *testing.T) {
	spec := makeSpec(0, 4, 40)
	// 3台で75%使用 → 2台にすると1台あたり37.5%→2台=75% > 28(=40*0.7) → 抑制
	decision := scaling.CalculateDesiredReplicas(spec, 3, 75.0)

	if decision.DesiredReplicas != 3 {
		t.Errorf("expected hysteresis to hold at 3, got %d", decision.DesiredReplicas)
	}
	if decision.ScaleChanged {
		t.Error("expected ScaleChanged=false (hysteresis)")
	}
}

// TestCalculate_HysteresisAllowsScaleDown は十分に負荷が下がった場合にスケールダウンを許可することを検証する
func TestCalculate_HysteresisAllowsScaleDown(t *testing.T) {
	spec := makeSpec(0, 4, 40)
	// 3台で20%使用 → ceil(20/40)=1台, 2台に減らすと30% > 28(=40*0.7)なので2→1のチェックが必要
	// 実際に1台の予測: 20/3*2=13.3% < 28 → スケールダウン許可
	decision := scaling.CalculateDesiredReplicas(spec, 3, 20.0)

	if decision.DesiredReplicas >= 3 {
		t.Errorf("expected scale down from 3, got %d", decision.DesiredReplicas)
	}
}

// TestCalculate_NoChangeWhenStable は安定状態でScaleChangedがfalseになることを検証する
func TestCalculate_NoChangeWhenStable(t *testing.T) {
	spec := makeSpec(1, 4, 40)
	// 2台でGPU使用率=60%, target=40 → ceil(60/40)=2 → 変化なし
	decision := scaling.CalculateDesiredReplicas(spec, 2, 60.0)

	if decision.DesiredReplicas != 2 {
		t.Errorf("expected stable at 2, got %d", decision.DesiredReplicas)
	}
	if decision.ScaleChanged {
		t.Error("expected ScaleChanged=false for stable state")
	}
}

// TestPollingInterval_Default はPollingIntervalSeconds未設定時にデフォルト5秒を返すことを検証する
func TestPollingInterval_Default(t *testing.T) {
	spec := makeSpec(1, 4, 40)
	interval := scaling.PollingInterval(spec)
	if interval != scaling.DefaultPollingIntervalSeconds {
		t.Errorf("expected default %d seconds, got %d", scaling.DefaultPollingIntervalSeconds, interval)
	}
}

// TestPollingInterval_Custom はSpecで指定した値が使われることを検証する
func TestPollingInterval_Custom(t *testing.T) {
	spec := makeSpec(1, 4, 40)
	spec.ScalingMetric.PollingIntervalSeconds = 15 // KEDAと同等にして比較実験
	interval := scaling.PollingInterval(spec)
	if interval != 15 {
		t.Errorf("expected 15 seconds, got %d", interval)
	}
}
