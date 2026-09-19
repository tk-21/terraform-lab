// Package webhooks はAIInferenceServiceのAdmission Webhookを実装する
//
// ValidatingWebhook: 危険な設定(GPU limit未指定・不整合なSpec)を作成/更新時点でブロックする。
// MutatingWebhook: spotノード設定・自己修復・スケーリングのデフォルト値を注入する。
//
// なぜCRDレベルのWebhookにしたか:
//   Pod直接webhookにするとクラスター全体のPodに影響するためスコープが広すぎる。
//   AIInferenceServiceを受け付ける時点でSpec整合性を保証する方が責任境界が明確。
package webhooks

import (
	"context"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/webhook"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"

	inferencev1alpha1 "github.com/takuya/gpu-inference-operator-lab/api/v1alpha1"
)

// AIInferenceServiceWebhook はValidating+MutatingWebhookの実装
// +kubebuilder:webhook:path=/mutate-inference-takuya-dev-v1alpha1-aiinferenceservice,mutating=true,failurePolicy=fail,sideEffects=None,groups=inference.takuya.dev,resources=aiinferenceservices,verbs=create;update,versions=v1alpha1,name=maiinferenceservice.kb.io,admissionReviewVersions=v1
// +kubebuilder:webhook:path=/validate-inference-takuya-dev-v1alpha1-aiinferenceservice,mutating=false,failurePolicy=fail,sideEffects=None,groups=inference.takuya.dev,resources=aiinferenceservices,verbs=create;update,versions=v1alpha1,name=vaiinferenceservice.kb.io,admissionReviewVersions=v1
type AIInferenceServiceWebhook struct{}

var _ webhook.CustomDefaulter = &AIInferenceServiceWebhook{}
var _ webhook.CustomValidator = &AIInferenceServiceWebhook{}

// SetupWithManager はWebhookをcontroller-managerに登録する
func (w *AIInferenceServiceWebhook) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewWebhookManagedBy(mgr).
		For(&inferencev1alpha1.AIInferenceService{}).
		WithDefaulter(w).
		WithValidator(w).
		Complete()
}

// Default はMutatingWebhookのハンドラ。未設定フィールドにデフォルト値を注入する
//
// デフォルト値注入の設計理由:
//
//	ユーザーが省略しやすいフィールド(スケーリング間隔・修復試行回数)を
//	安全なデフォルト値で補完することで設定ミスを防ぐ。
//	spotノードのtoleration/nodeSelectorはGPU Podに必須だが記述量が多いため
//	Webhookで自動注入することで利用側のmanifestを簡潔に保つ。
func (w *AIInferenceServiceWebhook) Default(ctx context.Context, obj runtime.Object) error {
	ais, ok := obj.(*inferencev1alpha1.AIInferenceService)
	if !ok {
		return fmt.Errorf("expected AIInferenceService, got %T", obj)
	}

	// スケーリングポーリング間隔のデフォルト: 5秒
	// KEDAの15秒・CloudWatch Alarmの60秒と比較実験するための基準値
	if ais.Spec.ScalingMetric.PollingIntervalSeconds == 0 {
		ais.Spec.ScalingMetric.PollingIntervalSeconds = 5
	}

	// bedrockFallbackのタイムアウトデフォルト: 90秒
	// g5gコールドスタートの中央値より短く設定してSLOを優先する
	if ais.Spec.BedrockFallback != nil && ais.Spec.BedrockFallback.Enabled {
		if ais.Spec.BedrockFallback.GPUProvisionTimeoutSeconds == 0 {
			ais.Spec.BedrockFallback.GPUProvisionTimeoutSeconds = 90
		}
	}

	// selfHealing.maxRestartAttemptsのデフォルト: 3回
	// restartOnOOM=trueで maxRestartAttempts未指定の場合のみ注入する
	if ais.Spec.SelfHealing != nil && ais.Spec.SelfHealing.RestartOnOOM {
		if ais.Spec.SelfHealing.MaxRestartAttempts == 0 {
			ais.Spec.SelfHealing.MaxRestartAttempts = 3
		}
	}

	// Resourcesが未設定の場合にGPU workload向けのデフォルトを注入する
	// spotノード上のGPU Podはnvidia.com/gpu limitがないとスケジューラが
	// GPUリソースを確保せず、他のPodと競合してOOMが発生しやすくなる
	if ais.Spec.Resources == nil && ais.Spec.GPUNodePoolRef != "" {
		ais.Spec.Resources = defaultGPUResources()
	}

	return nil
}

// ValidateCreate はCreate時のValidatingWebhookハンドラ
func (w *AIInferenceServiceWebhook) ValidateCreate(ctx context.Context, obj runtime.Object) (admission.Warnings, error) {
	ais, ok := obj.(*inferencev1alpha1.AIInferenceService)
	if !ok {
		return nil, fmt.Errorf("expected AIInferenceService, got %T", obj)
	}
	return w.validate(ais)
}

// ValidateUpdate はUpdate時のValidatingWebhookハンドラ
func (w *AIInferenceServiceWebhook) ValidateUpdate(ctx context.Context, oldObj, newObj runtime.Object) (admission.Warnings, error) {
	ais, ok := newObj.(*inferencev1alpha1.AIInferenceService)
	if !ok {
		return nil, fmt.Errorf("expected AIInferenceService, got %T", newObj)
	}
	return w.validate(ais)
}

