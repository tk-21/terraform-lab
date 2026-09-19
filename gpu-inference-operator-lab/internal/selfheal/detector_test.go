package selfheal_test

import (
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	inferencev1alpha1 "github.com/takuya/gpu-inference-operator-lab/api/v1alpha1"
	"github.com/takuya/gpu-inference-operator-lab/internal/selfheal"
)

func TestInspectPods_NoFailure(t *testing.T) {
	pods := []corev1.Pod{
		{
			ObjectMeta: metav1.ObjectMeta{Name: "vllm-abc"},
			Status: corev1.PodStatus{
				ContainerStatuses: []corev1.ContainerStatus{
					{
						Name:  "vllm",
						Ready: true,
						State: corev1.ContainerState{
							Running: &corev1.ContainerStateRunning{},
						},
					},
				},
			},
		},
	}
	health := selfheal.InspectPods(pods)
	if health.FailureMode != selfheal.FailureNone {
		t.Errorf("expected no failure, got %s", health.FailureMode)
	}
}

func TestInspectPods_OOMKilledCurrent(t *testing.T) {
	pods := []corev1.Pod{
		{
			ObjectMeta: metav1.ObjectMeta{Name: "vllm-oom"},
			Status: corev1.PodStatus{
				ContainerStatuses: []corev1.ContainerStatus{
					{
						Name:         "vllm",
						RestartCount: 2,
						State: corev1.ContainerState{
							Terminated: &corev1.ContainerStateTerminated{
								Reason:  "OOMKilled",
								Message: "memory limit exceeded",
							},
						},
					},
				},
			},
		},
	}
	health := selfheal.InspectPods(pods)
	if health.FailureMode != selfheal.FailureOOMKilled {
		t.Errorf("expected OOMKilled, got %s", health.FailureMode)
	}
	if health.PodName != "vllm-oom" {
		t.Errorf("expected pod name vllm-oom, got %s", health.PodName)
	}
	if health.CurrentRestartCount != 2 {
		t.Errorf("expected restartCount=2, got %d", health.CurrentRestartCount)
	}
}

func TestInspectPods_OOMKilledLastTermination(t *testing.T) {
	// 直前の実行でOOMKilledになったコンテナ(現在はBackoff中)
	pods := []corev1.Pod{
		{
			ObjectMeta: metav1.ObjectMeta{Name: "vllm-crash"},
			Status: corev1.PodStatus{
				ContainerStatuses: []corev1.ContainerStatus{
					{
						Name:         "vllm",
						RestartCount: 1,
						State: corev1.ContainerState{
							Waiting: &corev1.ContainerStateWaiting{Reason: "CrashLoopBackOff"},
						},
						LastTerminationState: corev1.ContainerState{
							Terminated: &corev1.ContainerStateTerminated{
								Reason:  "OOMKilled",
								Message: "OOM in previous run",
							},
						},
					},
				},
			},
		},
	}
	health := selfheal.InspectPods(pods)
	// LastTerminationがOOMKilledのためCrashLoopより優先してOOMKilledを返す
	if health.FailureMode != selfheal.FailureOOMKilled {
		t.Errorf("expected OOMKilled from last termination, got %s", health.FailureMode)
	}
}

func TestInspectPods_CrashLoopBackOff(t *testing.T) {
	pods := []corev1.Pod{
		{
			ObjectMeta: metav1.ObjectMeta{Name: "vllm-crash"},
			Status: corev1.PodStatus{
				ContainerStatuses: []corev1.ContainerStatus{
					{
						Name:         "vllm",
						RestartCount: 5,
						State: corev1.ContainerState{
							Waiting: &corev1.ContainerStateWaiting{
								Reason:  "CrashLoopBackOff",
								Message: "back-off 5m0s restarting",
							},
						},
						LastTerminationState: corev1.ContainerState{
							Terminated: &corev1.ContainerStateTerminated{
								Reason:  "Error",
								Message: "panic: runtime error",
							},
						},
					},
				},
			},
		},
	}
	health := selfheal.InspectPods(pods)
	if health.FailureMode != selfheal.FailureCrashLoop {
		t.Errorf("expected CrashLoopBackOff, got %s", health.FailureMode)
	}
	if health.LastTerminationMessage != "panic: runtime error" {
		t.Errorf("expected termination message from last state, got %q", health.LastTerminationMessage)
	}
}

func TestEvaluate_NoFailure(t *testing.T) {
	ais := buildAIS(true, 3, 0)
	d := selfheal.NewDetector()
	dec := d.Evaluate(ais, selfheal.PodHealth{FailureMode: selfheal.FailureNone})
	if dec.ShouldDegrade || dec.ShouldBumpMemory || dec.ShouldRecordEvent {
		t.Errorf("expected no-op decision, got %+v", dec)
	}
}

