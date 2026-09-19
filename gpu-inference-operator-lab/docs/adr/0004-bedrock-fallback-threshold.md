# ADR-0004: Bedrockフォールバック閾値の設計

**Status**: Accepted  
**Date**: 2026-07-22  
**Author**: takuya

---

## Context

GPUノードのコールドスタート(Karpenter NodeClaimがg5gノードをプロビジョニングしてPodがReadyになるまで)
には数分かかる。この間、受信リクエストに対して応答できないとSLOが毀損する。

`spec.bedrockFallback.gpuProvisionTimeoutSeconds` で閾値を設定し、超過した場合に
`status.activeBackend` を `bedrock` に切り替えるロジックを実装した。

### 検討した閾値の選択肢

| 閾値 | 特性 |
|---|---|
| 30秒 | フォールバックが早すぎる。ノード起動が間に合う場合も不必要にBedrockへ切り替える |
| 60秒 | Karpenterのノード起動最短ケース(既存NodeClaimがwarm状態)に合わせた値 |
| **90秒(採用)** | g5gコールドスタートの中央値(実測: 3〜4分)より短いが、SLO優先 |
| 300秒 | ノード起動の最大ケース(AMI pull含む)に合わせた値。Bedrock活用が事実上なくなる |

### フォールバック判定のシグナル

候補として以下を検討した:

1. **Karpenter NodeClaim status**: プロビジョニング進捗を直接取得できるが、
   NodeClaim API(v1beta1)はKarpenterバージョンによって変わりやすくAPIの安定性が低い。
   また、ClusterのRBACにNodeClaim watch権限を追加する必要がある。

2. **Pod Events (Scheduled/Unschedulable)**: Kubernetesネイティブだが、
   Eventsの保持期間は1時間でOperator再起動後に消失する。タイムアウト計算が狂うリスクがある。

3. **アノテーション + ReadyReplicas(採用)**: Operatorが最初にProvisioning状態を検知した
   時刻をetcdのアノテーションに記録する。etcdは永続化されているためOperator再起動後も
   正確な経過時間を計算できる。NodeClaim APIへの依存がないためKarpenterバージョン非依存。

---

## Options

### Option A: 固定閾値90秒

`spec.bedrockFallback.gpuProvisionTimeoutSeconds` のデフォルト値として90秒を採用。
ユーザーはSpecで上書き可能(30〜600秒の範囲)。

**メリット:**
- 実装が単純
- ユーザーがトラフィックパターンに合わせて調整できる

**デメリット:**
- 適切な閾値はワークロードの重要度・Bedrockコスト・GPUコストの三者バランスで変わる
- 「なぜ90秒か」を実測データで示す必要がある

### Option B: 動的閾値(p95プロビジョニング時間ベース)

過去のNodeClaimプロビジョニング時間をPrometheusに記録し、その p95 を閾値として動的に更新する。

**メリット:** 実測に基づく適応的な閾値

**デメリット:**
- 実装複雑度が大幅に上がる
- プロビジョニング時間の計測インフラ(Karpenter metrics + Prometheus)が必要

---

## Decision

> **⚠️ このDecisionセクションは人間が書く。AI生成禁止。**
>
> (CLAUDE.md ルール: "ADRのDecisionセクションは必ず自分で書く")
>
> あなた自身の言葉で、90秒という閾値を選んだ根拠と、
> 「アノテーション方式でプロビジョニング時間を追跡する」設計を選んだ理由を記入すること。
> 実際に実装・実測してみた感想(何が予想外だったか、代替案と比べてどうだったか)も書く。

```
[ここに自分の言葉でDecisionを記入する]

ヒント:
- なぜ90秒なのか(実測データとの関係)
- Pod Events ではなくアノテーションを選んだ実際の判断プロセス
- Operator再起動耐性(idempotency)を意識した設計でどこが難しかったか
- 固定閾値90秒のデメリットを将来どう改善するか
```

---

## Consequences

### 実装上の影響

- `inference.takuya.dev/provisioning-start-time` アノテーションがAISリソースに追加される
- フォールバック発動時に `status.phase=Fallback`, `status.activeBackend=bedrock` に遷移する
- フォールバック条件: Conditionの `Fallback=True` で追跡できる

### トラフィックルーティングの前提

本Operatorは `status.activeBackend` を更新するが、**トラフィックの実際の切り替えは行わない**。
`status.activeBackend=bedrock` を監視するAI Gateway(または専用Proxy)が実際のルーティングを担う。

この責任分離の理由: Operatorがトラフィック経路を直接変更すると、
Ingress/Gateway APIとの依存が密結合になりテスト・デプロイが複雑になる。

### コスト試算

`docs/benchmarks/gpu-coldstart-vs-bedrock-cost.md` 参照。

### フォールバック発動の実測検証方法

```bash
# GPU Podをわざと起動不可能な状態にする
kubectl patch ais llama-3-8b --type=merge -p '{"spec":{"gpuNodePoolRef":"non-existent-pool"}}'

# 90秒後にフォールバックが発動することを確認
kubectl get ais llama-3-8b -w
# PHASE が Provisioning → Fallback に遷移し
# BACKEND が gpu → bedrock になることを確認
```
