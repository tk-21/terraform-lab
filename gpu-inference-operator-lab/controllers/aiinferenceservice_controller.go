// Package controllers はAIInferenceServiceリソースのreconcileループを実装する
package controllers

import (
	"context"
	"fmt"
	"time"

	"github.com/go-logr/logr"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"

	inferencev1alpha1 "github.com/takuya/gpu-inference-operator-lab/api/v1alpha1"
	"github.com/takuya/gpu-inference-operator-lab/internal/fallback"
	custmetrics "github.com/takuya/gpu-inference-operator-lab/internal/metrics"
	"github.com/takuya/gpu-inference-operator-lab/internal/notify"
	"github.com/takuya/gpu-inference-operator-lab/internal/scaling"
	"github.com/takuya/gpu-inference-operator-lab/internal/selfheal"
)

const (
	// finalizerName はGPU関連外部リソースを安全にクリーンアップするためのfinalizer名
	// finalizer が残っている間はKubernetesがオブジェクトを物理削除しないことが保証される
	finalizerName = "inference.takuya.dev/cleanup"

	conditionTypeReady        = "Ready"
	conditionTypeProvisioning = "Provisioning"
	conditionTypeDegraded     = "Degraded"
	conditionTypeScaled       = "Scaled"
	conditionTypeFallback     = "Fallback"
)

// AIInferenceServiceReconciler はAIInferenceServiceリソースのreconcilerを定義する
type AIInferenceServiceReconciler struct {
	client.Client
	Log              logr.Logger
	Scheme           *runtime.Scheme
	Detector         *fallback.Detector
	SelfHealDetector *selfheal.Detector
	Notifier         *notify.ChatworkNotifier
	EventRecorder    record.EventRecorder
}

// +kubebuilder:rbac:groups=inference.takuya.dev,resources=aiinferenceservices,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=inference.takuya.dev,resources=aiinferenceservices/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=inference.takuya.dev,resources=aiinferenceservices/finalizers,verbs=update
// +kubebuilder:rbac:groups=apps,resources=deployments,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=core,resources=services,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=core,resources=pods,verbs=get;list;watch
// +kubebuilder:rbac:groups=core,resources=events,verbs=create;patch

