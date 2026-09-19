package e2e_test

import (
	"context"
	"testing"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/wait"
	"sigs.k8s.io/controller-runtime/pkg/client"

	inferencev1alpha1 "github.com/takuya/gpu-inference-operator-lab/api/v1alpha1"
)

const (
	testNamespace = "default"
	pollInterval  = 2 * time.Second
)

// TestAIInferenceServiceBasicReconcile は最も基本的なreconcileループを検証する。
// CRを作成してOperatorがDeploymentを生成するまでの一連の動作を確認する。
// GPU依存部分(vLLMの実際の起動・Karpenter GPUノード)はモック化しているため、
// DeploymentのPodがRunningになることはCI上では確認しない。
func TestAIInferenceServiceBasicReconcile(t *testing.T) {
	ctx, cancel := context.WithTimeout(testCtx, testTimeout)
	defer cancel()

	svcName := "e2e-test-llm"

	// テスト後のクリーンアップ
	t.Cleanup(func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cleanupCancel()
		_ = k8sClient.Delete(cleanupCtx, &inferencev1alpha1.AIInferenceService{
			ObjectMeta: metav1.ObjectMeta{
				Name:      svcName,
				Namespace: testNamespace,
			},
		})
	})

	// GPU依存テスト(Karpenter NodePool, vLLM起動)をスキップするために
	// BedrockFallback.Enabled=false, ScalingMetric.PrometheusURL=""とする
	svc := &inferencev1alpha1.AIInferenceService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      svcName,
			Namespace: testNamespace,
		},
		Spec: inferencev1alpha1.AIInferenceServiceSpec{
			// fake-ecrイメージ: 実際にpullしないのでImagePullPolicy: IfNotPresent相当で動作
			ModelImage:     "fake-ecr.example.com/vllm:fake",
			GPUNodePoolRef: "karpenter-gpu-g5g",
			MinReplicas:    1,
			MaxReplicas:    2,
			ScalingMetric: inferencev1alpha1.ScalingMetric{
				Type:        inferencev1alpha1.ScalingMetricQueueDepth,
				TargetValue: 10,
				// PrometheusURL空: DCGMメトリクスへの接続を避けるためCI環境では省略
			},
			BedrockFallback: &inferencev1alpha1.BedrockFallback{
				// falseにしてAWS Bedrock APIへの接続を回避する
				// CI環境のIAMロールにはBedrockへのアクセス権がないため
				Enabled: false,
			},
			SelfHealing: &inferencev1alpha1.SelfHealing{
				RestartOnOOM:       false,
				MaxRestartAttempts: 3,
			},
			Resources: &corev1.ResourceRequirements{
				Requests: corev1.ResourceList{
					corev1.ResourceCPU:    resource.MustParse("100m"),
					corev1.ResourceMemory: resource.MustParse("128Mi"),
				},
				Limits: corev1.ResourceList{
					corev1.ResourceCPU:    resource.MustParse("500m"),
					corev1.ResourceMemory: resource.MustParse("512Mi"),
				},
			},
		},
	}

	// CRを作成する
	if err := k8sClient.Create(ctx, svc); err != nil {
		t.Fatalf("AIInferenceServiceの作成に失敗しました: %v", err)
	}
	t.Logf("AIInferenceService %q を作成しました", svcName)

	// OperatorがDeploymentを生成するまで最大2分待つ
	t.Log("Operatorがreconcileして Deployment を生成するまで待機中...")
	if err := waitForDeployment(ctx, t, svcName, testNamespace); err != nil {
		t.Fatalf("Deploymentの生成待ちがタイムアウトしました: %v", err)
	}

	// Deploymentの内容を検証する
	t.Log("生成されたDeploymentの内容を検証中...")
	assertDeploymentSpec(ctx, t, svcName, testNamespace, svc)

	// statusのPhaseを確認する (Provisioning または Running が期待値)
	assertStatusPhase(ctx, t, svcName, testNamespace)
}

