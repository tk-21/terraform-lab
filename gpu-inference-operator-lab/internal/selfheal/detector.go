// Package selfheal はPodのOOMKilled/CrashLoopBackOffを検知して修復アクションを決定する
//
// 設計方針: Detector は状態を読み取るだけの純粋関数として実装する。
// DeploymentへのPatch・Kubernetes Eventの書き込みはコントローラーに委譲することで、
// fake clientなしで単体テストが書ける(fallback.Detectorと同じパターン)。
package selfheal

import (
	"fmt"
	"strings"

	corev1 "k8s.io/api/core/v1"

	inferencev1alpha1 "github.com/takuya/gpu-inference-operator-lab/api/v1alpha1"
)

const (
	// DefaultMaxRestartAttempts は設定がない場合のデフォルト自己修復試行回数
	// 3回にした理由: 1回はハードウェアノイズ・2回は一過性OOM・3回超は設定/モデルの問題と判断できる
	DefaultMaxRestartAttempts int32 = 3

	// MemoryBumpPercent はOOMKilled時にmemory limitを引き上げる割合(%)
	// 一度に2倍にすると他のPodを圧迫するため25%ずつ段階的に引き上げる設計
	MemoryBumpPercent int64 = 25

	// DefaultInitialMemoryMi はResources未設定のPodにOOMが発生した場合の初期メモリ割り当て(Mi)
	// vLLM + 7Bモデルのメモリ要求実測値を元にした最小値
	DefaultInitialMemoryMi int64 = 8192
)

// FailureMode は検知された障害の種類
type FailureMode string

const (
	FailureNone      FailureMode = ""
	FailureOOMKilled FailureMode = "OOMKilled"
	FailureCrashLoop FailureMode = "CrashLoopBackOff"
)

// PodHealth はコントローラーが収集したPodの障害情報を保持する
// DetectorがKubernetes APIを直接呼ばないためにこの構造体を経由して渡す
type PodHealth struct {
	// FailureMode は検知された障害種別
	FailureMode FailureMode

	// CurrentRestartCount は障害Podの現在のrestartCount(累計)
	CurrentRestartCount int32

	// LastTerminationMessage は最後のコンテナ終了メッセージ(Event記録・通知用)
	LastTerminationMessage string

	// PodName は障害が発生したPod名(通知・Event記録用)
	PodName string
}

// Decision は自己修復の判定結果
type Decision struct {
	// ShouldBumpMemory はOOMKilledへの対応としてDeploymentのmemory limitを引き上げるべきか
	// 単純再起動では同じメモリでまたOOMになるため、limitの変更を先に行う
	ShouldBumpMemory bool

	// ShouldRecordEvent はCrashLoopBackOff発生をKubernetes Eventとして記録するか
	ShouldRecordEvent bool

	// ShouldDegrade はmaxRestartAttemptsを超えたためPhaseDegradedに遷移すべきか
	// Degraded後は自動修復を停止してChatworkに人間向けアラートを送る
	ShouldDegrade bool

	// FailureMode は今回のReconcileで検知された障害種別
	FailureMode FailureMode

	// Reason は判定理由(log・Condition・Event用)
	Reason string

	// PodName は障害が発生したPod名
	PodName string
}

// Detector はPodの障害を検知して修復アクションを決定する
// client.Clientへの依存がないため、fake clientなしで単体テスト可能
type Detector struct{}

// NewDetector はDetectorを返す
func NewDetector() *Detector {
	return &Detector{}
}