// Reconcile はAIInferenceServiceリソースの変化を検知して期待状態に収束させる
//
// reconcileループを冪等に保つ理由:
//
//	ネットワーク分断・Operatorクラッシュ後に同じReconcileが何度も呼ばれるため、
//	副作用を伴う操作は必ず「現在の状態を確認 → 差分があれば変更」という手順を踏む。
//	Phase 3でRequeueAfterを追加し、メトリクスポーリングを自律的なループとして実装する。
//	KEDAはScaledObjectを監視するControllerが外部からスケーリング判断を挿入するが、
//	本実装はAISのReconcilerがメトリクス取得・スケーリング判断・Deployment更新を全て担う。
func (r *AIInferenceServiceReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	// reconcileIDをログに付与することで、同一CRの複数reconcileを追跡できる
	reconcileStart := time.Now()
	log := r.Log.WithValues("aiinferenceservice", req.NamespacedName, "reconcileAt", reconcileStart.Format(time.RFC3339))

	ais := &inferencev1alpha1.AIInferenceService{}
	if err := r.Get(ctx, req.NamespacedName, ais); err != nil {
		if apierrors.IsNotFound(err) {
			return ctrl.Result{}, nil
		}
		custmetrics.ReconcileErrors.WithLabelValues(req.Namespace, req.Name, "GetFailed").Inc()
		return ctrl.Result{}, err
	}

	if !ais.DeletionTimestamp.IsZero() {
		return ctrl.Result{}, r.handleDeletion(ctx, log, ais)
	}

	if !controllerutil.ContainsFinalizer(ais, finalizerName) {
		controllerutil.AddFinalizer(ais, finalizerName)
		if err := r.Update(ctx, ais); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{}, nil
	}

	// メトリクスを取得してスケーリング判定を行う
	// PrometheusURLが未設定の場合はMinReplicasを維持する(スケーリング無効)
	desiredReplicas := ais.Spec.MinReplicas
	var scalingDecision *scaling.ScalingDecision

	if ais.Spec.ScalingMetric.PrometheusURL != "" {
		decision, err := r.evaluateScaling(ctx, log, ais)
		if err != nil {
			// メトリクス取得失敗は致命的エラーではない。現在レプリカ数を維持してretryする
			log.Error(err, "metrics fetch failed, keeping current replicas")
			custmetrics.ReconcileErrors.WithLabelValues(ais.Namespace, ais.Name, "MetricsFetchFailed").Inc()
		} else {
			desiredReplicas = decision.DesiredReplicas
			scalingDecision = &decision
		}
	}

	phase := string(ais.Status.Phase)
	log.Info("Reconciling AIInferenceService",
		"phase", phase,
		"desiredReplicas", desiredReplicas)

	if err := r.reconcileDeployment(ctx, log, ais, desiredReplicas); err != nil {
		custmetrics.ReconcileErrors.WithLabelValues(ais.Namespace, ais.Name, "DeploymentReconcileFailed").Inc()
		r.setDegradedCondition(ctx, ais, "DeploymentReconcileFailed", err.Error())
		return ctrl.Result{}, err
	}

	if err := r.reconcileService(ctx, log, ais); err != nil {
		custmetrics.ReconcileErrors.WithLabelValues(ais.Namespace, ais.Name, "ServiceReconcileFailed").Inc()
		r.setDegradedCondition(ctx, ais, "ServiceReconcileFailed", err.Error())
		return ctrl.Result{}, err
	}

	// 自己修復: Deployment内のPodのOOMKilled/CrashLoopBackOffを検知してアクションを実行する
	// Deployment作成後に実行することで正しいPodリストを取得できる
	if err := r.reconcileSelfHeal(ctx, log, ais); err != nil {
		log.Error(err, "self-heal reconciliation failed, continuing without self-heal update")
		custmetrics.ReconcileErrors.WithLabelValues(ais.Namespace, ais.Name, "SelfHealFailed").Inc()
	}

	// フォールバック判定: DeploymentのreadyReplicasを元にBedrockへの切り替えを決定する
	// reconcileDeploymentの後に実行することで、最新のreplica状態を取得できる
	fallbackDecision, requeue, err := r.reconcileFallback(ctx, log, ais)
	if err != nil {
		// フォールバック判定の失敗はGPUの正常動作をブロックしないようにログのみ記録する
		log.Error(err, "fallback reconciliation failed, continuing without fallback state update")
		custmetrics.ReconcileErrors.WithLabelValues(ais.Namespace, ais.Name, "FallbackReconcileFailed").Inc()
	}
	// アノテーション更新のために即座に再reconcileが必要な場合は早期リターン
	if requeue {
		return ctrl.Result{Requeue: true}, nil
	}

	if err := r.updateStatus(ctx, ais, scalingDecision, fallbackDecision); err != nil {
		custmetrics.ReconcileErrors.WithLabelValues(ais.Namespace, ais.Name, "StatusUpdateFailed").Inc()
		return ctrl.Result{}, err
	}

	// reconcile完了時間をphaseラベル付きで記録する
	// phaseはupdateStatus後の最新値を使う(status更新後の状態を反映するため)
	custmetrics.ReconcileDuration.WithLabelValues(
		ais.Namespace, ais.Name, string(ais.Status.Phase),
	).Observe(time.Since(reconcileStart).Seconds())

	// ポーリング間隔後に再実行してメトリクス変化を検知する
	// RequeueAfterはevent-drivenなWatchとは独立して動作し、
	// メトリクス変化はCRDの変更を伴わないためWatchだけでは検知できない
	pollingInterval := time.Duration(scaling.PollingInterval(ais.Spec)) * time.Second
	return ctrl.Result{RequeueAfter: pollingInterval}, nil
}

