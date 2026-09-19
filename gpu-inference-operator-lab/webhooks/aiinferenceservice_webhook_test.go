package webhooks_test

import (
	"context"
	"testing"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	inferencev1alpha1 "github.com/takuya/gpu-inference-operator-lab/api/v1alpha1"
	"github.com/takuya/gpu-inference-operator-lab/webhooks"
)

var wh = &webhooks.AIInferenceServiceWebhook{}
var testCtx = context.Background()

// --- MutatingWebhook (Default) ---

func TestDefault_InjectsPollingInterval(t *testing.T) {
	ais := buildValidAIS()
	ais.Spec.ScalingMetric.PollingIntervalSeconds = 0

	if err := wh.Default(testCtx, ais); err != nil {
		t.Fatalf("Default() error: %v", err)
	}
	if ais.Spec.ScalingMetric.PollingIntervalSeconds != 5 {
		t.Errorf("expected pollingIntervalSeconds=5, got %d", ais.Spec.ScalingMetric.PollingIntervalSeconds)
	}
}

func TestDefault_DoesNotOverrideExistingPollingInterval(t *testing.T) {
	ais := buildValidAIS()
	ais.Spec.ScalingMetric.PollingIntervalSeconds = 15

	if err := wh.Default(testCtx, ais); err != nil {
		t.Fatalf("Default() error: %v", err)
	}
	if ais.Spec.ScalingMetric.PollingIntervalSeconds != 15 {
		t.Errorf("expected pollingIntervalSeconds=15 unchanged, got %d", ais.Spec.ScalingMetric.PollingIntervalSeconds)
	}
}

func TestDefault_InjectsMaxRestartAttempts(t *testing.T) {
	ais := buildValidAIS()
	ais.Spec.SelfHealing = &inferencev1alpha1.SelfHealing{
		RestartOnOOM:       true,
		MaxRestartAttempts: 0,
	}

	if err := wh.Default(testCtx, ais); err != nil {
		t.Fatalf("Default() error: %v", err)
	}
	if ais.Spec.SelfHealing.MaxRestartAttempts != 3 {
		t.Errorf("expected maxRestartAttempts=3 injected, got %d", ais.Spec.SelfHealing.MaxRestartAttempts)
	}
}

func TestDefault_InjectsDefaultGPUResources(t *testing.T) {
	ais := buildValidAIS()
	ais.Spec.Resources = nil

	if err := wh.Default(testCtx, ais); err != nil {
		t.Fatalf("Default() error: %v", err)
	}
	if ais.Spec.Resources == nil {
		t.Fatal("expected Resources to be injected, got nil")
	}
	if _, ok := ais.Spec.Resources.Limits["nvidia.com/gpu"]; !ok {
		t.Error("expected nvidia.com/gpu limit to be injected")
	}
}

func TestDefault_InjectsBedrockFallbackTimeout(t *testing.T) {
	ais := buildValidAIS()
	ais.Spec.BedrockFallback = &inferencev1alpha1.BedrockFallback{
		Enabled:                    true,
		GPUProvisionTimeoutSeconds: 0,
	}

	if err := wh.Default(testCtx, ais); err != nil {
		t.Fatalf("Default() error: %v", err)
	}
	if ais.Spec.BedrockFallback.GPUProvisionTimeoutSeconds != 90 {
		t.Errorf("expected gpuProvisionTimeoutSeconds=90, got %d", ais.Spec.BedrockFallback.GPUProvisionTimeoutSeconds)
	}
}

// --- ValidatingWebhook (Create) ---

func TestValidateCreate_ValidSpec(t *testing.T) {
	ais := buildValidAIS()
	_, err := wh.ValidateCreate(testCtx, ais)
	if err != nil {
		t.Errorf("expected valid spec to pass, got error: %v", err)
	}
}

func TestValidateCreate_MaxReplicasLessThanMin(t *testing.T) {
	ais := buildValidAIS()
	ais.Spec.MaxReplicas = 1
	ais.Spec.MinReplicas = 2

	_, err := wh.ValidateCreate(testCtx, ais)
	if err == nil {
		t.Error("expected error when maxReplicas < minReplicas")
	}
}

