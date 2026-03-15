SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c

# ====== ここだけ環境に合わせて調整 ======
INFRA_TF_DIR    ?= infra/envs/dev
PLATFORM_TF_DIR ?= platform/envs/dev

APP_DEV         ?= apps/demo-web/overlays/dev
APP_BREAK_RDY   ?= apps/demo-web/overlays/dev-break-readiness
APP_BREAK_LIV   ?= apps/demo-web/overlays/dev-break-liveness
APP_PVC2        ?= apps/demo-web/overlays/dev-pvc2

NAMESPACE       ?= demo

CLUSTER         ?= eks-handson-dev
REGION          ?= ap-northeast-1

APP_LABEL_KEY   ?= app
APP_LABEL_VAL   ?= demo-web
DEPLOY_NAME     ?= demo-web
SERVICE_NAME    ?= demo-web
INGRESS_NAME    ?= demo-web

PVC_NAME        ?= demo-pvc
PVC2_NAME       ?= demo-pvc2
# =========================================

# ---------- helpers ----------
define hr
	echo "============================================================"
endef

.PHONY: help
help:
	@cat <<'EOF'
Targets (main):
	make tf-init          Terraform init (upgrade) for infra + platform
	make tf-apply         Terraform apply in correct order (infra -> kubeconfig -> platform)
	make destroy          Terraform destroy (platform -> infra)
	make kubeconfig       Update kubeconfig for kubectl
	make wait-core        Wait nodes ready (best effort)
	make wait-alb         Wait aws-load-balancer-controller webhook endpoints ready

App deploy / break / recover:
	make pvc-apply        Create PVC (demo-pvc) from APP_DEV/pvc.yaml
	make pvc2-apply       Create second PVC + switch deploy to it (overlay dev-pvc2)
	make app-apply        Apply app overlay (healthy)
	make app-break-rdy    Apply overlay that breaks readinessProbe
	make app-break-liv    Apply overlay that breaks livenessProbe
	make app-recover      Recover back to healthy overlay

Observation:
	make status           Show core resources status
	make obs-all          Run common observation set
	make obs-app          Deploy/Pod/RS + logs summary
	make obs-net          Service/Ingress/Endpoints + ingress details
	make obs-events       Recent events
	make obs-readiness    Focus: readiness failure symptoms
	make obs-liveness     Focus: crashloop symptoms
	make obs-storage      SC/PVC/PV/CSIDriver info
	make obs-pvc          Describe PVC and show PV/volumeHandle (best effort)

PVC workflow:
	make pvc-write        Write test data into /data/test.txt
	make pvc-recreate     Delete pods and confirm data persists
	make pvc-ebs          Show PV and EBS volume id (requires AWS CLI)

CSI add-on workflow (destructive):
	make csi-delete       Delete aws-ebs-csi-driver addon
	make csi-restore      Restore addon via Terraform apply (infra)

Examples:
	make tf-init tf-apply wait-core wait-alb
	make pvc-apply app-apply obs-all
	make app-break-rdy obs-readiness app-recover
	make app-break-liv obs-liveness app-recover
	make csi-delete pvc2-apply obs-pvc csi-restore pvc2-apply
	EOF

# ---------- Terraform (2-stage) ----------
.PHONY: tf-init
tf-init:
	$(call hr)
	echo "[TF] init infra"
	terraform -chdir=$(INFRA_TF_DIR) init -upgrade
	$(call hr)
	echo "[TF] init platform"
	terraform -chdir=$(PLATFORM_TF_DIR) init -upgrade

.PHONY: tf-apply
tf-apply:
	$(call hr)
	echo "[TF] apply infra (VPC/EKS/MNG/Add-ons)"
	terraform -chdir=$(INFRA_TF_DIR) apply
	$(call hr)
	echo "[KUBE] update kubeconfig"
	aws eks update-kubeconfig --region $(REGION) --name $(CLUSTER)
	$(call hr)
	echo "[TF] apply platform (ALB Controller / ArgoCD)"
	terraform -chdir=$(PLATFORM_TF_DIR) apply

.PHONY: destroy
destroy:
	$(call hr)
	echo "[TF] destroy platform first"
	terraform -chdir=$(PLATFORM_TF_DIR) destroy || (terraform -chdir=$(PLATFORM_TF_DIR) init -upgrade && terraform -chdir=$(PLATFORM_TF_DIR) destroy)
	$(call hr)
	echo "[TF] destroy infra last"
	terraform -chdir=$(INFRA_TF_DIR) destroy || (terraform -chdir=$(INFRA_TF_DIR) init -upgrade && terraform -chdir=$(INFRA_TF_DIR) destroy)

# ---------- kubectl / cluster ----------
.PHONY: kubeconfig
kubeconfig:
	aws eks update-kubeconfig --region $(REGION) --name $(CLUSTER)