// reconcileSelfHeal はDeployment配下のPodの障害を検知して修復アクションを実行する
//
// PhaseDegraded中はスキップする理由:
//
//	Degradedは「自動修復の限界を超えた」シグナルであり、
//	人間の介入なしに修復を継続することはコスト暴走の原因になる。
func (r *AIInferenceServiceReconciler) reconcileSelfHeal(
	ctx context.Context,
	log logr.Logger,
	ais *inferencev1alpha1.AIInferenceService,
) error {
	if r.SelfHealDetector == nil || ais.Spec.SelfHealing == nil {
		return nil
	}
	// 既にDegradedの場合は追加修復を試みない
	if ais.Status.Phase == inferencev1alpha1.PhaseDegraded {
		return nil
	}

	podList := &corev1.PodList{}
	if err := r.List(ctx, podList,
		client.InNamespace(ais.Namespace),
		client.MatchingLabels{"inference.takuya.dev/service": ais.Name},
	); err != nil {
		return fmt.Errorf("listing pods for self-heal: %w", err)
	}

	health := selfheal.InspectPods(podList.Items)
	decision := r.SelfHealDetector.Evaluate(ais, health)

	if decision.ShouldDegrade {
		log.Info("Self-heal limit reached, degrading", "reason", decision.Reason)
		custmetrics.SelfHealActions.WithLabelValues(ais.Namespace, ais.Name, "degraded").Inc()
		if r.Notifier != nil {
			if err := r.Notifier.NotifyDegraded(ctx, ais.Name, ais.Namespace, decision.Reason); err != nil {
				log.Error(err, "failed to send degraded notification")
			}
		}
		r.setDegradedCondition(ctx, ais, "SelfHealExhausted", decision.Reason)
		return nil
	}

	if decision.ShouldBumpMemory {
		log.Info("OOMKilled detected, bumping memory limit", "pod", decision.PodName, "reason", decision.Reason)
		custmetrics.SelfHealActions.WithLabelValues(ais.Namespace, ais.Name, "memory_bump").Inc()
		if err := r.bumpMemoryLimit(ctx, log, ais); err != nil {
			return fmt.Errorf("bumping memory limit: %w", err)
		}
		// RestartCount更新はStatus.Update()で行う(updateStatusの前にインクリメントしておく)
		ais.Status.RestartCount++
		setStatusCondition(&ais.Status.Conditions, metav1.Condition{
			Type:    "SelfHealed",
			Status:  metav1.ConditionTrue,
			Reason:  "OOMKilledMemoryBump",
			Message: decision.Reason,
		})
		if r.EventRecorder != nil {
			r.EventRecorder.Event(ais, corev1.EventTypeWarning, "OOMKilledDetected", decision.Reason)
		}
	}

	if decision.ShouldRecordEvent {
		log.Info("CrashLoopBackOff detected, recording event", "pod", decision.PodName)
		custmetrics.SelfHealActions.WithLabelValues(ais.Namespace, ais.Name, "crash_loop_detected").Inc()
		if r.EventRecorder != nil {
			r.EventRecorder.Event(ais, corev1.EventTypeWarning, "CrashLoopBackOff", decision.Reason)
		}
		if r.Notifier != nil {
			if err := r.Notifier.NotifyCrashLoop(
				ctx, ais.Name, ais.Namespace, decision.PodName, decision.Reason,
			); err != nil {
				log.Error(err, "failed to send crash loop notification")
			}
		}
		ais.Status.RestartCount++
	}

	return nil
}