func TestValidateCreate_QueueDepthWithoutQueueName(t *testing.T) {
	ais := buildValidAIS()
	ais.Spec.ScalingMetric.Type = inferencev1alpha1.ScalingMetricQueueDepth
	ais.Spec.ScalingMetric.QueueName = ""

	_, err := wh.ValidateCreate(testCtx, ais)
	if err == nil {
		t.Error("expected error when queueDepth type is used without queueName")
	}
}

func TestValidateCreate_GPUNodePoolWithoutGPULimit(t *testing.T) {
	ais := buildValidAIS()
	// GPU limitなしのresourcesを設定
	ais.Spec.Resources = &corev1.ResourceRequirements{
		Limits: corev1.ResourceList{
			corev1.ResourceMemory: resource.MustParse("8Gi"),
			// nvidia.com/gpu がない
		},
	}

	_, err := wh.ValidateCreate(testCtx, ais)
	if err == nil {
		t.Error("expected error when gpuNodePoolRef is set but nvidia.com/gpu limit is missing")
	}
}

func TestValidateCreate_GPUNodePoolWithNilResources(t *testing.T) {
	ais := buildValidAIS()
	ais.Spec.Resources = nil

	_, err := wh.ValidateCreate(testCtx, ais)
	if err == nil {
		t.Error("expected error when gpuNodePoolRef is set but resources is nil")
	}
}

func TestValidateCreate_SelfHealingWithoutMaxAttempts(t *testing.T) {
	ais := buildValidAIS()
	ais.Spec.SelfHealing = &inferencev1alpha1.SelfHealing{
		RestartOnOOM:       true,
		MaxRestartAttempts: 0, // MutatingWebhookが注入するはずだが未注入の場合
	}

	_, err := wh.ValidateCreate(testCtx, ais)
	if err == nil {
		t.Error("expected error when restartOnOOM=true but maxRestartAttempts=0")
	}
}

func TestValidateCreate_LatestTagWarning(t *testing.T) {
	ais := buildValidAIS()
	ais.Spec.ModelImage = "123456789.dkr.ecr.ap-northeast-1.amazonaws.com/vllm:latest"

	warnings, err := wh.ValidateCreate(testCtx, ais)
	if err != nil {
		t.Errorf("expected no error for latest tag (only warning), got: %v", err)
	}
	if len(warnings) == 0 {
		t.Error("expected warning for latest tag")
	}
}

func TestValidateUpdate_Valid(t *testing.T) {
	old := buildValidAIS()
	updated := buildValidAIS()
	updated.Spec.MaxReplicas = 6

	_, err := wh.ValidateUpdate(testCtx, old, updated)
	if err != nil {
		t.Errorf("expected valid update to pass, got error: %v", err)
	}
}

func TestValidateDelete_AlwaysAllowed(t *testing.T) {
	ais := buildValidAIS()
	_, err := wh.ValidateDelete(testCtx, ais)
	if err != nil {
		t.Errorf("expected delete to always be allowed, got error: %v", err)
	}
}

// buildValidAIS はテストに使う合法なAIInferenceServiceを生成するヘルパー
func buildValidAIS() *inferencev1alpha1.AIInferenceService {
	return &inferencev1alpha1.AIInferenceService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "llama-3-8b",
			Namespace: "default",
		},
		Spec: inferencev1alpha1.AIInferenceServiceSpec{
			ModelImage:     "123456789.dkr.ecr.ap-northeast-1.amazonaws.com/vllm:v0.4.0",
			GPUNodePoolRef: "karpenter-gpu-g5g",
			MinReplicas:    1,
			MaxReplicas:    4,
			ScalingMetric: inferencev1alpha1.ScalingMetric{
				Type:                   inferencev1alpha1.ScalingMetricQueueDepth,
				TargetValue:            10,
				QueueName:              "inference-queue",
				PollingIntervalSeconds: 5,
			},
			Resources: &corev1.ResourceRequirements{
				Requests: corev1.ResourceList{
					corev1.ResourceMemory: resource.MustParse("8Gi"),
					corev1.ResourceCPU:    resource.MustParse("2"),
				},
				Limits: corev1.ResourceList{
					corev1.ResourceMemory:                  resource.MustParse("8Gi"),
					corev1.ResourceName("nvidia.com/gpu"): resource.MustParse("1"),
				},
			},
		},
	}
}
