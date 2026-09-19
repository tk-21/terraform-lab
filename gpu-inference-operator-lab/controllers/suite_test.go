// Package controllers_test はenvtestを使ったコントローラーの統合テストスイートを定義する
// テスト実行前に `make envtest` でKubebuilder binaries をダウンロードし、
// KUBEBUILDER_ASSETS 環境変数を設定すること
package controllers_test

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	k8sruntime "k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/rest"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"

	inferencev1alpha1 "github.com/takuya/gpu-inference-operator-lab/api/v1alpha1"
	"github.com/takuya/gpu-inference-operator-lab/controllers"
)

var (
	cfg       *rest.Config
	k8sClient client.Client
	testEnv   *envtest.Environment
	testCtx   context.Context
	testCancel context.CancelFunc
	scheme    *k8sruntime.Scheme
)

// TestMain はenvtestのライフサイクル全体を管理する
// 各テストが独立したリソース名を使う前提で、1つのmanagerを全テスト共通で起動する
func TestMain(m *testing.M) {
	ctrl.SetLogger(zap.New(zap.UseDevMode(true)))
	testCtx, testCancel = context.WithCancel(context.Background())

	// CRDはcontroller-genが生成するYAMLを使う
	// make manifests でconfig/crd/basesを生成してからテストを実行すること
	testEnv = &envtest.Environment{
		CRDDirectoryPaths:     []string{filepath.Join("..", "config", "crd", "bases")},
		ErrorIfCRDPathMissing: true,
	}

	scheme = k8sruntime.NewScheme()
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(appsv1.AddToScheme(scheme))
	utilruntime.Must(corev1.AddToScheme(scheme))
	utilruntime.Must(inferencev1alpha1.AddToScheme(scheme))

	var err error
	cfg, err = testEnv.Start()
	if err != nil {
		panic("failed to start testenv: " + err.Error())
	}

	k8sClient, err = client.New(cfg, client.Options{Scheme: scheme})
	if err != nil {
		panic("failed to create client: " + err.Error())
	}

	// Managerを起動してreconcileループを動かす
	mgr, err := ctrl.NewManager(cfg, ctrl.Options{
		Scheme: scheme,
		// テスト時はleader electionを無効化する(テスト内でリーダー競合が起きないようにするため)
		LeaderElection:         false,
		MetricsBindAddress:     "0",
		HealthProbeBindAddress: "0",
	})
	if err != nil {
		panic("failed to create manager: " + err.Error())
	}

	if err := (&controllers.AIInferenceServiceReconciler{
		Client: mgr.GetClient(),
		Log:    ctrl.Log.WithName("test-controller"),
		Scheme: mgr.GetScheme(),
	}).SetupWithManager(mgr); err != nil {
		panic("failed to setup reconciler: " + err.Error())
	}

	go func() {
		if err := mgr.Start(testCtx); err != nil {
			panic("manager exited with error: " + err.Error())
		}
	}()

	code := m.Run()

	testCancel()
	if err := testEnv.Stop(); err != nil {
		panic("failed to stop testenv: " + err.Error())
	}
	os.Exit(code)
}