// bumpMemoryLimit はDeploymentのvllmコンテナのmemory limitを25%引き上げる
//
// 単純Pod再起動ではなくlimitを変更してから再起動する理由:
//
//	OOMKilledは「割り当てたメモリが足りない」ことが原因であり、
//	同じlimitで再起動しても即座に再度OOMになる。limitを先に引き上げてから
//	Deploymentを更新することでPodがrolling updateされ、より多いメモリで起動する。
func (r *AIInferenceServiceReconciler) bumpMemoryLimit(
	ctx context.Context,
	log logr.Logger,
	ais *inferencev1alpha1.AIInferenceService,
) error {
	deployment := &appsv1.Deployment{}
	if err := r.Get(ctx, client.ObjectKey{Name: ais.Name, Namespace: ais.Namespace}, deployment); err != nil {
		return fmt.Errorf("getting deployment for memory bump: %w", err)
	}

	if len(deployment.Spec.Template.Spec.Containers) == 0 {
		return fmt.Errorf("deployment has no containers")
	}

	container := &deployment.Spec.Template.Spec.Containers[0]
	if container.Resources.Limits == nil {
		container.Resources.Limits = corev1.ResourceList{}
	}
	if container.Resources.Requests == nil {
		container.Resources.Requests = corev1.ResourceList{}
	}

	// 現在のmemory limitを取得してMilliValueで計算する
	currentLimit, ok := container.Resources.Limits[corev1.ResourceMemory]
	if !ok {
		// limit未設定の場合はデフォルト初期値(8Gi)から開始する
		currentLimit = resource.MustParse(fmt.Sprintf("%dMi", selfheal.DefaultInitialMemoryMi))
	}

	// 25%増加: (currentMi * 125) / 100
	currentMi := currentLimit.Value() / (1024 * 1024)
	newMi := currentMi * (100 + selfheal.MemoryBumpPercent) / 100
	newLimit := resource.MustParse(fmt.Sprintf("%dMi", newMi))

	log.Info("Bumping memory limit",
		"from", currentLimit.String(),
		"to", newLimit.String(),
		"container", container.Name,
	)

	container.Resources.Limits[corev1.ResourceMemory] = newLimit
	container.Resources.Requests[corev1.ResourceMemory] = newLimit

	return r.Update(ctx, deployment)
}

// reconcileFallback はBedrockフォールバック状態を評価してアノテーションを管理する
//
// アノテーション管理をControllerで集中させてDetectorを純粋関数にする理由:
//
//	DetectorがKubernetes APIを直接呼ぶとfake clientなしではユニットテストが書けない。
//	コントローラーがAnnotation変更の唯一の責任者であることでテスト容易性と責任分離を両立する。
//
// requeue=trueを返す場合はアノテーション設定直後で、次のreconcileで正確な経過時間を計算させる。
func (r *AIInferenceServiceReconciler) reconcileFallback(
	ctx context.Context,
	log logr.Logger,
	ais *inferencev1alpha1.AIInferenceService,
) (fallback.Decision, bool, error) {
	if r.Detector == nil {
		return fallback.Decision{Reason: "fallback detector not configured"}, false, nil
	}

	// 現在のDeploymentからreadyReplicasを取得
	deployment := &appsv1.Deployment{}
	var readyReplicas int32
	if err := r.Get(ctx, client.ObjectKey{Name: ais.Name, Namespace: ais.Namespace}, deployment); err == nil {
		readyReplicas = deployment.Status.ReadyReplicas
	}

	decision := r.Detector.Evaluate(ais, readyReplicas)
	log.Info("Fallback evaluation", "decision", decision.Reason, "elapsed", decision.ProvisioningElapsed)

	// アノテーション変更が必要な場合はDeep Copyして更新する
	// Status Subresourceとは別にSpec/Metadataの変更はr.Update()を使う
	if decision.NeedsAnnotation || decision.ClearAnnotation {
		updated := ais.DeepCopy()
		if updated.Annotations == nil {
			updated.Annotations = map[string]string{}
		}
		if decision.ClearAnnotation {
			delete(updated.Annotations, fallback.AnnotationProvisioningStart)
		}
		if decision.NeedsAnnotation {
			updated.Annotations[fallback.AnnotationProvisioningStart] = time.Now().UTC().Format(time.RFC3339)
		}
		if err := r.Update(ctx, updated); err != nil {
			return decision, false, fmt.Errorf("updating provisioning annotation: %w", err)
		}
		// アノテーション設定直後は再reconcileして正確な経過時間を計算させる
		return decision, true, nil
	}

	// Chatwork通知とメトリクス記録: 状態遷移時のみ実行する
	// 毎回のreconcileで送ると通知スパムになるため、前回のStatusと比較する
	prevBackend := ais.Status.ActiveBackend
	if decision.ShouldFallback && prevBackend != inferencev1alpha1.BackendBedrock {
		// GPU→Bedrock切替: フォールバック発動回数をカウント
		custmetrics.BedrockFallbackTotal.WithLabelValues(ais.Namespace, ais.Name, "to_bedrock").Inc()
		if r.Notifier != nil {
			if err := r.Notifier.NotifyFallbackActivated(ctx, ais.Name, ais.Namespace, decision.ProvisioningElapsed); err != nil {
				// 通知失敗はOperatorの動作を止めない(best-effort)
				log.Error(err, "failed to send fallback activation notification")
			}
		}
	}
	if decision.ShouldRecover && prevBackend == inferencev1alpha1.BackendBedrock {
		// Bedrock→GPU回復: フォールバック継続時間を記録して切戻し回数をカウント
		custmetrics.BedrockFallbackTotal.WithLabelValues(ais.Namespace, ais.Name, "to_gpu").Inc()
		custmetrics.BedrockFallbackDuration.WithLabelValues(ais.Namespace, ais.Name).Observe(
			decision.ProvisioningElapsed.Seconds(),
		)
		if r.Notifier != nil {
			if err := r.Notifier.NotifyFallbackRecovered(ctx, ais.Name, ais.Namespace); err != nil {
				log.Error(err, "failed to send fallback recovery notification")
			}
		}
	}

	return decision, false, nil
}