// Evaluate はAIInferenceServiceとPod健全性情報から自己修復判定を行う
//
// 修復の範囲を意図的に絞った理由:
//
//	無限リトライを許容するとAPIサーバーへの書き込み負荷・GPU費用の暴走が起きる。
//	根本原因が設定ミスや不正なモデルファイルの場合は再起動では解決しない。
//	maxRestartAttempts超過後はPhaseDegradedにして必ず人間が確認するフローを強制する。
func (d *Detector) Evaluate(
	ais *inferencev1alpha1.AIInferenceService,
	health PodHealth,
) Decision {
	if health.FailureMode == FailureNone {
		return Decision{Reason: "no failure detected"}
	}

	cfg := ais.Spec.SelfHealing
	// selfHealingが未設定またはrestartOnOOM=falseの場合はEventのみ記録して終了
	if cfg == nil || !cfg.RestartOnOOM {
		return Decision{
			FailureMode:       health.FailureMode,
			ShouldRecordEvent: true,
			PodName:           health.PodName,
			Reason: fmt.Sprintf(
				"selfHealing.restartOnOOM is disabled, recording event only: %s on pod %s",
				health.FailureMode, health.PodName,
			),
		}
	}

	maxAttempts := effectiveMaxRestartAttempts(cfg)
	currentAttempts := ais.Status.RestartCount

	// maxRestartAttemptsに達していたらDegradedへ遷移して修復を停止する
	// なぜ上限を設けるか:
	//   根本原因が設定ミスやモデルバグの場合、無限再起動はコストを垂れ流し続ける。
	//   上限後は人間が確認するフローを強制することで問題の見逃しを防ぐ。
	if currentAttempts >= maxAttempts {
		return Decision{
			ShouldDegrade: true,
			FailureMode:   health.FailureMode,
			PodName:       health.PodName,
			Reason: fmt.Sprintf(
				"maxRestartAttempts(%d) exceeded (current=%d), transitioning to Degraded — manual intervention required",
				maxAttempts, currentAttempts,
			),
		}
	}

	switch health.FailureMode {
	case FailureOOMKilled:
		// OOMKilledは単純再起動では解決しない(同じメモリ量でまたOOMになる)
		// memory limitを段階的に引き上げてからDeploymentを更新することで根本対処する
		return Decision{
			ShouldBumpMemory: true,
			FailureMode:      FailureOOMKilled,
			PodName:          health.PodName,
			Reason: fmt.Sprintf(
				"OOMKilled detected on pod %s (attempt %d/%d), bumping memory limit by %d%%",
				health.PodName, currentAttempts+1, maxAttempts, MemoryBumpPercent,
			),
		}

	case FailureCrashLoop:
		// CrashLoopBackOff: ログをKubernetes Eventに残してChatworkに通知する
		// OOMと違いメモリ量の問題ではないため、Eventで証跡を残し人間に調査を促す
		return Decision{
			ShouldRecordEvent: true,
			FailureMode:       FailureCrashLoop,
			PodName:           health.PodName,
			Reason: fmt.Sprintf(
				"CrashLoopBackOff on pod %s (attempt %d/%d): %s",
				health.PodName, currentAttempts+1, maxAttempts, truncate(health.LastTerminationMessage, 200),
			),
		}
	}

	return Decision{Reason: fmt.Sprintf("unknown failure mode: %s", health.FailureMode)}
}

// InspectPods はPodリストからOOMKilled/CrashLoopBackOffを検知してPodHealthを返す
// コントローラーがKubernetes APIからPodリストを取得した後にこの関数を呼ぶ
func InspectPods(pods []corev1.Pod) PodHealth {
	for _, pod := range pods {
		for _, cs := range pod.Status.ContainerStatuses {
			// 現在OOMKilledで終了しているコンテナを最優先で検知する
			if cs.State.Terminated != nil && cs.State.Terminated.Reason == "OOMKilled" {
				return PodHealth{
					FailureMode:            FailureOOMKilled,
					CurrentRestartCount:    cs.RestartCount,
					LastTerminationMessage: cs.State.Terminated.Message,
					PodName:               pod.Name,
				}
			}

			// 直前の実行でOOMKilledになっていたコンテナ(現在はCrashLoopのBackoff待ち中など)
			if cs.LastTerminationState.Terminated != nil &&
				cs.LastTerminationState.Terminated.Reason == "OOMKilled" {
				return PodHealth{
					FailureMode:            FailureOOMKilled,
					CurrentRestartCount:    cs.RestartCount,
					LastTerminationMessage: cs.LastTerminationState.Terminated.Message,
					PodName:               pod.Name,
				}
			}

			// CrashLoopBackOffはWaiting stateで検知する
			if cs.State.Waiting != nil &&
				strings.Contains(cs.State.Waiting.Reason, "CrashLoopBackOff") {
				msg := "no termination message available"
				if cs.LastTerminationState.Terminated != nil {
					msg = cs.LastTerminationState.Terminated.Message
				}
				return PodHealth{
					FailureMode:            FailureCrashLoop,
					CurrentRestartCount:    cs.RestartCount,
					LastTerminationMessage: msg,
					PodName:               pod.Name,
				}
			}
		}
	}

	return PodHealth{FailureMode: FailureNone}
}

// effectiveMaxRestartAttempts はSelfHealing設定からmaxRestartAttemptsを取得する
func effectiveMaxRestartAttempts(cfg *inferencev1alpha1.SelfHealing) int32 {
	if cfg.MaxRestartAttempts > 0 {
		return cfg.MaxRestartAttempts
	}
	return DefaultMaxRestartAttempts
}

// truncate は文字列をmaxLen文字以下に切り詰める(Event messageの長さ制限対策)
func truncate(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen] + "..."
}