// TestAIInferenceServiceScaleToZero はminReplicas=0の設定でreconcileが正常動作するか確認する。
func TestAIInferenceServiceScaleToZero(t *testing.T) {
	ctx, cancel := context.WithTimeout(testCtx, testTimeout)
	defer cancel()

	svcName := "e2e-test-scale-zero"

	t.Cleanup(func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cleanupCancel()
		_ = k8sClient.Delete(cleanupCtx, &inferencev1alpha1.AIInferenceService{
			ObjectMeta: metav1.ObjectMeta{
				Name:      svcName,
				Namespace: testNamespace,
			},
		})
	})

	svc := &inferencev1alpha1.AIInferenceService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      svcName,
			Namespace: testNamespace,
		},
		Spec: inferencev1alpha1.AIInferenceServiceSpec{
			ModelImage:     "fake-ecr.example.com/vllm:fake",
			GPUNodePoolRef: "karpenter-gpu-g5g",
			// スケールトゼロ設定: minReplicas=0 はキューが空のときにPodをゼロにする
			MinReplicas: 0,
			MaxReplicas: 4,
			ScalingMetric: inferencev1alpha1.ScalingMetric{
				Type:        inferencev1alpha1.ScalingMetricQueueDepth,
				TargetValue: 10,
			},
			BedrockFallback: &inferencev1alpha1.BedrockFallback{
				Enabled: false,
			},
			SelfHealing: &inferencev1alpha1.SelfHealing{
				RestartOnOOM:       false,
				MaxRestartAttempts: 3,
			},
		},
	}

	if err := k8sClient.Create(ctx, svc); err != nil {
		t.Fatalf("AIInferenceServiceの作成に失敗しました: %v", err)
	}

	// Deploymentが生成され、レプリカが0であることを確認する
	if err := waitForDeployment(ctx, t, svcName, testNamespace); err != nil {
		t.Fatalf("Deploymentの生成待ちがタイムアウトしました: %v", err)
	}

	dep := &appsv1.Deployment{}
	if err := k8sClient.Get(ctx, types.NamespacedName{Name: svcName, Namespace: testNamespace}, dep); err != nil {
		t.Fatalf("Deploymentの取得に失敗しました: %v", err)
	}

	if *dep.Spec.Replicas != 0 {
		t.Errorf("期待するreplicas=0、実際の値=%d", *dep.Spec.Replicas)
	}
	t.Log("スケールトゼロのDeploymentが正常に生成されました")
}

// waitForDeployment はOperatorがDeploymentを生成するまでポーリングして待つ。
func waitForDeployment(ctx context.Context, t *testing.T, name, namespace string) error {
	t.Helper()
	return wait.PollUntilContextTimeout(ctx, pollInterval, testTimeout, true, func(ctx context.Context) (bool, error) {
		dep := &appsv1.Deployment{}
		err := k8sClient.Get(ctx, types.NamespacedName{Name: name, Namespace: namespace}, dep)
		if err != nil {
			if client.IgnoreNotFound(err) == nil {
				t.Logf("Deployment %q はまだ存在しません", name)
				return false, nil
			}
			return false, err
		}
		t.Logf("Deployment %q が生成されました (replicas=%d)", name, *dep.Spec.Replicas)
		return true, nil
	})
}

// assertDeploymentSpec はDeploymentの仕様がCRのSpecと一致するか検証する。
func assertDeploymentSpec(ctx context.Context, t *testing.T, name, namespace string, svc *inferencev1alpha1.AIInferenceService) {
	t.Helper()

	dep := &appsv1.Deployment{}
	if err := k8sClient.Get(ctx, types.NamespacedName{Name: name, Namespace: namespace}, dep); err != nil {
		t.Fatalf("Deploymentの取得に失敗しました: %v", err)
	}

	// コンテナイメージがCRのModelImageと一致するか確認する
	if len(dep.Spec.Template.Spec.Containers) == 0 {
		t.Fatal("Deploymentにコンテナが含まれていません")
	}
	container := dep.Spec.Template.Spec.Containers[0]
	if container.Image != svc.Spec.ModelImage {
		t.Errorf("コンテナイメージが一致しません: 期待値=%q, 実際=%q", svc.Spec.ModelImage, container.Image)
	}

	// レプリカ数がminReplicasと一致するか確認する
	if *dep.Spec.Replicas != int32(svc.Spec.MinReplicas) {
		t.Errorf("レプリカ数が一致しません: 期待値=%d, 実際=%d", svc.Spec.MinReplicas, *dep.Spec.Replicas)
	}

	t.Logf("Deployment仕様の検証が完了しました: image=%q, replicas=%d", container.Image, *dep.Spec.Replicas)
}

// assertStatusPhase はCRのstatusにPhaseが設定されているか確認する。
func assertStatusPhase(ctx context.Context, t *testing.T, name, namespace string) {
	t.Helper()

	// Phaseがセットされるまで少し待つ
	var phase inferencev1alpha1.InferencePhase
	_ = wait.PollUntilContextTimeout(ctx, pollInterval, 30*time.Second, true, func(ctx context.Context) (bool, error) {
		svc := &inferencev1alpha1.AIInferenceService{}
		if err := k8sClient.Get(ctx, types.NamespacedName{Name: name, Namespace: namespace}, svc); err != nil {
			return false, nil
		}
		if svc.Status.Phase != "" {
			phase = svc.Status.Phase
			return true, nil
		}
		return false, nil
	})

	if phase == "" {
		t.Error("AIInferenceServiceのStatus.Phaseが設定されていません")
		return
	}

	validPhases := map[inferencev1alpha1.InferencePhase]bool{
		inferencev1alpha1.PhaseRunning:      true,
		inferencev1alpha1.PhaseProvisioning: true,
		inferencev1alpha1.PhaseFallback:     true,
		inferencev1alpha1.PhaseDegraded:     true,
	}
	if !validPhases[phase] {
		t.Errorf("不正なPhase値: %q", phase)
	}
	t.Logf("Status.Phase=%q が設定されています", phase)
}
