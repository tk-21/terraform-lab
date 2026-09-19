## Operator開発用Makefile
## kubebuilder標準ターゲットに準拠しつつ、arm64ビルドとKindローカル開発を追加

# Go設定
GOARCH ?= arm64
GOOS ?= linux

# コンテナイメージ設定
IMG ?= gpu-inference-operator:latest
PLATFORMS ?= linux/arm64

# ツールバイナリのインストール先
LOCALBIN ?= $(shell pwd)/bin
CONTROLLER_GEN ?= $(LOCALBIN)/controller-gen
KUSTOMIZE ?= $(LOCALBIN)/kustomize

## help: ヘルプを表示する
.PHONY: help
help: ## このヘルプを表示する
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

##@ 開発

.PHONY: fmt
fmt: ## go fmt でコードをフォーマットする
	go fmt ./...

.PHONY: vet
vet: ## go vet で静的解析を実行する
	go vet ./...

.PHONY: test
test: manifests generate fmt vet ## ユニットテストを実行する (envtest使用)
	go test ./... -coverprofile cover.out

##@ ビルド

.PHONY: build
build: manifests generate fmt vet ## Operatorバイナリをビルドする
	GOARCH=$(GOARCH) GOOS=$(GOOS) go build -o bin/manager main.go

.PHONY: run
run: manifests generate fmt vet ## ローカルでOperatorを実行する (Kind接続)
	go run ./main.go

.PHONY: docker-build
docker-build: ## Dockerイメージをビルドする (arm64)
	docker buildx build --platform $(PLATFORMS) -t $(IMG) .

##@ Kubernetes マニフェスト生成

.PHONY: manifests
manifests: controller-gen ## CRD/RBAC/WebhookマニフェストをGoマーカーから生成する
	$(CONTROLLER_GEN) rbac:roleName=manager-role crd webhook paths="./..." output:crd:artifacts:config=config/crd/bases

.PHONY: generate
generate: controller-gen ## zz_generated.deepcopy.go を再生成する
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

.PHONY: install
install: manifests kustomize ## CRDをクラスタ(Kind/EKS)にインストールする
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

.PHONY: uninstall
uninstall: manifests kustomize ## CRDをクラスタから削除する
	$(KUSTOMIZE) build config/crd | kubectl delete --ignore-not-found=true -f -

.PHONY: deploy
deploy: manifests kustomize ## OperatorをKindクラスタにデプロイする
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(IMG)
	$(KUSTOMIZE) build config/default | kubectl apply -f -

.PHONY: undeploy
undeploy: kustomize ## Operatorをクラスタから削除する
	$(KUSTOMIZE) build config/default | kubectl delete --ignore-not-found=true -f -

##@ Kind ローカル開発

.PHONY: kind-create
kind-create: ## Kindクラスタを作成する
	kind create cluster --config kind-config.yaml --name gpu-inference-operator

.PHONY: kind-delete
kind-delete: ## Kindクラスタを削除する
	kind delete cluster --name gpu-inference-operator

.PHONY: kind-load
kind-load: docker-build ## DockerイメージをKindクラスタにロードする
	kind load docker-image $(IMG) --name gpu-inference-operator

##@ ツールインストール

$(LOCALBIN):
	mkdir -p $(LOCALBIN)

SETUP_ENVTEST ?= $(LOCALBIN)/setup-envtest
# envtest は KUBEBUILDER_ASSETS 環境変数が指すディレクトリのetcd/kube-apiserverを使う
ENVTEST_K8S_VERSION ?= 1.31.0

.PHONY: envtest
envtest: $(SETUP_ENVTEST) ## envtest用バイナリをダウンロードしてKUBEBUILDER_ASSETSを設定する
$(SETUP_ENVTEST): $(LOCALBIN)
	GOBIN=$(LOCALBIN) go install sigs.k8s.io/controller-runtime/tools/setup-envtest@latest

.PHONY: test
test: manifests generate fmt vet envtest ## ユニットテストを実行する (envtest使用)
	KUBEBUILDER_ASSETS="$(shell $(SETUP_ENVTEST) use $(ENVTEST_K8S_VERSION) --bin-path $(LOCALBIN)/k8s -p path)" \
		go test ./... -coverprofile cover.out

.PHONY: controller-gen
controller-gen: $(CONTROLLER_GEN)
$(CONTROLLER_GEN): $(LOCALBIN)
	GOBIN=$(LOCALBIN) go install sigs.k8s.io/controller-tools/cmd/controller-gen@latest

.PHONY: kustomize
kustomize: $(KUSTOMIZE)
$(KUSTOMIZE): $(LOCALBIN)
	GOBIN=$(LOCALBIN) go install sigs.k8s.io/kustomize/kustomize/v5@latest
