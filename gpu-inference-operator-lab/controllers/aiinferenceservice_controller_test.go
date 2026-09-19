package controllers_test

import (
	"testing"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"

	inferencev1alpha1 "github.com/takuya/gpu-inference-operator-lab/api/v1alpha1"
)

const (
	pollInterval = 100 * time.Millisecond
	pollTimeout  = 30 * time.Second
)

// waitUntil はconditionがtrueになるまでpollTimeoutまでポーリングする
func waitUntil(t *testing.T, condition func() bool, msg string) {
	t.Helper()
	deadline := time.Now().Add(pollTimeout)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(pollInterval)
	}
	t.Fatalf("timeout waiting for: %s", msg)
}

func newTestAIS(name, namespace string) *inferencev1alpha1.AIInferenceService {
	return &inferencev1alpha1.AIInferenceService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: namespace,
		},
		Spec: inferencev1alpha1.AIInferenceServiceSpec{
			ModelImage:     "public.ecr.aws/vllm/vllm:v0.5.0",
			GPUNodePoolRef: "karpenter-gpu-g5g",
			MinReplicas:    1,
			MaxReplicas:    4,
			ScalingMetric: inferencev1alpha1.ScalingMetric{
				Type:        inferencev1alpha1.ScalingMetricQueueDepth,
				TargetValue: 10,
			},
		},
	}
}

// TestReconcile_CreatesDeploymentAndService は正常系: Deployment・Serviceが自動生成されることを検証する
func TestReconcile_CreatesDeploymentAndService(t *testing.T) {
	const ns, name = "default", "test-creates-resources"

	ais := newTestAIS(name, ns)
	if err := k8sClient.Create(testCtx, ais); err != nil {
		t.Fatalf("Create AIS: %v", err)
	}
	t.Cleanup(func() { _ = k8sClient.Delete(testCtx, ais) })

	// Deploymentが生成されることを確認する
	deployment := &appsv1.Deployment{}
	waitUntil(t, func() bool {
		err := k8sClient.Get(testCtx, types.NamespacedName{Name: name, Namespace: ns}, deployment)
		return err == nil
	}, "Deployment to be created")

	if deployment.Spec.Template.Spec.Containers[0].Image != ais.Spec.ModelImage {
		t.Errorf("image mismatch: got %q, want %q",
			deployment.Spec.Template.Spec.Containers[0].Image, ais.Spec.ModelImage)
	}
	if *deployment.Spec.Replicas != ais.Spec.MinReplicas {
		t.Errorf("replicas mismatch: got %d, want %d", *deployment.Spec.Replicas, ais.Spec.MinReplicas)
	}

	// OwnerReferenceが設定されていることを確認する
	if len(deployment.OwnerReferences) == 0 {
		t.Error("Deployment has no OwnerReference")
	} else if deployment.OwnerReferences[0].Kind != "AIInferenceService" {
		t.Errorf("unexpected OwnerReference Kind: %s", deployment.OwnerReferences[0].Kind)
	}

	// Serviceが生成されることを確認する
	svc := &corev1.Service{}
	waitUntil(t, func() bool {
		err := k8sClient.Get(testCtx, types.NamespacedName{Name: name, Namespace: ns}, svc)
		return err == nil
	}, "Service to be created")

	if len(svc.OwnerReferences) == 0 {
		t.Error("Service has no OwnerReference")
	}
}

// TestReconcile_FinalizerIsAdded はfinalizerが自動付与されることを検証する
func TestReconcile_FinalizerIsAdded(t *testing.T) {
	const ns, name = "default", "test-finalizer"

	ais := newTestAIS(name, ns)
	if err := k8sClient.Create(testCtx, ais); err != nil {
		t.Fatalf("Create AIS: %v", err)
	}
	t.Cleanup(func() { _ = k8sClient.Delete(testCtx, ais) })

	updated := &inferencev1alpha1.AIInferenceService{}
	waitUntil(t, func() bool {
		if err := k8sClient.Get(testCtx, types.NamespacedName{Name: name, Namespace: ns}, updated); err != nil {
			return false
		}
		for _, f := range updated.Finalizers {
			if f == "inference.takuya.dev/cleanup" {
				return true
			}
		}
		return false
	}, "finalizer inference.takuya.dev/cleanup to be added")
}