// ValidateDelete はDelete時のValidatingWebhookハンドラ(削除は制限しない)
func (w *AIInferenceServiceWebhook) ValidateDelete(ctx context.Context, obj runtime.Object) (admission.Warnings, error) {
	return nil, nil
}

// validate はCreate/Updateで共通のバリデーションロジック
func (w *AIInferenceServiceWebhook) validate(ais *inferencev1alpha1.AIInferenceService) (admission.Warnings, error) {
	var warnings admission.Warnings

	// maxReplicas >= minReplicas のチェック(CRDマーカーより詳細なエラーメッセージを返す)
	if ais.Spec.MaxReplicas < ais.Spec.MinReplicas {
		return nil, fmt.Errorf(
			"spec.maxReplicas(%d) must be >= spec.minReplicas(%d)",
			ais.Spec.MaxReplicas, ais.Spec.MinReplicas,
		)
	}

	// queueDepthタイプ選択時にqueueNameが必須
	if ais.Spec.ScalingMetric.Type == inferencev1alpha1.ScalingMetricQueueDepth &&
		ais.Spec.ScalingMetric.QueueName == "" {
		return nil, fmt.Errorf(
			"spec.scalingMetric.queueName is required when scalingMetric.type=queueDepth",
		)
	}

	// selfHealing.restartOnOOM=trueの場合、maxRestartAttemptsが必要
	// Webhookによるデフォルト注入後に検証するため、0のまま来た場合はエラー
	if ais.Spec.SelfHealing != nil && ais.Spec.SelfHealing.RestartOnOOM {
		if ais.Spec.SelfHealing.MaxRestartAttempts == 0 {
			return nil, fmt.Errorf(
				"spec.selfHealing.maxRestartAttempts must be set (>0) when restartOnOOM=true " +
					"to prevent unbounded restart loops",
			)
		}
	}

	// GPUNodePoolRefが設定されている場合はGPU limitが必須
	// GPU limitなしでGPUノードにスケジュールされると他のPodとGPUリソースを取り合い
	// OOMやPodEvictionが多発する事故シナリオを防ぐための強制ポリシー
	if ais.Spec.GPUNodePoolRef != "" {
		if err := validateGPULimit(ais.Spec.Resources); err != nil {
			return nil, err
		}
	}

	// modelImageに"latest"タグを使っている場合は警告(エラーにはしない)
	// latestタグはイメージの再現性を壊すためCIではtagged imageを推奨する
	if containsLatestTag(ais.Spec.ModelImage) {
		warnings = append(warnings, fmt.Sprintf(
			"spec.modelImage %q uses 'latest' tag; consider using a specific digest or version tag for reproducibility",
			ais.Spec.ModelImage,
		))
	}

	return warnings, nil
}

// validateGPULimit はResourceRequirementsにnvidia.com/gpu limitが含まれているか検証する
func validateGPULimit(resources *corev1.ResourceRequirements) error {
	if resources == nil {
		return fmt.Errorf(
			"spec.resources must be set when gpuNodePoolRef is specified; " +
				"include resources.limits[\"nvidia.com/gpu\"] to prevent GPU resource contention",
		)
	}

	gpuLimit, ok := resources.Limits[corev1.ResourceName("nvidia.com/gpu")]
	if !ok {
		return fmt.Errorf(
			"spec.resources.limits[\"nvidia.com/gpu\"] is required when gpuNodePoolRef is specified; " +
				"without it, multiple pods may compete for the same GPU causing OOM and eviction",
		)
	}

	if gpuLimit.Cmp(resource.MustParse("1")) < 0 {
		return fmt.Errorf(
			"spec.resources.limits[\"nvidia.com/gpu\"] must be >= 1, got %s",
			gpuLimit.String(),
		)
	}

	return nil
}

// defaultGPUResources はvLLM + 7Bモデルを想定したデフォルトリソース設定を返す
func defaultGPUResources() *corev1.ResourceRequirements {
	return &corev1.ResourceRequirements{
		Requests: corev1.ResourceList{
			corev1.ResourceMemory: resource.MustParse("8Gi"),
			corev1.ResourceCPU:    resource.MustParse("2"),
		},
		Limits: corev1.ResourceList{
			corev1.ResourceMemory:                  resource.MustParse("8Gi"),
			corev1.ResourceName("nvidia.com/gpu"): resource.MustParse("1"),
		},
	}
}

// containsLatestTag はmodelImageがlatestタグを使っているか判定する
func containsLatestTag(image string) bool {
	if image == "" {
		return false
	}
	// "image:latest" または タグなし(暗黙のlatest)
	if len(image) > 7 && image[len(image)-7:] == ":latest" {
		return true
	}
	// タグ区切り(:)がない場合はlatestとみなす(ただしdigest@sha256は除く)
	for i := len(image) - 1; i >= 0; i-- {
		switch image[i] {
		case ':':
			return false
		case '/':
			return true // タグなし
		case '@':
			return false // digest指定
		}
	}
	return true
}