.PHONY: wait-core
wait-core:
	$(call hr)
	echo "[WAIT] nodes Ready (best effort)"
	kubectl get nodes -o wide || true
	kubectl wait --for=condition=Ready nodes --all --timeout=10m || true

.PHONY: wait-alb
wait-alb:
	$(call hr)
	echo "[WAIT] aws-load-balancer-controller rollout + webhook endpoints"
	kubectl -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=10m
	for i in $$(seq 1 60); do \
	  EP=$$(kubectl -n kube-system get endpoints aws-load-balancer-webhook-service -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true); \
	  if [[ -n "$$EP" ]]; then echo "webhook endpoints ready: $$EP"; exit 0; fi; \
	  echo "waiting webhook endpoints... ($$i/60)"; sleep 5; \
	done; \
	echo "webhook endpoints not ready (timeout)"; exit 1

.PHONY: status
status:
	$(call hr)
	kubectl get ns | egrep '^(NAME|$(NAMESPACE)|kube-system|argocd)' || true
	$(call hr)
	kubectl -n $(NAMESPACE) get deploy,rs,pod -o wide || true
	$(call hr)
	kubectl -n $(NAMESPACE) get svc,ingress,endpoints -o wide || true
	$(call hr)
	kubectl -n $(NAMESPACE) get pvc,pv -o wide || true

# ---------- app (kustomize overlays) ----------
.PHONY: app-apply
app-apply:
	kubectl apply -k $(APP_DEV)
	kubectl -n $(NAMESPACE) rollout status deploy/$(DEPLOY_NAME) --timeout=5m

.PHONY: app-break-rdy
app-break-rdy:
	kubectl apply -k $(APP_BREAK_RDY)
	kubectl -n $(NAMESPACE) rollout status deploy/$(DEPLOY_NAME) --timeout=5m || true

.PHONY: app-break-liv
app-break-liv:
	kubectl apply -k $(APP_BREAK_LIV)
	echo "Tip: watch pods with: kubectl -n $(NAMESPACE) get pod -w"

.PHONY: app-recover
app-recover:
	kubectl apply -k $(APP_DEV)
	kubectl -n $(NAMESPACE) rollout status deploy/$(DEPLOY_NAME) --timeout=5m

# ---------- PVC / EBS ----------
.PHONY: pvc-apply
pvc-apply:
	test -f "$(APP_DEV)/pvc.yaml"
	kubectl apply -f $(APP_DEV)/pvc.yaml
	kubectl -n $(NAMESPACE) get pvc,pv -o wide

.PHONY: pvc2-apply
pvc2-apply:
	kubectl apply -k $(APP_PVC2)
	kubectl -n $(NAMESPACE) rollout status deploy/$(DEPLOY_NAME) --timeout=5m || true
	kubectl -n $(NAMESPACE) get pvc,pv,pod -o wide

.PHONY: pvc-write
pvc-write:
	kubectl -n $(NAMESPACE) exec -it deploy/$(DEPLOY_NAME) -- sh -lc 'mkdir -p /data; echo "hello ebs $$(date)" >> /data/test.txt; tail -n 5 /data/test.txt'

.PHONY: pvc-recreate
pvc-recreate:
	kubectl -n $(NAMESPACE) delete pod -l $(APP_LABEL_KEY)=$(APP_LABEL_VAL)
	kubectl -n $(NAMESPACE) rollout status deploy/$(DEPLOY_NAME) --timeout=5m
	kubectl -n $(NAMESPACE) exec -it deploy/$(DEPLOY_NAME) -- sh -lc 'tail -n 5 /data/test.txt'

.PHONY: pvc-ebs
pvc-ebs:
	PV=$$(kubectl -n $(NAMESPACE) get pvc $(PVC_NAME) -o jsonpath='{.spec.volumeName}'); \
	echo "PV=$$PV"; \
	VOL=$$(kubectl get pv "$$PV" -o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null || true); \
	if [[ -z "$$VOL" ]]; then \
	  echo "volumeHandle not found (maybe in-tree awsElasticBlockStore PV?)"; \
	  kubectl get pv "$$PV" -o yaml | egrep -n 'awsElasticBlockStore:|csi:|volumeHandle:|fsType:' -n -A3 || true; \
	  exit 0; \
	fi; \
	echo "EBS VolumeID=$$VOL"; \
	aws ec2 describe-volumes --volume-ids "$$VOL" --region $(REGION) \
	  --query 'Volumes[0].{VolumeId:VolumeId,State:State,Size:Size,Az:AvailabilityZone,Attachments:Attachments}' \
	  --output table

# ---------- CSI addon break/restore ----------
.PHONY: csi-delete
csi-delete:
	aws eks delete-addon --cluster-name $(CLUSTER) --addon-name aws-ebs-csi-driver --region $(REGION)
	aws eks wait addon-deleted --cluster-name $(CLUSTER) --addon-name aws-ebs-csi-driver --region $(REGION)

.PHONY: csi-restore
csi-restore:
	terraform -chdir=$(INFRA_TF_DIR) apply