// evaluateScaling はPrometheusからメトリクスを取得してスケーリング判定を実施する
func (r *AIInferenceServiceReconciler) evaluateScaling(
	ctx context.Context,
	log logr.Logger,
	ais *inferencev1alpha1.AIInferenceService,
) (scaling.ScalingDecision, error) {
	fetcher := scaling.NewPrometheusMetricsFetcher(ais.Spec.ScalingMetric.PrometheusURL)

	var metricValue float64
	var err error

	switch ais.Spec.ScalingMetric.Type {
	case inferencev1alpha1.ScalingMetricGPUUtilization:
		mv, fetchErr := fetcher.FetchGPUUtilization(ctx, ais.Namespace, ais.Name)
		if fetchErr != nil {
			return scaling.ScalingDecision{}, fmt.Errorf("fetching GPU utilization: %w", fetchErr)
		}
		metricValue = mv.Value

	case inferencev1alpha1.ScalingMetricQueueDepth:
		if ais.Spec.ScalingMetric.QueueName == "" {
			return scaling.ScalingDecision{}, fmt.Errorf("queueName must be set when scalingMetric.type=queueDepth")
		}
		mv, fetchErr := fetcher.FetchQueueDepth(ctx, ais.Spec.ScalingMetric.QueueName)
		if fetchErr != nil {
			return scaling.ScalingDecision{}, fmt.Errorf("fetching queue depth: %w", fetchErr)
		}
		metricValue = mv.Value
	}

	// 現在のDeploymentのreplicaを取得してヒステリシス計算に使う
	deployment := &appsv1.Deployment{}
	currentReplicas := ais.Spec.MinReplicas
	if err = r.Get(ctx, client.ObjectKey{Name: ais.Name, Namespace: ais.Namespace}, deployment); err == nil {
		if deployment.Spec.Replicas != nil {
			currentReplicas = *deployment.Spec.Replicas
		}
	}

	decision := scaling.CalculateDesiredReplicas(ais.Spec, currentReplicas, metricValue)
	log.Info("Scaling decision",
		"metric", metricValue,
		"currentReplicas", currentReplicas,
		"desiredReplicas", decision.DesiredReplicas,
		"reason", decision.Reason,
	)
	return decision, nil
}

