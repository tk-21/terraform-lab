# ADR-0005: 自己修復の範囲とAdmission Webhookポリシーの設計

**Status**: Accepted  
**Date**: 2026-07-23  
**Author**: takuya

---

## Context

Phase 4でBedrockフォールバックを実装したが、GPUノード起動後も
OOMKilledやCrashLoopBackOffが発生した場合に人間が気づかないまま
Degraded状態が続く問題がある。

また、`spec.resources`のGPU limit未指定やscalingMetric設定の不整合など
「作成時点で検知できる設定ミス」をAPIサーバーが素通りさせてしまい、
あとでPodが起動しないことで初めて気づくパターンが多い。

### 解決したい2つの問題

1. **実行時障害の自己修復**: OOMKilled/CrashLoopBackOffを検知してOperatorが修復を試みる
2. **設定ミスの早期発見**: 危険な設定を`kubectl apply`時点でブロックするAdmission Webhook

### 自己修復の技術的な選択肢

| アプローチ | 特性 |
|---|---|
| Pod再起動のみ | 単純だがOOMKilledは同じlimitで再起動しても即座に再OOMになる |
| **メモリbump + rolling update(採用)** | limitを引き上げてからDeploymentを更新することで根本対処 |
| VPA (Vertical Pod Autoscaler) | リソース自動調整の既存ツール。本プロジェクトは「仕組みを自作する」ため不採用 |
| 無限リトライ | コスト暴走・根本原因の隠蔽リスクがある |

### Webhookの対象スコープの選択肢

| スコープ | 特性 |
|---|---|
| Pod直接webhook | GPUリソースのポリシー強制に最も直接的だがクラスター全体に影響 |
| **CRD(AIInferenceService)レベルwebhook(採用)** | 本Operatorが管理するリソースに閉じたポリシー。他チームへの影響なし |
| OPA/Gatekeeper | より汎用的なポリシーエンジン。本プロジェクトのスコープを超える |

---

## Options

### Option A: 自己修復 — 単純再起動

OOMKilled/CrashLoop検知時にPodをDeleteして再起動させる。

**メリット:** 実装が単純  
**デメリット:** OOMKilledは同じlimitで再起動しても即座に再OOMになる。根本解決にならない。

### Option B: 自己修復 — メモリbump + rolling update(採用)

OOMKilled検知時はDeploymentのmemory limitを25%引き上げてからUpdateする。
Rolling updateによりPodが順番に新しいlimitで再起動される。

**メリット:** OOMKilledの根本原因(メモリ不足)を直接修正する  
**デメリット:** limit引き上げはコスト増加を伴う。上限なく引き上げると他のPodを圧迫する

### Option C: 自己修復 — 無限リトライ

maxRestartAttemptsなしで永続的に修復を試みる。

**採用しない理由:** GPUコスト暴走・根本原因が設定ミスの場合に問題を隠蔽してしまう

### Option D: Webhook — Pod直接webhook

全Podを対象にnvidia.com/gpu limitを必須化する。

**採用しない理由:** クラスター全体のPodに影響し、他チームのワークロードを巻き込む。
本Operatorが管理しないPodへの副作用リスクが高い。

### Option E: Webhook — CRDレベルwebhook(採用)

AIInferenceService作成/更新時のみ検証する。

**メリット:** 本Operatorの責任範囲に閉じる。テスト容易性が高い  
**デメリット:** Operatorを経由せず直接Deploymentを作成した場合は検証されない

---

## Decision

> **⚠️ このDecisionセクションは人間が書く。AI生成禁止。**
>
> (CLAUDE.md ルール: "ADRのDecisionセクションは必ず自分で書く")
>
> あなた自身の言葉で以下を記述すること:
> - なぜ「修復上限を設けてDegradedにする」設計にしたか(無限リトライを選ばなかった理由)
> - OOMKilledに対してメモリbumpを選んだ実際の判断プロセス
> - CRDレベルWebhookを選んだ理由(Pod直接webhookとの比較での実体験)
> - 実装してみて「ここは想定外だった」「もっとこうすれば良かった」と感じた点

```
[ここに自分の言葉でDecisionを記入する]

ヒント:
- 「なぜ3回上限なのか」の根拠(1回=ノイズ・2回=一過性・3回超=設定ミスの判断基準)
- Webhookのfailure policy=failを選んだ理由(Ignoreとの違い)
- ValidatingとMutatingをどう使い分けたか(順序の関係)
- OOMKilledとCrashLoopで対処を分けた理由の言語化
```

---

## Consequences

### 実装上の影響

- `internal/selfheal/Detector` がPodHealth(コントローラーが収集した障害情報)を入力として
  修復アクションを決定する。fallback.Detectorと同じ純粋関数パターンで単体テスト可能。
- OOMKilled検知時: `spec.resources.limits.memory`を25%引き上げてDeploymentをUpdate
- CrashLoopBackOff検知時: Kubernetes Eventに記録しChatworkに通知
- `maxRestartAttempts`超過時: `status.phase=Degraded`に遷移して自動修復を停止
- `status.restartCount`が自己修復の累計試行回数として記録される

### Webhookポリシーの強制内容

- **ValidatingWebhook**:
  - `gpuNodePoolRef`設定時に`resources.limits["nvidia.com/gpu"] >= 1`を必須化
  - `scalingMetric.type=queueDepth`時に`queueName`を必須化
  - `maxReplicas >= minReplicas`の検証
  - `selfHealing.restartOnOOM=true`時に`maxRestartAttempts > 0`を必須化
  - `latest`タグ使用時は警告(エラーにはしない)
- **MutatingWebhook(デフォルト注入)**:
  - `pollingIntervalSeconds` → 5秒
  - `bedrockFallback.gpuProvisionTimeoutSeconds` → 90秒
  - `selfHealing.maxRestartAttempts` → 3
  - `resources` → GPU workload向けデフォルト(8Gi memory + 1 GPU)

### 証明書管理

- 本番: cert-manager によるTLS証明書の自動ローテーション
- 開発: `make generate-certs`で自己署名証明書を生成(Kind環境向け)
- webhook manifestの`caBundle`はcert-managerのCAinjectorが自動注入する

### 検証方法

```bash
# OOMKilledを意図的に発生させる
kubectl patch ais llama-3-8b --type=merge \
  -p '{"spec":{"resources":{"limits":{"memory":"1Mi","nvidia.com/gpu":"1"}}}}'

# OOMKilled → メモリbump → rolling update を確認
kubectl get events -n default --field-selector reason=OOMKilledDetected -w

# maxRestartAttempts超過でDegradedに遷移することを確認
kubectl get ais llama-3-8b -w  # PHASE が Degraded になることを確認

# GPU limit未指定のmanifestがWebhookで拒否されることを確認
kubectl apply -f - <<EOF
apiVersion: inference.takuya.dev/v1alpha1
kind: AIInferenceService
metadata:
  name: test-no-gpu-limit
spec:
  modelImage: ecr.aws/vllm:v0.4.0
  gpuNodePoolRef: karpenter-gpu-g5g
  minReplicas: 1
  maxReplicas: 2
  scalingMetric:
    type: queueDepth
    targetValue: 10
    queueName: test-queue
  resources:
    limits:
      memory: "8Gi"
      # nvidia.com/gpu が意図的に欠落
EOF
# → admission webhook "vaiinferenceservice.kb.io" でエラーになることを確認
```