# ==========================
# Observation targets
# ==========================
.PHONY: obs-all
obs-all: obs-app obs-net obs-storage obs-events

.PHONY: obs-app
obs-app:
	$(call hr)
	echo "[APP] deploy/rs/pod"
	kubectl -n $(NAMESPACE) get deploy,rs,pod -o wide || true
	$(call hr)
	echo "[APP] rollout status (best effort)"
	kubectl -n $(NAMESPACE) rollout status deploy/$(DEPLOY_NAME) --timeout=30s || true
	$(call hr)
	echo "[APP] last 120 lines of logs (best effort)"
	kubectl -n $(NAMESPACE) logs deploy/$(DEPLOY_NAME) --tail=120 2>/dev/null || true

.PHONY: obs-net
obs-net:
	$(call hr)
	echo "[NET] svc/ing/endpoints"
	kubectl -n $(NAMESPACE) get svc $(SERVICE_NAME) -o wide || true
	kubectl -n $(NAMESPACE) get ingress $(INGRESS_NAME) -o wide || true
	kubectl -n $(NAMESPACE) get endpoints $(SERVICE_NAME) -o wide || true
	$(call hr)
	echo "[NET] ingress details (tail 200)"
	kubectl -n $(NAMESPACE) describe ingress $(INGRESS_NAME) 2>/dev/null | tail -n 200 || true

.PHONY: obs-events
obs-events:
	$(call hr)
	echo "[EVENTS] recent events (tail 80)"
	kubectl -n $(NAMESPACE) get events --sort-by=.lastTimestamp | tail -n 80 || true

.PHONY: obs-readiness
obs-readiness:
	$(call hr)
	echo "[READINESS] pod readiness + endpoints"
	kubectl -n $(NAMESPACE) get pod -o wide || true
	kubectl -n $(NAMESPACE) get endpoints $(SERVICE_NAME) -o wide || true
	$(call hr)
	echo "[READINESS] describe pods (tail 260)"
	kubectl -n $(NAMESPACE) describe pod -l $(APP_LABEL_KEY)=$(APP_LABEL_VAL) | tail -n 260 || true
	$(call hr)
	echo "[READINESS] recent events"
	kubectl -n $(NAMESPACE) get events --sort-by=.lastTimestamp | tail -n 80 || true

.PHONY: obs-liveness
obs-liveness:
	$(call hr)
	echo "[LIVENESS] pod status / restarts"
	kubectl -n $(NAMESPACE) get pod -o wide || true
	$(call hr)
	echo "[LIVENESS] describe pods (tail 320)"
	kubectl -n $(NAMESPACE) describe pod -l $(APP_LABEL_KEY)=$(APP_LABEL_VAL) | tail -n 320 || true
	$(call hr)
	echo "[LIVENESS] logs (tail 200) (best effort)"
	kubectl -n $(NAMESPACE) logs deploy/$(DEPLOY_NAME) --tail=200 2>/dev/null || true
	$(call hr)
	echo "[LIVENESS] recent events"
	kubectl -n $(NAMESPACE) get events --sort-by=.lastTimestamp | tail -n 120 || true

.PHONY: obs-storage
obs-storage:
	$(call hr)
	echo "[STORAGE] StorageClass"
	kubectl get sc -o wide || true
	$(call hr)
	echo "[STORAGE] PVC/PV"
	kubectl -n $(NAMESPACE) get pvc,pv -o wide || true
	$(call hr)
	echo "[STORAGE] CSIDrivers"
	kubectl get csidrivers || true
	kubectl -n kube-system get pods | egrep 'ebs|csi' || true

.PHONY: obs-pvc
obs-pvc:
	$(call hr)
	echo "[PVC] describe pvc (prefer $(PVC2_NAME), fallback $(PVC_NAME))"
	if kubectl -n $(NAMESPACE) get pvc $(PVC2_NAME) >/dev/null 2>&1; then \
	  kubectl -n $(NAMESPACE) describe pvc $(PVC2_NAME) | tail -n 260 || true; \
	else \
	  kubectl -n $(NAMESPACE) describe pvc $(PVC_NAME) | tail -n 260 || true; \
	fi
	$(call hr)
	echo "[PVC] pv + volumeHandle (best effort)"
	PVC=$(PVC_NAME); \
	if kubectl -n $(NAMESPACE) get pvc $(PVC2_NAME) >/dev/null 2>&1; then PVC=$(PVC2_NAME); fi; \
	PV=$$(kubectl -n $(NAMESPACE) get pvc $$PVC -o jsonpath='{.spec.volumeName}' 2>/dev/null || true); \
	echo "PVC=$$PVC PV=$$PV"; \
	if [[ -n "$$PV" ]]; then \
	  kubectl get pv "$$PV" -o yaml | egrep -n 'awsElasticBlockStore:|csi:|volumeHandle:|fsType:' -n -A3 || true; \
	fi