// handleDeletion はCR削除時のクリーンアップ処理を実行してfinalizerを除去する
func (r *AIInferenceServiceReconciler) handleDeletion(ctx context.Context, log logr.Logger, ais *inferencev1alpha1.AIInferenceService) error {
	if !controllerutil.ContainsFinalizer(ais, finalizerName) {
		return nil
	}

	log.Info("Running cleanup finalizer", "name", ais.Name, "phase", ais.Status.Phase)

	if err := r.cleanupExternalResources(ctx, log, ais); err != nil {
		return fmt.Errorf("external resource cleanup failed: %w", err)
	}

	controllerutil.RemoveFinalizer(ais, finalizerName)
	return r.Update(ctx, ais)
}

// cleanupExternalResources はKubernetes管理外のGPU/Bedrock外部リソースを解放する
func (r *AIInferenceServiceReconciler) cleanupExternalResources(ctx context.Context, log logr.Logger, ais *inferencev1alpha1.AIInferenceService) error {
	log.Info("Cleaning up external resources", "name", ais.Name)
	return nil
}

// reconcileDeployment はvLLM Deploymentを冪等に期待状態へ収束させる
// desiredReplicas はメトリクス評価済みの目標レプリカ数(フォールバック時はMinReplicas)
func (r *AIInferenceServiceReconciler) reconcileDeployment(
	ctx context.Context,
	log logr.Logger,
	ais *inferencev1alpha1.AIInferenceService,
	desiredReplicas int32,
) error {
	desired := r.buildDeployment(ais, desiredReplicas)

	existing := &appsv1.Deployment{}
	err := r.Get(ctx, client.ObjectKeyFromObject(desired), existing)
	if apierrors.IsNotFound(err) {
		log.Info("Creating Deployment", "name", desired.Name, "replicas", desiredReplicas)
		return r.Create(ctx, desired)
	}
	if err != nil {
		return err
	}

	needsUpdate := false
	if len(existing.Spec.Template.Spec.Containers) > 0 &&
		existing.Spec.Template.Spec.Containers[0].Image != ais.Spec.ModelImage {
		existing.Spec.Template.Spec.Containers[0].Image = ais.Spec.ModelImage
		needsUpdate = true
	}
	if existing.Spec.Replicas == nil || *existing.Spec.Replicas != desiredReplicas {
		existing.Spec.Replicas = &desiredReplicas
		needsUpdate = true
	}

	if needsUpdate {
		log.Info("Updating Deployment",
			"name", existing.Name,
			"image", ais.Spec.ModelImage,
			"replicas", desiredReplicas)
		return r.Update(ctx, existing)
	}
	return nil
}

// reconcileService はvLLM向けのClusterIP Serviceを冪等に管理する
func (r *AIInferenceServiceReconciler) reconcileService(ctx context.Context, log logr.Logger, ais *inferencev1alpha1.AIInferenceService) error {
	desired := r.buildService(ais)

	existing := &corev1.Service{}
	err := r.Get(ctx, client.ObjectKeyFromObject(desired), existing)
	if apierrors.IsNotFound(err) {
		log.Info("Creating Service", "name", desired.Name)
		return r.Create(ctx, desired)
	}
	return err
}

