# Operator Runbook — gpu-inference-operator-lab

## 目次

1. [フォールバック状態(Fallback)の対応](#fallback)
2. [Degraded状態の対応](#degraded)
3. [OOMKilled自己修復の確認](#oomkilled)
4. [CrashLoopBackOff対応](#crashloop)
5. [Webhook起因の拒否エラー対応](#webhook)
6. [Operatorの再起動](#operator-restart)
7. [フォールバック長期化(Bedrock側で費用が膨らんでいる場合)](#fallback-long)
8. [Webhook誤検知で正当なCRDが弾かれる場合](#webhook-false-positive)

---

## 1. フォールバック状態(Fallback)の対応 {#fallback}

### 症状

```
kubectl get ais <name> -n <namespace>
# → PHASE=Fallback, BACKEND=bedrock
```

### 原因

GPUプロビジョニングが `spec.bedrockFallback.gpuProvisionTimeoutSeconds`(デフォルト90秒)以内に
完了せず、トラフィックがBedrockに切り替わった状態。

### 調査手順

```bash
# 1. Conditionの詳細を確認
kubectl describe ais <name> -n <namespace>
# → Fallback=True, Reason=GPUProvisionTimeout

# 2. Karpenterのノードプロビジョニング状態を確認
kubectl get nodeclaims -l karpenter.sh/nodepool=<gpuNodePoolRef>

# 3. GPUノードのPod一覧を確認
kubectl get pods -n <namespace> -o wide | grep <name>

# 4. アノテーションのプロビジョニング開始時刻を確認
kubectl get ais <name> -n <namespace> -o jsonpath='{.metadata.annotations.inference\.takuya\.dev/provisioning-start-time}'
```

### 復旧

GPUノードが起動してPodがReadyになれば、次のReconcileサイクルで自動的に
`BACKEND=gpu`に戻る。手動介入は通常不要。

タイムアウト値が短すぎる場合は調整:

```bash
kubectl patch ais <name> -n <namespace> --type=merge \
  -p '{"spec":{"bedrockFallback":{"gpuProvisionTimeoutSeconds":180}}}'
```

---

## 2. Degraded状態の対応 {#degraded}

### 症状

```
kubectl get ais <name> -n <namespace>
# → PHASE=Degraded
```

Chatwork通知: `🚨 推論サービス Degraded — 手動介入が必要です`

### 原因

`spec.selfHealing.maxRestartAttempts`に達した。
自動修復を継続してもコスト暴走・根本原因の隠蔽が起きるため、
Operatorは自動修復を停止して人間に判断を委ねる。

### 調査手順

```bash
# 1. Conditionとイベントを確認
kubectl describe ais <name> -n <namespace>
# → Conditions: SelfHealExhausted

# 2. Pod状態を確認
kubectl get pods -n <namespace> -l inference.takuya.dev/service=<name>

# 3. 直近のKubernetes Eventを確認
kubectl get events -n <namespace> --field-selector involvedObject.name=<name> --sort-by='.lastTimestamp'

# 4. OOMKilledの場合: 現在のメモリlimitを確認
kubectl get deployment <name> -n <namespace> -o jsonpath='{.spec.template.spec.containers[0].resources}'

# 5. CrashLoopの場合: 直前のコンテナログを取得
kubectl logs -n <namespace> <pod-name> --previous
```

### 復旧手順

#### パターンA: OOMKilledが原因でメモリ不足が根本原因

```bash
# 1. メモリlimitを手動で適切な値に設定する
kubectl patch ais <name> -n <namespace> --type=merge \
  -p '{"spec":{"resources":{"limits":{"memory":"16Gi","nvidia.com/gpu":"1"}}}}'

# 2. RestartCountをリセットしてDegradedから脱出させる
kubectl patch ais <name> -n <namespace> --type=merge \
  -p '{"status":{"restartCount":0,"phase":"Provisioning"}}' --subresource=status
```

#### パターンB: CrashLoopが原因でモデル/設定の問題

```bash
# 1. モデルイメージを修正済みのものに更新する
kubectl patch ais <name> -n <namespace> --type=merge \
  -p '{"spec":{"modelImage":"<fixed-image-uri>"}}'

# 2. RestartCountをリセット
kubectl patch ais <name> -n <namespace> --type=merge \
  -p '{"status":{"restartCount":0}}' --subresource=status
```

#### パターンC: 一時的な障害(インフラノイズ)だった場合

```bash
# maxRestartAttemptsを引き上げてから再試行させる
kubectl patch ais <name> -n <namespace> --type=merge \
  -p '{"spec":{"selfHealing":{"maxRestartAttempts":5}}}'

kubectl patch ais <name> -n <namespace> --type=merge \
  -p '{"status":{"restartCount":0}}' --subresource=status
```

### 事後確認

```bash
# Degradedから脱出してRunningに遷移したことを確認
kubectl get ais <name> -n <namespace> -w
```

---

## 3. OOMKilled自己修復の確認 {#oomkilled}

Operatorが自動でメモリbumpを実施した場合のトレース手順。

```bash
# 1. 自己修復Eventを確認
kubectl get events -n <namespace> --field-selector reason=OOMKilledDetected

# 2. Deploymentのメモリlimitが引き上げられていることを確認
kubectl get deployment <name> -n <namespace> \
  -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'

# 3. AISのrestartCountが増加していることを確認
kubectl get ais <name> -n <namespace> -o jsonpath='{.status.restartCount}'

# 4. rolling updateが完了してPodがReadyになったことを確認
kubectl rollout status deployment/<name> -n <namespace>
```

### OOMKillを意図的に再現する手順(実験・検証用)

```bash
# メモリlimitを意図的に小さくしてOOMを発生させる
kubectl patch ais <name> -n <namespace> --type=merge \
  -p '{"spec":{"resources":{"limits":{"memory":"10Mi","nvidia.com/gpu":"1"}}}}'

# Operatorがbumpして10Mi → 13Mi(25%増) に修正されることを確認
kubectl get deployment <name> -n <namespace> -w \
  -o custom-columns='MEMORY:.spec.template.spec.containers[0].resources.limits.memory'
```

---

## 4. CrashLoopBackOff対応 {#crashloop}

Chatwork通知: `⚠️ CrashLoopBackOff 検知`

```bash
# 1. 直前のコンテナログを取得
kubectl logs -n <namespace> <pod-name> --previous

# 2. Pod termination messageを確認
kubectl get pod <pod-name> -n <namespace> \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated.message}'

# 3. restartCountを確認して自動修復カウンターとの関係を把握
kubectl get pod <pod-name> -n <namespace> \
  -o jsonpath='{.status.containerStatuses[0].restartCount}'
```

CrashLoopの根本原因はモデルファイルの破損・環境変数の設定ミス・
依存サービス(S3/ECR)へのアクセス失敗などが多い。
ログを確認して根本原因を修正した上でイメージを更新する。

---

## 5. Webhook起因の拒否エラー対応 {#webhook}

```bash
# エラー例
# Error from server: admission webhook "vaiinferenceservice.kb.io" denied the request:
# spec.resources.limits["nvidia.com/gpu"] is required when gpuNodePoolRef is specified
```

### よくある拒否パターンと対処

| エラーメッセージ | 原因 | 対処 |
|---|---|---|
| `nvidia.com/gpu is required` | resources.limitsにGPU指定なし | `resources.limits["nvidia.com/gpu"]: "1"` を追加 |
| `queueName is required` | queueDepthタイプでqueueName未設定 | `scalingMetric.queueName` を設定 |
| `maxReplicas must be >= minReplicas` | レプリカ数の論理矛盾 | `maxReplicas` を `minReplicas` 以上に修正 |
| `maxRestartAttempts must be set` | restartOnOOM=trueでmaxAttempts未設定 | `selfHealing.maxRestartAttempts: 3` を追加 |

### Webhookが正常に動作しているか確認

```bash
kubectl get validatingwebhookconfigurations
kubectl get mutatingwebhookconfigurations
```

---

## 6. Operatorの再起動 {#operator-restart}

Operator再起動後も以下が保証されている:

- `inference.takuya.dev/provisioning-start-time` アノテーションがetcdに残るため
  フォールバック閾値の計算が正確に再開される
- `status.restartCount` がetcdに保持されるため自己修復の試行回数が引き継がれる
- Reconcileループは冪等設計のため重複実行しても副作用なし

```bash
# Operatorを再起動する
kubectl rollout restart deployment/gpu-inference-operator-controller-manager -n gpu-inference-operator-system

# 再起動後にReconcileが再開したことを確認
kubectl logs -n gpu-inference-operator-system deployment/gpu-inference-operator-controller-manager -f
```

---

## 7. フォールバック長期化(Bedrock側で費用が膨らんでいる場合) {#fallback-long}

### 症状

- `status.activeBackend=bedrock` が1時間以上継続している
- AWS CostExplorerでBedrock費用が通常の10倍以上になっている
- Chatwork通知: `Fallback状態が継続中` が繰り返し届く

### 考えられる原因

| 原因 | 確認コマンド |
|---|---|
| GPUノードが起動できていない(EC2キャパシティ不足) | `kubectl get nodeclaims` / `kubectl describe nodeclaim <name>` |
| vLLMのイメージ取得失敗(ECR endpoint障害) | `kubectl describe pod <name>` → Events欄を確認 |
| GPUドライバーのロード失敗 | `kubectl logs <pod-name> -c vllm` |
| タイムアウト閾値が短すぎる | `kubectl get ais <name> -o jsonpath='{.spec.bedrockFallback.gpuProvisionTimeoutSeconds}'` |

### 調査手順

```bash
# 1. NodeClaimの状態を確認
kubectl get nodeclaims -l karpenter.sh/nodepool=<gpuNodePoolRef>
kubectl describe nodeclaim <nodeclaim-name>
# → DisruptionReason, Conditions を確認

# 2. EC2キャパシティ不足の場合: 別インスタンスタイプへのフォールバック設定確認
kubectl get nodepool <gpuNodePoolRef> -o yaml | grep -A5 requirements

# 3. フォールバック中のBedrock費用を試算
# (リクエスト数 × $0.000448/req で概算)
kubectl logs -n gpu-inference-operator-system \
  deployment/gpu-inference-operator-controller-manager \
  | grep "fallback request" | wc -l
```

### 対処

#### キャパシティ不足が原因の場合

```bash
# NodePoolに代替インスタンスタイプを追加する (Terraform管理外の場合は一時的に直接編集)
kubectl edit nodepool <gpuNodePoolRef>
# spec.template.spec.requirements に g5g.2xlarge 等を追加

# または、Bedrockのみで完結させる緊急モードに切り替える
kubectl patch ais <name> -n <namespace> --type=merge \
  -p '{"spec":{"bedrockFallback":{"gpuProvisionTimeoutSeconds":1}}}'
# ※ タイムアウトを1秒にすると常時Bedrockに落ちる。コスト意識して使うこと
```

#### タイムアウト閾値の調整

```bash
# 実測のコールドスタート時間に合わせて調整
kubectl patch ais <name> -n <namespace> --type=merge \
  -p '{"spec":{"bedrockFallback":{"gpuProvisionTimeoutSeconds":300}}}'
```

### 事後

費用異常が発生した場合は AWS Budgets アラートを設定して再発防止する。

---

## 8. Webhook誤検知で正当なCRDが弾かれる場合 {#webhook-false-positive}

### 症状

```
Error from server: admission webhook "vaiinferenceservice.kb.io" denied the request: ...
```

正しく設定しているはずのCRDが拒否される、またはWebhook自体が応答しない。

### 原因の切り分け

```bash
# 1. Webhookの設定を確認
kubectl get validatingwebhookconfigurations gpu-inference-operator-validating-webhook-configuration -o yaml
kubectl get mutatingwebhookconfigurations gpu-inference-operator-mutating-webhook-configuration -o yaml

# 2. Webhookエンドポイント(Operator pod)が正常かを確認
kubectl get pods -n gpu-inference-operator-system
kubectl logs -n gpu-inference-operator-system deployment/gpu-inference-operator-controller-manager \
  | grep -i webhook | tail -20

# 3. TLS証明書の有効期限を確認 (cert-manager管理の場合)
kubectl get certificate -n gpu-inference-operator-system
kubectl describe certificate <cert-name> -n gpu-inference-operator-system
# → Conditions: Ready=True / NotAfter を確認
```

### パターン別対処

#### パターンA: TLS証明書の期限切れ

```bash
# cert-managerが管理している場合は自動更新されるが、手動でトリガーする場合
kubectl delete secret <webhook-tls-secret> -n gpu-inference-operator-system
# cert-managerが自動再発行する (数秒〜1分で再作成される)

# 再作成を確認
kubectl get secret -n gpu-inference-operator-system -w
```

#### パターンB: failurePolicy=Fail でWebhook Podが落ちている

Webhook Podが応答しない状態で `failurePolicy: Fail` だと全てのCRD操作がブロックされる。

```bash
# 緊急回避: failurePolicyを一時的にIgnoreに変更
kubectl patch validatingwebhookconfigurations \
  gpu-inference-operator-validating-webhook-configuration \
  --type=json \
  -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]'

# Operatorを再起動して復旧させてからFailに戻す
kubectl rollout restart deployment/gpu-inference-operator-controller-manager \
  -n gpu-inference-operator-system

kubectl patch validatingwebhookconfigurations \
  gpu-inference-operator-validating-webhook-configuration \
  --type=json \
  -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Fail"}]'
```

#### パターンC: バリデーションロジックのバグ(正当な値を拒否している)

```bash
# Operatorログでバリデーションエラーの詳細を確認
kubectl logs -n gpu-inference-operator-system \
  deployment/gpu-inference-operator-controller-manager \
  | grep -i "validation\|deny\|webhook" | tail -30

# 問題のあるバリデーションを特定してOperatorをロールバック
kubectl rollout history deployment/gpu-inference-operator-controller-manager \
  -n gpu-inference-operator-system
kubectl rollout undo deployment/gpu-inference-operator-controller-manager \
  -n gpu-inference-operator-system
```
