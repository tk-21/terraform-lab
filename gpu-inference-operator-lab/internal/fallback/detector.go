// Package fallback はGPUプロビジョニングのタイムアウト監視とBedrockフォールバック判定を提供する
//
// 設計方針: Detector は状態を読み取るだけの純粋関数として実装する。
// アノテーションの書き込みやKubernetes APIの呼び出しはコントローラーに委譲することで、
// テスト時にfake clientを使わずに単体テストが書ける。
package fallback

import (
	"fmt"
	"time"

	inferencev1alpha1 "github.com/takuya/gpu-inference-operator-lab/api/v1alpha1"
)

const (
	// AnnotationProvisioningStart はGPUプロビジョニング開始時刻を記録するアノテーション
	// KubernetesのPod Eventsは保持期間が短く(デフォルト1時間)Operator再起動後に消失する。
	// アノテーションはetcdに永続化されるため、Operator再起動後も正確な経過時間を計算できる。
	AnnotationProvisioningStart = "inference.takuya.dev/provisioning-start-time"

	// DefaultGPUProvisionTimeout はBedrockフォールバックまでのデフォルト待機時間
	// g5gノードのコールドスタート実測値は3〜5分(Karpenter NodeClaimが承認されてからEKS NodeがReady)。
	// 90秒はノード起動完了より短いが、ユーザー体験を優先してフォールバックを早めに発動する設計。
	// spec.bedrockFallback.gpuProvisionTimeoutSecondsで上書き可能。
	DefaultGPUProvisionTimeout = 90 * time.Second
)

// Decision はフォールバック判定の結果を保持する
type Decision struct {
	// ShouldFallback はBedrockへ切り替えるべきかどうか
	ShouldFallback bool

	// ShouldRecover はGPUノードが起動完了してBedrockからGPUへ戻すべきかどうか
	ShouldRecover bool

	// NeedsAnnotation はコントローラーがプロビジョニング開始時刻アノテーションを設定すべきかどうか
	// 初めてProvisioning状態を検知したサイクルでtrueになる
	NeedsAnnotation bool

	// ClearAnnotation はコントローラーがプロビジョニング開始時刻アノテーションをクリアすべきかどうか
	// GPUが復帰したサイクルでtrueになる
	ClearAnnotation bool

	// ProvisioningElapsed はGPUプロビジョニング開始からの経過時間
	ProvisioningElapsed time.Duration

	// Reason は判定理由(ログ・Conditionへの記録用)
	Reason string
}

// Detector はGPUプロビジョニング状態を監視してフォールバック判定を行う
// client.Clientへの依存がないため、fake clientなしで単体テスト可能
type Detector struct{}

// NewDetector はDetectorを返す
func NewDetector() *Detector {
	return &Detector{}
}

// Evaluate はAIInferenceServiceの現在状態からフォールバック判定を行う
//
// 判定に使うシグナル:
//  1. readyReplicas == 0: GPUノードが未起動または起動中
//  2. AnnotationProvisioningStart: プロビジョニング開始時刻(Operatorが記録)
//  3. spec.bedrockFallback.gpuProvisionTimeoutSeconds: タイムアウト閾値
//
// なぜKarpenter NodeClaim statusを直接見ないか:
//
//	NodeClaim の provisioningDuration フィールドはKarpenter v0.33以降で変更されており
//	APIが安定していない。PendingPod + タイムアウト閾値の組み合わせの方がシンプルで堅牢。
//	また、NodeClaimのwatch権限を増やさずに済む。
func (d *Detector) Evaluate(
	ais *inferencev1alpha1.AIInferenceService,
	readyReplicas int32,
) Decision {
	cfg := ais.Spec.BedrockFallback
	if cfg == nil || !cfg.Enabled {
		return Decision{Reason: "bedrockFallback is disabled or not configured"}
	}

	timeout := timeoutDuration(cfg)
	_, hasAnnotation := ais.Annotations[AnnotationProvisioningStart]

	// GPUが稼働中(readyReplicas > 0)の場合
	if readyReplicas > 0 {
		if hasAnnotation {
			// アノテーションが残っている = フォールバックから復帰した
			if ais.Status.ActiveBackend == inferencev1alpha1.BackendBedrock {
				return Decision{
					ShouldRecover:   true,
					ClearAnnotation: true,
					Reason:          "GPU pods are ready, initiating traffic return from Bedrock to GPU",
				}
			}
			// フォールバックしていないがアノテーションが残っている(例: Operator再起動)
			return Decision{
				ClearAnnotation: true,
				Reason:          "GPU running normally, clearing stale provisioning annotation",
			}
		}
		return Decision{Reason: "GPU running normally"}
	}

	// readyReplicas == 0: GPUが起動していない
	if !hasAnnotation {
		// 初めてProvisioning状態を検知 → アノテーション設定を要求する
		return Decision{
			NeedsAnnotation: true,
			Reason:          "GPU pods not ready, started tracking provisioning time",
		}
	}

	// アノテーション有り: 経過時間を計算してタイムアウト判定
	startStr := ais.Annotations[AnnotationProvisioningStart]
	startTime, err := time.Parse(time.RFC3339, startStr)
	if err != nil {
		// パース失敗 = アノテーションが壊れている → リセットして再計測
		return Decision{
			NeedsAnnotation: true,
			ClearAnnotation: true,
			Reason:          fmt.Sprintf("malformed provisioning annotation %q, resetting", startStr),
		}
	}

	elapsed := time.Since(startTime)

	if elapsed >= timeout {
		return Decision{
			ShouldFallback:      true,
			ProvisioningElapsed: elapsed,
			Reason: fmt.Sprintf(
				"GPU provisioning timed out: elapsed=%s, threshold=%s",
				elapsed.Round(time.Second).String(),
				timeout.String(),
			),
		}
	}

	return Decision{
		ProvisioningElapsed: elapsed,
		Reason: fmt.Sprintf(
			"waiting for GPU provisioning: elapsed=%s / threshold=%s",
			elapsed.Round(time.Second).String(),
			timeout.String(),
		),
	}
}

// timeoutDuration はBedrockFallback設定からtime.Durationに変換する
func timeoutDuration(cfg *inferencev1alpha1.BedrockFallback) time.Duration {
	if cfg.GPUProvisionTimeoutSeconds > 0 {
		return time.Duration(cfg.GPUProvisionTimeoutSeconds) * time.Second
	}
	return DefaultGPUProvisionTimeout
}
