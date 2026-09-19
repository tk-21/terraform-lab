// Package e2e_test はKindクラスタを使ったE2Eテストを提供する。
// envtest(インプロセス)とは異なり、実際のKubernetesクラスタに対してOperatorを実行する。
//
// 前提条件:
//   - KUBECONFIGが設定されたKindクラスタが起動済みであること
//   - CRDが kubectl apply -f config/crd/bases/ で適用済みであること
//   - Operatorバイナリが --enable-webhooks=false --leader-elect=false で別プロセス起動済みであること
//
// GPU依存部分のモック化方針:
//   - BedrockFallback.Enabled=false でAWS APIへの接続を回避する
//   - ScalingMetric.PrometheusURL を空にしてDCGM Exporterへの接続を回避する
//   - GPUプロビジョニング(Karpenter NodePool)は実際にNodeを起動しない
//   - SKIP_GPU_TESTS=true の場合、GPU依存のアサーションをスキップする
package e2e_test

import (
	"context"
	"os"
	"testing"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/clientcmd"
	"sigs.k8s.io/controller-runtime/pkg/client"

	inferencev1alpha1 "github.com/takuya/gpu-inference-operator-lab/api/v1alpha1"
)

var (
	k8sClient   client.Client
	testCtx     context.Context
	testCancel  context.CancelFunc
	skipGPU     bool
	testTimeout = 2 * time.Minute
)

func TestMain(m *testing.M) {
	testCtx, testCancel = context.WithCancel(context.Background())
	defer testCancel()

	skipGPU = os.Getenv("SKIP_GPU_TESTS") == "true"

	// KUBECONFIGからKindクラスタへの接続設定を読み込む
	kubeconfig := os.Getenv("KUBECONFIG")
	if kubeconfig == "" {
		home, _ := os.UserHomeDir()
		kubeconfig = home + "/.kube/config"
	}

	cfg, err := clientcmd.BuildConfigFromFlags("", kubeconfig)
	if err != nil {
		panic("KUBECONFIGが設定されていないかKindクラスタに接続できません: " + err.Error())
	}

	// テスト用スキームにCRDとコアAPIを登録する
	scheme := runtime.NewScheme()
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(appsv1.AddToScheme(scheme))
	utilruntime.Must(corev1.AddToScheme(scheme))
	utilruntime.Must(inferencev1alpha1.AddToScheme(scheme))

	k8sClient, err = client.New(cfg, client.Options{Scheme: scheme})
	if err != nil {
		panic("Kubernetes clientの作成に失敗しました: " + err.Error())
	}

	os.Exit(m.Run())
}
