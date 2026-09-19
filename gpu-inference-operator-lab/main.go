// main.go はOperatorのエントリーポイント
// controller-runtimeのManagerを起動し、AIInferenceServiceのReconcilerを登録する
package main

import (
	"flag"
	"os"

	"go.uber.org/zap/zapcore"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"

	inferencev1alpha1 "github.com/takuya/gpu-inference-operator-lab/api/v1alpha1"
	"github.com/takuya/gpu-inference-operator-lab/controllers"
	"github.com/takuya/gpu-inference-operator-lab/internal/fallback"
	"github.com/takuya/gpu-inference-operator-lab/internal/notify"
	"github.com/takuya/gpu-inference-operator-lab/internal/selfheal"
	"github.com/takuya/gpu-inference-operator-lab/webhooks"
)

var (
	scheme   = runtime.NewScheme()
	setupLog = ctrl.Log.WithName("setup")
)

func init() {
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(appsv1.AddToScheme(scheme))
	utilruntime.Must(corev1.AddToScheme(scheme))
	utilruntime.Must(inferencev1alpha1.AddToScheme(scheme))
}

func main() {
	var metricsAddr string
	var enableLeaderElection bool
	var probeAddr string
	var enableWebhooks bool

	flag.StringVar(&metricsAddr, "metrics-bind-address", ":8080", "The address the metric endpoint binds to.")
	flag.StringVar(&probeAddr, "health-probe-bind-address", ":8081", "The address the probe endpoint binds to.")
	// cert-managerなしのKind環境やE2Eテストではwebhookサーバーを起動できないため
	// falseにするとwebhook登録をスキップしてOperatorのみ起動できる
	flag.BoolVar(&enableWebhooks, "enable-webhooks", true, "Enable admission webhooks. Set false for Kind/E2E without cert-manager.")
	// leader electionをデフォルトで有効化する理由:
	//   Operatorを複数レプリカ(HA)で動かした場合、leader electionがないと
	//   複数インスタンスが同じCRを同時にreconcileしてStatusの競合書き込みが発生する。
	//   etcdのCAS(Compare-And-Swap)がconflictエラーを返しても最終的には収束するが、
	//   フォールバック判定やself-healingカウンターの更新でrace conditionが起きうる。
	//   leader electionにより「1インスタンスだけがreconcileを実行」を保証する。
	flag.BoolVar(&enableLeaderElection, "leader-elect", true,
		"Enable leader election for controller manager. "+
			"Enabling this will ensure there is only one active controller manager.")
	flag.Parse()

	opts := zap.Options{
		Development: true,
		TimeEncoder: zapcore.ISO8601TimeEncoder,
	}
	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&opts)))

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme:                 scheme,
		MetricsBindAddress:     metricsAddr,
		Port:                   9443,
		HealthProbeBindAddress: probeAddr,
		LeaderElection:         enableLeaderElection,
		LeaderElectionID:       "gpu-inference-operator.takuya.dev",
	})
	if err != nil {
		setupLog.Error(err, "unable to start manager")
		os.Exit(1)
	}

	notifier := notify.NewChatworkNotifier()
	if notifier.Enabled() {
		setupLog.Info("Chatwork notifications enabled")
	} else {
		setupLog.Info("Chatwork notifications disabled (CHATWORK_API_TOKEN or CHATWORK_ROOM_ID not set)")
	}

	if err = (&controllers.AIInferenceServiceReconciler{
		Client:           mgr.GetClient(),
		Log:              ctrl.Log.WithName("controllers").WithName("AIInferenceService"),
		Scheme:           mgr.GetScheme(),
		Detector:         fallback.NewDetector(),
		SelfHealDetector: selfheal.NewDetector(),
		Notifier:         notifier,
	}).SetupWithManager(mgr); err != nil {
		setupLog.Error(err, "unable to create controller", "controller", "AIInferenceService")
		os.Exit(1)
	}

	// Admission Webhook登録
	// cert-manager が /tmp/k8s-webhook-server/serving-certs/ にTLS証明書を配置することを前提とする
	// ローカル開発時は kind-config.yaml に extraMounts でマウントするか
	// `make generate-certs` で自己署名証明書を生成する
	// --enable-webhooks=false でKind/E2E環境でもWebhookなしで起動できる
	if enableWebhooks {
		if err = (&webhooks.AIInferenceServiceWebhook{}).SetupWithManager(mgr); err != nil {
			setupLog.Error(err, "unable to set up webhook", "webhook", "AIInferenceService")
			os.Exit(1)
		}
	} else {
		setupLog.Info("webhooks disabled via --enable-webhooks=false")
	}

	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		setupLog.Error(err, "unable to set up health check")
		os.Exit(1)
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		setupLog.Error(err, "unable to set up ready check")
		os.Exit(1)
	}

	setupLog.Info("starting manager")
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		setupLog.Error(err, "problem running manager")
		os.Exit(1)
	}
}