// TestReconcile_SpecUpdate_ReflectsToDeployment はSpec変更がDeploymentに反映されることを検証する
func TestReconcile_SpecUpdate_ReflectsToDeployment(t *testing.T) {
	const ns, name = "default", "test-spec-update"

	ais := newTestAIS(name, ns)
	if err := k8sClient.Create(testCtx, ais); err != nil {
		t.Fatalf("Create AIS: %v", err)
	}
	t.Cleanup(func() { _ = k8sClient.Delete(testCtx, ais) })

	// Deploymentが初回作成されるまで待つ
	deployment := &appsv1.Deployment{}
	waitUntil(t, func() bool {
		return k8sClient.Get(testCtx, types.NamespacedName{Name: name, Namespace: ns}, deployment) == nil
	}, "initial Deployment creation")

	// イメージを更新する
	const newImage = "public.ecr.aws/vllm/vllm:v0.6.0"
	if err := k8sClient.Get(testCtx, types.NamespacedName{Name: name, Namespace: ns}, ais); err != nil {
		t.Fatalf("Get AIS for update: %v", err)
	}
	ais.Spec.ModelImage = newImage
	if err := k8sClient.Update(testCtx, ais); err != nil {
		t.Fatalf("Update AIS spec: %v", err)
	}

	// Deploymentのイメージが更新されることを確認する
	waitUntil(t, func() bool {
		d := &appsv1.Deployment{}
		if err := k8sClient.Get(testCtx, types.NamespacedName{Name: name, Namespace: ns}, d); err != nil {
			return false
		}
		return len(d.Spec.Template.Spec.Containers) > 0 &&
			d.Spec.Template.Spec.Containers[0].Image == newImage
	}, "Deployment image to be updated to "+newImage)
}

// TestReconcile_InvalidSpec は不正なSpec(空のModelImage)がCRD validationでrejectされることを検証する
func TestReconcile_InvalidSpec(t *testing.T) {
	const ns, name = "default", "test-invalid-spec"

	ais := &inferencev1alpha1.AIInferenceService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: ns,
		},
		Spec: inferencev1alpha1.AIInferenceServiceSpec{
			ModelImage:     "", // minLength=1 のバリデーションに違反する
			GPUNodePoolRef: "karpenter-gpu-g5g",
			MinReplicas:    0,
			MaxReplicas:    1,
			ScalingMetric: inferencev1alpha1.ScalingMetric{
				Type:        inferencev1alpha1.ScalingMetricQueueDepth,
				TargetValue: 10,
			},
		},
	}

	err := k8sClient.Create(testCtx, ais)
	if err == nil {
		_ = k8sClient.Delete(testCtx, ais)
		t.Fatal("expected validation error for empty ModelImage, but Create succeeded")
	}
	if !apierrors.IsInvalid(err) {
		t.Errorf("expected Invalid error, got: %v", err)
	}
}

// TestReconcile_StatusIsUpdated はReconcile後にstatusが設定されることを検証する
func TestReconcile_StatusIsUpdated(t *testing.T) {
	const ns, name = "default", "test-status-update"

	ais := newTestAIS(name, ns)
	if err := k8sClient.Create(testCtx, ais); err != nil {
		t.Fatalf("Create AIS: %v", err)
	}
	t.Cleanup(func() { _ = k8sClient.Delete(testCtx, ais) })

	// PhaseがProvisioning(GPU Pod未Ready)またはRunningに設定されることを確認する
	// envtestはPodを実際に起動しないためProvisioningになることを期待する
	updated := &inferencev1alpha1.AIInferenceService{}
	waitUntil(t, func() bool {
		if err := k8sClient.Get(testCtx, types.NamespacedName{Name: name, Namespace: ns}, updated); err != nil {
			return false
		}
		return updated.Status.Phase != ""
	}, "status.phase to be set")

	if updated.Status.Phase != inferencev1alpha1.PhaseProvisioning &&
		updated.Status.Phase != inferencev1alpha1.PhaseRunning {
		t.Errorf("unexpected phase: %s", updated.Status.Phase)
	}

	// Conditions が設定されていることを確認する
	if len(updated.Status.Conditions) == 0 {
		t.Error("status.conditions is empty")
	}
}