func TestEvaluate_OOMKilledBumpsMemory(t *testing.T) {
	ais := buildAIS(true, 3, 0)
	d := selfheal.NewDetector()
	dec := d.Evaluate(ais, selfheal.PodHealth{
		FailureMode: selfheal.FailureOOMKilled,
		PodName:     "vllm-oom",
	})
	if !dec.ShouldBumpMemory {
		t.Error("expected ShouldBumpMemory=true for OOMKilled")
	}
	if dec.ShouldDegrade {
		t.Error("expected ShouldDegrade=false when within maxRestartAttempts")
	}
}

func TestEvaluate_CrashLoopRecordsEvent(t *testing.T) {
	ais := buildAIS(true, 3, 0)
	d := selfheal.NewDetector()
	dec := d.Evaluate(ais, selfheal.PodHealth{
		FailureMode: selfheal.FailureCrashLoop,
		PodName:     "vllm-crash",
	})
	if !dec.ShouldRecordEvent {
		t.Error("expected ShouldRecordEvent=true for CrashLoopBackOff")
	}
	if dec.ShouldBumpMemory {
		t.Error("CrashLoop should not trigger memory bump")
	}
}

func TestEvaluate_MaxAttemptsExceededDegrade(t *testing.T) {
	// RestartCount=3, maxRestartAttempts=3 → Degradedに遷移するべき
	ais := buildAIS(true, 3, 3)
	d := selfheal.NewDetector()
	dec := d.Evaluate(ais, selfheal.PodHealth{
		FailureMode: selfheal.FailureOOMKilled,
		PodName:     "vllm-oom",
	})
	if !dec.ShouldDegrade {
		t.Error("expected ShouldDegrade=true when RestartCount >= maxRestartAttempts")
	}
	if dec.ShouldBumpMemory {
		t.Error("should not bump memory when degrading")
	}
}

func TestEvaluate_SelfHealingDisabled_RecordsEventOnly(t *testing.T) {
	// restartOnOOM=false でもEventは記録する
	ais := buildAIS(false, 3, 0)
	d := selfheal.NewDetector()
	dec := d.Evaluate(ais, selfheal.PodHealth{
		FailureMode: selfheal.FailureOOMKilled,
		PodName:     "vllm-oom",
	})
	if dec.ShouldBumpMemory {
		t.Error("should not bump memory when restartOnOOM=false")
	}
	if dec.ShouldDegrade {
		t.Error("should not degrade when selfHealing is disabled")
	}
	if !dec.ShouldRecordEvent {
		t.Error("expected ShouldRecordEvent=true even when selfHealing is disabled")
	}
}

func TestEvaluate_DefaultMaxRestartAttempts(t *testing.T) {
	// MaxRestartAttempts=0 → DefaultMaxRestartAttempts(3)が使われるべき
	ais := buildAIS(true, 0, 2)
	d := selfheal.NewDetector()
	dec := d.Evaluate(ais, selfheal.PodHealth{
		FailureMode: selfheal.FailureOOMKilled,
		PodName:     "vllm-oom",
	})
	// RestartCount=2 < default(3) なのでまだ修復を試みる
	if !dec.ShouldBumpMemory {
		t.Error("expected ShouldBumpMemory=true when still within default max attempts")
	}
}

// buildAIS はテスト用のAIInferenceServiceを生成するヘルパー
func buildAIS(restartOnOOM bool, maxAttempts, currentRestartCount int32) *inferencev1alpha1.AIInferenceService {
	ais := &inferencev1alpha1.AIInferenceService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "llama-3-8b",
			Namespace: "default",
		},
		Spec: inferencev1alpha1.AIInferenceServiceSpec{
			ModelImage:     "ecr.aws/vllm:latest",
			GPUNodePoolRef: "karpenter-gpu-g5g",
			MinReplicas:    1,
			MaxReplicas:    4,
			ScalingMetric: inferencev1alpha1.ScalingMetric{
				Type:        inferencev1alpha1.ScalingMetricQueueDepth,
				TargetValue: 10,
			},
			SelfHealing: &inferencev1alpha1.SelfHealing{
				RestartOnOOM:       restartOnOOM,
				MaxRestartAttempts: maxAttempts,
			},
		},
		Status: inferencev1alpha1.AIInferenceServiceStatus{
			RestartCount: currentRestartCount,
		},
	}
	return ais
}