// updateStatus はDeploymentの観測状態・スケーリング判定・フォールバック判定からAISのstatusを算出して更新する
func (r *AIInferenceServiceReconciler) updateStatus(
	ctx context.Context,
	ais *inferencev1alpha1.AIInferenceService,
	decision *scaling.ScalingDecision,
	fb fallback.Decision,
) error {
	deployment := &appsv1.Deployment{}
	if err := r.Get(ctx, client.ObjectKey{Name: ais.Name, Namespace: ais.Namespace}, deployment); err != nil {
		return err
	}

	ais.Status.ReadyReplicas = deployment.Status.ReadyReplicas

	switch {
	case ais.Status.Phase == inferencev1alpha1.PhaseDegraded:
		// reconcileSelfHealがDegradedを設定済みの場合はPhaseを上書きしない
		// setDegradedConditionがすでにr.Status().Update()を呼んでいるため、
		// ここではConditionとReadyReplicasのみ同期する
		return r.Status().Update(ctx, ais)

	case fb.ShouldFallback:
		// GPUプロビジョニングタイムアウト → Bedrockフォールバック状態
		ais.Status.Phase = inferencev1alpha1.PhaseFallback
		ais.Status.ActiveBackend = inferencev1alpha1.BackendBedrock
		setStatusCondition(&ais.Status.Conditions, metav1.Condition{
			Type:    conditionTypeFallback,
			Status:  metav1.ConditionTrue,
			Reason:  "GPUProvisionTimeout",
			Message: fb.Reason,
		})
		setStatusCondition(&ais.Status.Conditions, metav1.Condition{
			Type:    conditionTypeReady,
			Status:  metav1.ConditionFalse,
			Reason:  "FallbackActive",
			Message: "serving via Amazon Bedrock (GPU provisioning timed out)",
		})

	case fb.ShouldRecover:
		// Bedrockから GPU への切り戻し完了
		ais.Status.Phase = inferencev1alpha1.PhaseRunning
		ais.Status.ActiveBackend = inferencev1alpha1.BackendGPU
		setStatusCondition(&ais.Status.Conditions, metav1.Condition{
			Type:    conditionTypeFallback,
			Status:  metav1.ConditionFalse,
			Reason:  "GPURecovered",
			Message: "GPU pods are ready, traffic returned from Bedrock to GPU",
		})
		setStatusCondition(&ais.Status.Conditions, metav1.Condition{
			Type:    conditionTypeReady,
			Status:  metav1.ConditionTrue,
			Reason:  "Running",
			Message: "vLLM inference is running on GPU",
		})

	case deployment.Status.ReadyReplicas > 0:
		// GPU正常稼働
		ais.Status.Phase = inferencev1alpha1.PhaseRunning
		ais.Status.ActiveBackend = inferencev1alpha1.BackendGPU
		setStatusCondition(&ais.Status.Conditions, metav1.Condition{
			Type:    conditionTypeReady,
			Status:  metav1.ConditionTrue,
			Reason:  "Running",
			Message: "vLLM inference is running on GPU",
		})
		setStatusCondition(&ais.Status.Conditions, metav1.Condition{
			Type:    conditionTypeProvisioning,
			Status:  metav1.ConditionFalse,
			Reason:  "Running",
			Message: "GPU node provisioning complete",
		})

	default:
		// GPUプロビジョニング中(タイムアウト未達)
		ais.Status.Phase = inferencev1alpha1.PhaseProvisioning
		setStatusCondition(&ais.Status.Conditions, metav1.Condition{
			Type:    conditionTypeReady,
			Status:  metav1.ConditionFalse,
			Reason:  "Provisioning",
			Message: fb.Reason,
		})
		setStatusCondition(&ais.Status.Conditions, metav1.Condition{
			Type:    conditionTypeProvisioning,
			Status:  metav1.ConditionTrue,
			Reason:  "GPUNodeStarting",
			Message: "Waiting for Karpenter to provision GPU node",
		})
	}

	// スケーリングが発生した場合はLastScaleTimeを更新しConditionに記録する
	if decision != nil && decision.ScaleChanged {
		now := metav1.Now()
		ais.Status.LastScaleTime = &now
		setStatusCondition(&ais.Status.Conditions, metav1.Condition{
			Type:   conditionTypeScaled,
			Status: metav1.ConditionTrue,
			Reason: "MetricsBasedScaling",
			Message: fmt.Sprintf("scaled to %d replicas (metric=%.2f, reason=%s)",
				decision.DesiredReplicas, decision.CurrentMetric, decision.Reason),
		})
	}

	return r.Status().Update(ctx, ais)
}

// setDegradedCondition はreconcileエラー時にDegradedコンディションをベストエフォートで記録する
func (r *AIInferenceServiceReconciler) setDegradedCondition(ctx context.Context, ais *inferencev1alpha1.AIInferenceService, reason, msg string) {
	setStatusCondition(&ais.Status.Conditions, metav1.Condition{
		Type:    conditionTypeDegraded,
		Status:  metav1.ConditionTrue,
		Reason:  reason,
		Message: msg,
	})
	ais.Status.Phase = inferencev1alpha1.PhaseDegraded
	_ = r.Status().Update(ctx, ais)
}

