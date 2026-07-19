# STAR形式 面接Q&A

## Q1: 「最も技術的に挑戦的だったインフラ構築を教えてください」

**Situation:**
AI推論基盤の要件として「OSS モデルをGPUで自前サービング」かつ
「コスト管理を自動化」という相反する要件があった。
GPU インスタンスは常時稼働させると月 $115 (g4dn.xlarge) かかるが、
実際の推論需要は1日数時間に限られていた。

**Task:**
vLLM on EKS でGPU効率を最大化しつつ、
トラフィックゼロ時はGPUノードを自動返却するアーキテクチャを設計・実装する。

**Action:**
1. KEDA の AMP Prometheus スケーラーで vllm_num_requests_waiting を監視
2. 待機リクエストゼロが5分継続 → vLLM replica=0
3. Karpenter WhenEmpty consolidation → g4dn.xlarge Spot 返却
4. AI Gateway が Bedrock にフォールバック (コールドスタート中のUX維持)
5. PagedAttention + continuous batching でGPU使用率を __% まで向上
   (DCGM + OTEL + AMG で可視化)

**Result:**
- GPU稼働時間: 1日24h → 約 __ h/day に削減 (___% コスト削減)
- P95レイテンシ: vLLM __ ms / Bedrock __ ms
- コールドスタート中のエラー率: ___% (Bedrock フォールバックにより)
- 1M tokens あたりのコスト: Bedrock $0.25 → vLLM $____ (___% 削減)

---

## Q2: 「NAT Gatewayなしでどうやって外部サービスにアクセスしましたか？」

**Situation:**
EKS クラスターをプライベートサブネットに配置し、
セキュリティとコスト (NAT GW: $45/月以上) の両立が課題だった。

**Task:**
NAT Gateway ゼロでECR/S3/Bedrock/AMPへのアクセスを実現する。

**Action:**
13種類の VPC Endpoint を Terraform for_each で管理:
- Gateway型: S3 (モデル重みのDL)
- Interface型: ECR API/DKR (イメージPull), STS (IRSA), APS (AMP), bedrock-runtime, etc.

特にハマったのは `private_dns_enabled = true` の設定漏れで
名前解決が失敗するケース。VPC Flow Logs で経路確認しながらデバッグした。

**Result:**
NAT Gateway コスト: $0
全てのAWSサービスへのアクセスがプライベート接続経由となり、
インターネット経由の通信ゼロを実現。

---

## Q3: 「vLLMとSageMakerエンドポイントを比較するとしたら？」

*(面接官がMLOpsバックグラウンドを持つ場合に備えて準備)*

**vLLMのメリット:**
1. PagedAttentionによるGPU効率: SageMakerの標準TGI比で推論スループット __ tokens/sec向上
2. OpenAI API互換: 既存クライアントのコード変更ゼロ
3. scale-to-zero: KEDA連携でGPUコストを使った分のみに最小化
4. モデル制約なし: HuggingFace の任意モデルを使用可能

**SageMakerのメリット:**
1. MLフロー統合 (モデルレジストリ、A/Bテスト、モデルモニタリング)
2. Managed なのでKubernetesの知識不要
3. Spot Training との統合が容易

**今回の判断:**
推論サービングの柔軟性とコスト最適化を優先してvLLMを選択。
MLOps機能が必要になった場合はMLflowをEKSに追加することを検討。

---

## 計測結果テンプレート (負荷試験後に埋める)

```
=== 計測結果 ===
vLLM (g4dn.xlarge, Phi-3-mini):
  スループット: ____ tokens/sec
  P50 レイテンシ: ____ ms
  P95 レイテンシ: ____ ms
  GPU使用率 (ピーク): ____%
  1Mトークンあたりコスト: $____

Bedrock (Claude Haiku):
  P50 レイテンシ: ____ ms
  P95 レイテンシ: ____ ms
  1Mトークンあたりコスト: $____

KEDA スケールアウト:
  トリガー条件: vllm_num_requests_waiting >= 1
  スケールアウト完了まで: ____ 分 (コールドスタート含む)
  スケールアウト中のエラー率: ____%

コスト最適化効果:
  scale-to-zero 適用後の1日あたりGPU稼働時間: ____ h/day
  従来 (常時稼働) vs scale-to-zero のコスト比: ____% 削減
```
