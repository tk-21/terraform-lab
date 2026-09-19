// Package notify はOperatorイベントをChatwork APIに通知する機能を提供する
//
// CLAUDE.md制約:
//   POST /v2/rooms/{room_id}/messages
//   Header: X-ChatWorkToken
//   Content-Type: application/x-www-form-urlencoded
package notify

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

// ChatworkNotifier はChatwork APIへのOperatorイベント通知を担う
type ChatworkNotifier struct {
	token      string
	roomID     string
	httpClient *http.Client
}

// NewChatworkNotifier は環境変数からトークン・ルームIDを読み込んでNotifierを初期化する
// 環境変数: CHATWORK_API_TOKEN / CHATWORK_ROOM_ID
// シークレットはSSM Parameter Store → Kubernetes Secret → 環境変数の順で注入する(CLAUDE.md制約)
func NewChatworkNotifier() *ChatworkNotifier {
	return &ChatworkNotifier{
		token:  os.Getenv("CHATWORK_API_TOKEN"),
		roomID: os.Getenv("CHATWORK_ROOM_ID"),
		// Chatwork APIは国内DCのため10秒で十分
		httpClient: &http.Client{Timeout: 10 * time.Second},
	}
}

// Enabled はChatwork通知が設定済みかどうかを返す
// トークンまたはルームIDが未設定の場合はノーオペレーションにする
func (n *ChatworkNotifier) Enabled() bool {
	return n.token != "" && n.roomID != ""
}

// NotifyFallbackActivated はBedrockフォールバック発動時に通知する
func (n *ChatworkNotifier) NotifyFallbackActivated(
	ctx context.Context,
	serviceName, namespace string,
	elapsed time.Duration,
) error {
	msg := fmt.Sprintf(
		"[info][title]⚠️ GPU→Bedrock フォールバック発動[/title]"+
			"Service: %s / Namespace: %s\n"+
			"GPUプロビジョニングが %s 経過してタイムアウトしました。\n"+
			"Amazon Bedrockへのトラフィック切り替えを実行します。\n"+
			"発生時刻: %s[/info]",
		serviceName, namespace,
		elapsed.Round(time.Second).String(),
		time.Now().Format(time.RFC3339),
	)
	return n.send(ctx, msg)
}

// NotifyFallbackRecovered はGPUノード復帰・Bedrockからの切り戻し完了時に通知する
func (n *ChatworkNotifier) NotifyFallbackRecovered(
	ctx context.Context,
	serviceName, namespace string,
) error {
	msg := fmt.Sprintf(
		"[info][title]✅ Bedrock→GPU 復帰完了[/title]"+
			"Service: %s / Namespace: %s\n"+
			"GPUノードの起動を確認しました。トラフィックをGPUに戻します。\n"+
			"復帰時刻: %s[/info]",
		serviceName, namespace,
		time.Now().Format(time.RFC3339),
	)
	return n.send(ctx, msg)
}

// NotifyDegraded は自己修復試行上限に達して手動介入が必要になった際に通知する
func (n *ChatworkNotifier) NotifyDegraded(
	ctx context.Context,
	serviceName, namespace, reason string,
) error {
	msg := fmt.Sprintf(
		"[info][title]🚨 推論サービス Degraded — 手動介入が必要です[/title]"+
			"Service: %s / Namespace: %s\n"+
			"自己修復の試行回数が上限に達しました。自動修復を停止します。\n"+
			"原因: %s\n"+
			"対応: `kubectl describe ais %s -n %s` でConditionを確認してください。\n"+
			"発生時刻: %s[/info]",
		serviceName, namespace,
		reason,
		serviceName, namespace,
		time.Now().Format(time.RFC3339),
	)
	return n.send(ctx, msg)
}

// NotifyCrashLoop はCrashLoopBackOff検知時に直近ログを添えて通知する
func (n *ChatworkNotifier) NotifyCrashLoop(
	ctx context.Context,
	serviceName, namespace, podName, terminationMessage string,
) error {
	msg := fmt.Sprintf(
		"[info][title]⚠️ CrashLoopBackOff 検知[/title]"+
			"Service: %s / Namespace: %s / Pod: %s\n"+
			"コンテナが繰り返しクラッシュしています。\n"+
			"最終終了メッセージ: %s\n"+
			"調査: `kubectl logs %s -n %s --previous` でスタックトレースを確認してください。\n"+
			"発生時刻: %s[/info]",
		serviceName, namespace, podName,
		terminationMessage,
		podName, namespace,
		time.Now().Format(time.RFC3339),
	)
	return n.send(ctx, msg)
}

// send はChatwork API POST /v2/rooms/{room_id}/messages を呼び出す
func (n *ChatworkNotifier) send(ctx context.Context, body string) error {
	if !n.Enabled() {
		return nil
	}

	endpoint := fmt.Sprintf("https://api.chatwork.com/v2/rooms/%s/messages", n.roomID)

	req, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		endpoint,
		strings.NewReader(url.Values{"body": {body}}.Encode()),
	)
	if err != nil {
		return fmt.Errorf("building chatwork request: %w", err)
	}
	req.Header.Set("X-ChatWorkToken", n.token)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := n.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("sending chatwork notification: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("chatwork API returned unexpected status %d", resp.StatusCode)
	}
	return nil
}