// setStatusCondition はKubernetes標準のcondition patternに従ってconditionを更新する
// Statusが変化しない場合はLastTransitionTimeを保持することでノイズを防ぐ
func setStatusCondition(conditions *[]metav1.Condition, newCond metav1.Condition) {
	now := metav1.Now()
	for i, c := range *conditions {
		if c.Type == newCond.Type {
			if c.Status != newCond.Status {
				newCond.LastTransitionTime = now
			} else {
				newCond.LastTransitionTime = c.LastTransitionTime
			}
			(*conditions)[i] = newCond
			return
		}
	}
	newCond.LastTransitionTime = now
	*conditions = append(*conditions, newCond)
}

// buildDeployment はAIInferenceServiceのSpecからDeploymentマニフェストを生成する
func (r *AIInferenceServiceReconciler) buildDeployment(ais *inferencev1alpha1.AIInferenceService, replicas int32) *appsv1.Deployment {
	labels := map[string]string{
		"app":                          ais.Name,
		"inference.takuya.dev/service": ais.Name,
	}

	return &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ais.Name,
			Namespace: ais.Namespace,
			OwnerReferences: []metav1.OwnerReference{
				*metav1.NewControllerRef(ais, inferencev1alpha1.GroupVersion.WithKind("AIInferenceService")),
			},
		},
		Spec: appsv1.DeploymentSpec{
			Replicas: &replicas,
			Selector: &metav1.LabelSelector{MatchLabels: labels},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{Labels: labels},
				Spec: corev1.PodSpec{
					// KarpenterのNodePoolラベルでGPUノードへのスケジューリングを制約する
					NodeSelector: map[string]string{
						"karpenter.sh/nodepool": ais.Spec.GPUNodePoolRef,
					},
					Containers: []corev1.Container{
						{
							Name:  "vllm",
							Image: ais.Spec.ModelImage,
							Ports: []corev1.ContainerPort{
								{ContainerPort: 8000, Protocol: corev1.ProtocolTCP},
							},
							// specにResourcesが指定されている場合は反映する
							// Webhookがデフォルト値を注入するためnilになるケースは稀
							Resources: func() corev1.ResourceRequirements {
								if ais.Spec.Resources != nil {
									return *ais.Spec.Resources
								}
								return corev1.ResourceRequirements{}
							}(),
						},
					},
				},
			},
		},
	}
}

// buildService はAIInferenceService向けのClusterIP Serviceを生成する
func (r *AIInferenceServiceReconciler) buildService(ais *inferencev1alpha1.AIInferenceService) *corev1.Service {
	selector := map[string]string{
		"inference.takuya.dev/service": ais.Name,
	}
	return &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ais.Name,
			Namespace: ais.Namespace,
			OwnerReferences: []metav1.OwnerReference{
				*metav1.NewControllerRef(ais, inferencev1alpha1.GroupVersion.WithKind("AIInferenceService")),
			},
		},
		Spec: corev1.ServiceSpec{
			Selector: selector,
			Ports: []corev1.ServicePort{
				{Port: 8000, Protocol: corev1.ProtocolTCP},
			},
		},
	}
}

// SetupWithManager はReconcilerをcontroller-managerに登録する
func (r *AIInferenceServiceReconciler) SetupWithManager(mgr ctrl.Manager) error {
	// EventRecorderが未設定の場合はManagerから取得する
	if r.EventRecorder == nil {
		r.EventRecorder = mgr.GetEventRecorderFor("aiinferenceservice-controller")
	}
	return ctrl.NewControllerManagedBy(mgr).
		For(&inferencev1alpha1.AIInferenceService{}).
		Owns(&appsv1.Deployment{}).
		Owns(&corev1.Service{}).
		Complete(r)
}
