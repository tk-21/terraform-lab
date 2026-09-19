package fallback_test

import (
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	inferencev1alpha1 "github.com/takuya/gpu-inference-operator-lab/api/v1alpha1"
	"github.com/takuya/gpu-inference-operator-lab/internal/fallback"
)

func makeAIS(annotations map[string]string, cfg *inferencev1alpha1.BedrockFallback, backend inferencev1alpha1.ActiveBackend) *inferencev1alpha1.AIInferenceService {
	return &inferencev1alpha1.AIInferenceService{
		ObjectMeta: metav1.ObjectMeta{
			Name:        "test-ais",
			Namespace:   "default",
			Annotations: annotations,
		},
		Spec: inferencev1alpha1.AIInferenceServiceSpec{
			BedrockFallback: cfg,
		},
		Status: inferencev1alpha1.AIInferenceServiceStatus{
			ActiveBackend: backend,
		},
	}
}

func TestEvaluate_FallbackDisabled(t *testing.T) {
	d := fallback.NewDetector()
	ais := makeAIS(nil, nil, inferencev1alpha1.BackendGPU)

	result := d.Evaluate(ais, 0)

	if result.ShouldFallback || result.NeedsAnnotation {
		t.Errorf("expected no action when fallback is disabled, got: %+v", result)
	}
}

func TestEvaluate_FallbackEnabledButGPURunning(t *testing.T) {
	d := fallback.NewDetector()
	ais := makeAIS(nil, &inferencev1alpha1.BedrockFallback{
		Enabled:                    true,
		GPUProvisionTimeoutSeconds: 90,
	}, inferencev1alpha1.BackendGPU)

	result := d.Evaluate(ais, 2)

	if result.ShouldFallback || result.ShouldRecover || result.NeedsAnnotation {
		t.Errorf("expected no action when GPU is running normally, got: %+v", result)
	}
}

func TestEvaluate_FirstProvisioningCycle_SetsAnnotation(t *testing.T) {
	d := fallback.NewDetector()
	ais := makeAIS(nil, &inferencev1alpha1.BedrockFallback{
		Enabled:                    true,
		GPUProvisionTimeoutSeconds: 90,
	}, inferencev1alpha1.BackendGPU)

	result := d.Evaluate(ais, 0)

	if !result.NeedsAnnotation {
		t.Error("expected NeedsAnnotation=true on first provisioning cycle")
	}
	if result.ShouldFallback {
		t.Error("expected no fallback on first cycle (timeout not yet reached)")
	}
}

func TestEvaluate_TimeoutNotYetReached(t *testing.T) {
	d := fallback.NewDetector()
	// 30秒前に記録されたアノテーション (タイムアウト90秒には達していない)
	recentStart := time.Now().Add(-30 * time.Second).UTC().Format(time.RFC3339)
	ais := makeAIS(
		map[string]string{fallback.AnnotationProvisioningStart: recentStart},
		&inferencev1alpha1.BedrockFallback{Enabled: true, GPUProvisionTimeoutSeconds: 90},
		inferencev1alpha1.BackendGPU,
	)

	result := d.Evaluate(ais, 0)

	if result.ShouldFallback {
		t.Errorf("expected no fallback before timeout, got reason: %s", result.Reason)
	}
	if result.ProvisioningElapsed < 29*time.Second || result.ProvisioningElapsed > 35*time.Second {
		t.Errorf("unexpected elapsed time: %s", result.ProvisioningElapsed)
	}
}

func TestEvaluate_TimeoutExceeded_TriggersFallback(t *testing.T) {
	d := fallback.NewDetector()
	// 120秒前に記録されたアノテーション (タイムアウト90秒を超過)
	oldStart := time.Now().Add(-120 * time.Second).UTC().Format(time.RFC3339)
	ais := makeAIS(
		map[string]string{fallback.AnnotationProvisioningStart: oldStart},
		&inferencev1alpha1.BedrockFallback{Enabled: true, GPUProvisionTimeoutSeconds: 90},
		inferencev1alpha1.BackendGPU,
	)

	result := d.Evaluate(ais, 0)

	if !result.ShouldFallback {
		t.Errorf("expected fallback to trigger after timeout, got reason: %s", result.Reason)
	}
	if result.ProvisioningElapsed < 90*time.Second {
		t.Errorf("elapsed time should be >= 90s, got %s", result.ProvisioningElapsed)
	}
}

func TestEvaluate_GPURecoveredDuringFallback_ShouldRecover(t *testing.T) {
	d := fallback.NewDetector()
	oldStart := time.Now().Add(-200 * time.Second).UTC().Format(time.RFC3339)
	ais := makeAIS(
		map[string]string{fallback.AnnotationProvisioningStart: oldStart},
		&inferencev1alpha1.BedrockFallback{Enabled: true, GPUProvisionTimeoutSeconds: 90},
		// Bedrockフォールバック中にGPUが復帰した状態
		inferencev1alpha1.BackendBedrock,
	)

	result := d.Evaluate(ais, 1)

	if !result.ShouldRecover {
		t.Errorf("expected recovery when GPU ready after fallback, got: %+v", result)
	}
	if !result.ClearAnnotation {
		t.Error("expected ClearAnnotation=true on recovery")
	}
}

func TestEvaluate_MalformedAnnotation_Resets(t *testing.T) {
	d := fallback.NewDetector()
	ais := makeAIS(
		map[string]string{fallback.AnnotationProvisioningStart: "not-a-valid-time"},
		&inferencev1alpha1.BedrockFallback{Enabled: true, GPUProvisionTimeoutSeconds: 90},
		inferencev1alpha1.BackendGPU,
	)

	result := d.Evaluate(ais, 0)

	// 壊れたアノテーションはリセットして再計測
	if !result.NeedsAnnotation || !result.ClearAnnotation {
		t.Errorf("expected reset on malformed annotation, got: %+v", result)
	}
	if result.ShouldFallback {
		t.Error("should not trigger fallback on malformed annotation")
	}
}

func TestEvaluate_DefaultTimeout_Applied(t *testing.T) {
	d := fallback.NewDetector()
	// GPUProvisionTimeoutSeconds=0 → DefaultGPUProvisionTimeout(90秒)が使われる
	oldStart := time.Now().Add(-100 * time.Second).UTC().Format(time.RFC3339)
	ais := makeAIS(
		map[string]string{fallback.AnnotationProvisioningStart: oldStart},
		&inferencev1alpha1.BedrockFallback{Enabled: true, GPUProvisionTimeoutSeconds: 0},
		inferencev1alpha1.BackendGPU,
	)

	result := d.Evaluate(ais, 0)

	if !result.ShouldFallback {
		t.Errorf("expected fallback with default 90s timeout after 100s, got: %s", result.Reason)
	}
}
