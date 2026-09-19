# GPUコールドスタート vs Bedrockコスト比較

**計測日**: 2026-07-22  
**環境**: Kind (ローカル検証) / 実EKS計測はTBD  
**対象インスタンス**: g5g.xlarge (arm64 / NVIDIA T4G / 16GB GPU)

---

## 1. GPUノードコールドスタート実測

### 計測方法

```bash
# test/load/measure_scale_latency.sh を使用
# AIInferenceService作成 → Deployment ReadyReplicas>=1 までの時間を計測
kubectl apply -f config/samples/aiinferenceservice_v1alpha1_llama3.yaml
START=$(date +%s%N)
kubectl wait --for=condition=Ready=True ais/llama-3-8b --timeout=600s
END=$(date +%s%N)
echo "Cold start: $(( (END - START) / 1000000 ))ms"
```

### 実測データ (TBD - 実EKSクラスターで計測後に記入)

| 試行 | NodeClaim承認 | ノードReady | Pod Scheduled | Pod Ready | 合計 |
|---|---|---|---|---|---|
| 1回目 | TBD | TBD | TBD | TBD | TBD |
| 2回目 | TBD | TBD | TBD | TBD | TBD |
| 3回目 | TBD | TBD | TBD | TBD | TBD |
| **中央値** | - | - | - | - | **TBD** |
| **p95** | - | - | - | - | **TBD** |

### 参考: 他プロジェクトでの計測値

`eks-ai-inference-platform` プロジェクトでの計測(条件が異なる可能性あり):
- g5.xlarge (x86_64) コールドスタート: 約 3〜5分
- warm node(既存NodeClaimが残存): 約 30〜60秒

g5g (arm64) 固有のオーバーヘッド:
- arm64向けAMIはx86_64より若干サイズが大きい場合がある
- T4G GPUドライバーのロード時間は T4 (x86_64)と同等

---

## 2. コスト比較

### GPU (g5g.xlarge) コスト

| 項目 | 値 |
|---|---|
| オンデマンド料金 | $0.420/時間 (ap-northeast-1, 2026年7月時点) |
| Spot料金 (参考) | $0.126〜$0.210/時間 (約30〜50%割引) |
| **分単位コスト (Spot中央値)** | **≈ $0.0028/分** |

コールドスタート中(GPUノードが存在する場合)のコスト:
- 3〜5分のウォームアップ中は推論を処理していないが課金される
- Karpenter Consolidation で使わないノードは自動削除されるため最小化できる

### Bedrock (Claude Haiku) コスト

| 項目 | 値 |
|---|---|
| 入力トークン | $0.00025 / 1K tokens |
| 出力トークン | $0.00125 / 1K tokens |
| **1リクエスト当たりコスト(仮定: 入力512 + 出力256 tokens)** | **≈ $0.000448/req** |

### フォールバック採算ラインの試算

フォールバックが「コスト削減」になる条件:

```
GPU コールドスタート中のコスト > フォールバック中のBedrock課金

仮定:
- コールドスタート: 4分間
- GPU Spot コスト中央値: $0.0028/分
- コールドスタート中のリクエスト数: N件
- Bedrockコスト/req: $0.000448

GPUコスト: 4分 × $0.0028 = $0.0112
Bedrockコスト: N × $0.000448

BEP (損益分岐点): N = $0.0112 / $0.000448 ≈ 25 リクエスト

→ コールドスタート4分間に25件以上のリクエストがある場合、
  フォールバックはコスト中立かコスト削減になる。
```

### レイテンシ比較

| バックエンド | First Token Latency | Throughput (tokens/sec) |
|---|---|---|
| GPU (g5g + vLLM, warm) | TBD | TBD |
| Bedrock Claude Haiku (ap-northeast-1) | TBD | TBD |
| **差分** | TBD | TBD |

計測方法:
```bash
# GPU (warmup後)
curl -s -o /dev/null -w "%{time_total}" \
  http://<gpu-service>:8000/v1/completions \
  -d '{"prompt": "Hello", "max_tokens": 50}'

# Bedrock
aws bedrock-runtime invoke-model \
  --model-id anthropic.claude-haiku-20240307-v1:0 \
  --body '{"prompt": "\n\nHuman: Hello\n\nAssistant:", "max_tokens_to_sample": 50}' \
  /dev/stdout
```

---

## 3. フォールバック閾値90秒の根拠

```
[ここに実測後の根拠を記入する]

記入すべき内容:
- コールドスタート実測値の中央値・p95
- 90秒閾値に設定した場合の "不必要なフォールバック率"
  (ノードが90秒以内に起動した回数 / 全プロビジョニング回数)
- Bedrockフォールバック中のユーザー体験への影響
  (Haikuはvllm+Llama3と異なるモデルのため、応答品質の差異)
```

---

## 4. 復帰時のトラフィック切り戻し

### なぜ緩やかに戻すか

GPUが復帰した直後に全トラフィックをBedrockからGPUへ切り戻すと、
GPU側でウォームアップ中のスパイク(KV-cache miss率が高い状態)が発生する。

### 実装の設計方針 (Phase 4 Scope)

現フェーズでは `status.activeBackend` を即座に `gpu` に更新する設計を採用。
段階的切り戻し(トラフィックウェイト: 10% → 50% → 100%)はPhase 7の
AI Gateway統合で実装予定。

理由: 段階的切り戻しにはIngress/Gateway APIのweightedRoutingが必要で、
Operatorのスコープ外の依存が増える。現フェーズではフォールバック判定ロジックの
検証を優先する。

---

## 5. 今後の改善案

1. **動的閾値**: `gpuProvisionTimeoutSeconds` を履歴から自動調整するロジック
2. **コスト最適化**: GPU spot中断時の自動フォールバック(NodeClaim eviction イベント検知)
3. **品質比較**: GPU (vLLM+Llama3) vs Bedrock (Claude Haiku) の応答品質A/Bテスト
