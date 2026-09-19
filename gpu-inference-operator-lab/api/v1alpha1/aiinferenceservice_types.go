// Package v1alpha1 defines the v1alpha1 version of the AIInferenceService CRD.
// なぜ独自CRDにするか:
//   KEDA ScaledObjectはキュー深度やCPU等の汎用メトリクスへのスケーリングしか提供しない。
//   Bedrockへの自動フォールバック・OOMKilled自己修復・GPUプロビジョニング状態管理を
//   単一のリソースで表現し、Operatorが全ライフサイクルを責任を持って管理するために独自CRDが必要。
//   HPAはカスタムメトリクスを扱えるが、フォールバックロジックやself-healingを
//   Kubernetesネイティブなstatus/conditionで表現できない。
package v1alpha1

import (
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// ScalingMetricType はスケーリングに使用するメトリクスの種類を表す
// +kubebuilder:validation:Enum=queueDepth;gpuUtilization
type ScalingMetricType string

const (
	// ScalingMetricQueueDepth はリクエストキューの深度を基準にスケーリングする
	ScalingMetricQueueDepth ScalingMetricType = "queueDepth"
	// ScalingMetricGPUUtilization はGPU使用率を基準にスケーリングする
	ScalingMetricGPUUtilization ScalingMetricType = "gpuUtilization"
)

// InferencePhase はAIInferenceServiceの現在の動作フェーズを表す
// +kubebuilder:validation:Enum=Running;Provisioning;Fallback;Degraded
type InferencePhase string

const (
	// PhaseRunning はGPUノードで正常に推論が動作している状態
	PhaseRunning InferencePhase = "Running"
	// PhaseProvisioning はKarpenterがGPUノードをプロビジョニング中の状態
	PhaseProvisioning InferencePhase = "Provisioning"
	// PhaseFallback はGPUプロビジョニングタイムアウト後にBedrockで代替推論中の状態
	PhaseFallback InferencePhase = "Fallback"
	// PhaseDegraded は自己修復試行上限に達し、手動介入が必要な状態
	PhaseDegraded InferencePhase = "Degraded"
)

// ActiveBackend は現在推論を処理しているバックエンドを表す
// +kubebuilder:validation:Enum=gpu;bedrock
type ActiveBackend string

const (
	// BackendGPU はGPUノード上のvLLMが推論を処理している
	BackendGPU ActiveBackend = "gpu"
	// BackendBedrock はAmazon Bedrockが推論を処理している(フォールバック中)
	BackendBedrock ActiveBackend = "bedrock"
)

// ScalingMetric はオートスケーリングのメトリクス設定を定義する
type ScalingMetric struct {
	// Type はスケーリングに使用するメトリクスの種類
	// +kubebuilder:validation:Required
	Type ScalingMetricType `json:"type"`

	// TargetValue はスケーリングの閾値。queueDepthならキュー深度、gpuUtilizationなら使用率(%)
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:Minimum=1
	TargetValue int32 `json:"targetValue"`

	// PrometheusURL はDCGM Exporter/CloudWatch ExporterのメトリクスをスクレイプするPrometheusのURL
	// 空の場合はメトリクス取得をスキップしてMinReplicasを維持する(スケーリング無効化)
	// +kubebuilder:validation:Optional
	PrometheusURL string `json:"prometheusURL,omitempty"`

	// PollingIntervalSeconds はPrometheusへのメトリクスポーリング間隔(秒)
	// KEDAのデフォルト15秒・CloudWatch Alarmの60秒と比較実験するために変更可能にしている
	// +kubebuilder:validation:Optional
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=300
	PollingIntervalSeconds int32 `json:"pollingIntervalSeconds,omitempty"`

	// QueueName はqueueDepthタイプ使用時のSQSキュー名
	// CloudWatch Exporterが`aws_sqs_approximate_number_of_messages_visible_maximum`として公開している前提
	// +kubebuilder:validation:Optional
	QueueName string `json:"queueName,omitempty"`
}

// BedrockFallback はGPUプロビジョニングタイムアウト時のBedrockフォールバック設定
type BedrockFallback struct {
	// Enabled がtrueの場合、GPUノードが時間内に起動しない場合にBedrockへ自動切替する
	// GPUコールドスタート(g5gは通常3-5分かかる)中もSLOを維持するための設計
	// +kubebuilder:validation:Required
	Enabled bool `json:"enabled"`

	// ModelId はフォールバック先のBedrockモデルID
	// +kubebuilder:validation:Optional
	ModelId string `json:"modelId,omitempty"`

	// GPUProvisionTimeoutSeconds はBedrockへ切り替えるまでのGPUプロビジョニング待機時間(秒)
	// Karpenterのノード起動時間を考慮してデフォルト90秒を推奨
	// +kubebuilder:validation:Optional
	// +kubebuilder:validation:Minimum=30
	// +kubebuilder:validation:Maximum=600
	GPUProvisionTimeoutSeconds int32 `json:"gpuProvisionTimeoutSeconds,omitempty"`
}

// SelfHealing はCrashLoopBackOff/OOMKilledの自己修復設定
type SelfHealing struct {
	// RestartOnOOM がtrueの場合、OOMKilledを検知したらPodを自動再起動する
	// +kubebuilder:validation:Optional
	RestartOnOOM bool `json:"restartOnOOM,omitempty"`

	// MaxRestartAttempts は自動再起動の最大試行回数。超えた場合はPhaseDegradedに遷移
	// +kubebuilder:validation:Optional
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=10
	MaxRestartAttempts int32 `json:"maxRestartAttempts,omitempty"`
}

// AIInferenceServiceSpec はAIInferenceServiceの期待状態を定義する
type AIInferenceServiceSpec struct {
	// ModelImage はvLLMを含むコンテナイメージ(ECR URI)
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinLength=1
	ModelImage string `json:"modelImage"`

	// GPUNodePoolRef はKarpenterのNodePool名。OperatorはこのNodePoolのノードにPodをスケジュールする
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinLength=1
	GPUNodePoolRef string `json:"gpuNodePoolRef"`

	// MinReplicas は最小レプリカ数。0を許容することでscale-to-zeroコスト最適化を実現する
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:Minimum=0
	MinReplicas int32 `json:"minReplicas"`

	// MaxReplicas は最大レプリカ数。GPU費用の上限を制御するために必須
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:Minimum=1
	MaxReplicas int32 `json:"maxReplicas"`

	// ScalingMetric はオートスケーリングに使用するメトリクス設定
	// +kubebuilder:validation:Required
	ScalingMetric ScalingMetric `json:"scalingMetric"`

	// BedrockFallback はGPUプロビジョニングタイムアウト時のフォールバック設定
	// +kubebuilder:validation:Optional
	BedrockFallback *BedrockFallback `json:"bedrockFallback,omitempty"`

	// SelfHealing はOOMKilled/CrashLoopBackOff自動回復の設定
	// +kubebuilder:validation:Optional
	SelfHealing *SelfHealing `json:"selfHealing,omitempty"`

	// Resources はvLLMコンテナのリソース要求・制限
	// nvidia.com/gpu limitを含めること(Admission Webhookで強制)
	// OOMKilled発生時にOperatorがmemory limitを段階的に引き上げる基準値になる
	// +kubebuilder:validation:Optional
	Resources *corev1.ResourceRequirements `json:"resources,omitempty"`
}

// AIInferenceServiceStatus はAIInferenceServiceの観測状態を定義する
type AIInferenceServiceStatus struct {
	// Phase はサービスの現在のライフサイクルフェーズ
	// +kubebuilder:validation:Optional
	Phase InferencePhase `json:"phase,omitempty"`

	// Conditions はKubernetes標準のcondition patternに従う詳細状態リスト
	// Ready / Scaled / Fallback / SelfHealed の各conditionを持つ
	// +listType=map
	// +listMapKey=type
	// +kubebuilder:validation:Optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`

	// LastScaleTime は直近のスケーリング操作が完了した時刻
	// +kubebuilder:validation:Optional
	LastScaleTime *metav1.Time `json:"lastScaleTime,omitempty"`

	// ActiveBackend は現在推論を処理しているバックエンド(gpu or bedrock)
	// +kubebuilder:validation:Optional
	ActiveBackend ActiveBackend `json:"activeBackend,omitempty"`

	// ReadyReplicas は現在Readyなvllmレプリカ数
	// +kubebuilder:validation:Optional
	ReadyReplicas int32 `json:"readyReplicas,omitempty"`

	// RestartCount は自己修復による累計再起動回数
	// +kubebuilder:validation:Optional
	RestartCount int32 `json:"restartCount,omitempty"`
}

// AIInferenceService はAI推論ワークロードのライフサイクル全体を管理するCRD
//
// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:shortName=ais
// +kubebuilder:printcolumn:name="Phase",type="string",JSONPath=".status.phase"
// +kubebuilder:printcolumn:name="Backend",type="string",JSONPath=".status.activeBackend"
// +kubebuilder:printcolumn:name="Ready",type="integer",JSONPath=".status.readyReplicas"
// +kubebuilder:printcolumn:name="Age",type="date",JSONPath=".metadata.creationTimestamp"
type AIInferenceService struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   AIInferenceServiceSpec   `json:"spec,omitempty"`
	Status AIInferenceServiceStatus `json:"status,omitempty"`
}

// AIInferenceServiceList はAIInferenceServiceのリスト型
// +kubebuilder:object:root=true
type AIInferenceServiceList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []AIInferenceService `json:"items"`
}

func init() {
	SchemeBuilder.Register(&AIInferenceService{}, &AIInferenceServiceList{})
}
