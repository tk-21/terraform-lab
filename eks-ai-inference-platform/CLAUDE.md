# eks-ai-inference-platform

## プロジェクト概要

EKS + Karpenter を基盤とした **本番グレードのAI推論インフラ**。

- **vLLM** (GPU Spot) と **Amazon Bedrock** (Claude Haiku) をコスト・可用性に応じて動的ルーティング
- GPU使用率・推論レイテンシ・$/tokenをリアルタイム可視化 (DCGM + OTEL + AMP + AMG)
- KEDA による推論キュー連動スケーリング (scale-to-zero → GPU Spotノード自動解放)

---

## アーキテクチャ

```
クライアント
    │
    ▼
ALB (VPC Endpoint経由)
    │
    ▼
AI Gateway (FastAPI / EKS Pod / arm64)
    ├─ コスト試算 → vLLM (GPU Spot g4dn.xlarge) を優先
    └─ GPU不可 / 予算超過 → Bedrock (Claude Haiku) にフォールバック
         │
         ├─ vLLM Pod
         │     └─ GPU: nvidia.com/gpu: 1
         │     └─ モデル: S3 → EBS (gp3) キャッシュ
         │
         └─ Bedrock Runtime (VPC Endpoint)

可観測性レイヤー
    ├─ DCGM Exporter (GPU metrics: 使用率/温度/メモリ)
    ├─ OpenTelemetry Collector (カスタムメトリクス: tokens/s, latency, $/req)
    ├─ Amazon Managed Prometheus (AMP) ← remote_write
    └─ Amazon Managed Grafana (AMG) ← ダッシュボード
         ├─ GPU Utilization Panel
         ├─ Inference Throughput Panel
         └─ Cost per 1M tokens Panel

スケーリング
    └─ KEDA ScaledObject (AMP metric → vLLM replica 0→N)
         └─ scale-to-zero → Karpenter が GPU Spotノードを自動返却
```

---

## ディレクトリ構造

```
eks-ai-inference-platform/
├── CLAUDE.md
├── phase1.md  ~ phase6.md
├── terraform/
│   ├── environments/dev/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── terraform.tfvars
│   └── modules/
│       ├── vpc/
│       ├── eks/
│       ├── karpenter/
│       └── observability/
├── k8s/
│   ├── karpenter/        # NodePool定義
│   ├── nvidia/           # device plugin
│   ├── vllm/             # 推論サーバー
│   ├── dcgm/             # GPUメトリクス
│   ├── otel/             # OpenTelemetry Collector
│   ├── keda/             # ScaledObject
│   └── gateway/          # AI Gateway
├── src/
│   ├── gateway/          # FastAPI ルーター
│   └── cost_lambda/      # コスト集計 Lambda
└── docs/
    ├── adr/
    └── runbook/
```

---

## 必須制約 (全フェーズ共通・厳守)

| 制約 | 内容 |
|------|------|
| ネットワーク | NAT Gateway **禁止** — VPC Endpoint のみ |
| IAM | ワイルドカード権限 **禁止** |
| シークレット | SSM Parameter Store のみ (ハードコード禁止) |
| IAMロール名 | 64文字以内 |
| Terraform | `count` **禁止** → `for_each` のみ |
| コンピュート | arm64/Graviton2 (CPU系) + g4dn (GPU系) |
| Spot | GPU NodePool は SPOT 優先 |
| GitHub Actions | OIDC認証のみ (IAMアクセスキー禁止) |
| Lambda | Python 3.12 + AWS Lambda Powertools / DLQ必須 / `reserved_concurrent_executions` 明示 |
| リージョン | ap-northeast-1 (東京) |
| 通知 | Chatwork REST API (`X-ChatWorkToken` / SSM) |
| コメント | Terraform HCL・Python の全コメントは日本語で「なぜ」を記述 |

---

## フェーズ一覧

| フェーズ | 内容 | 推定時間 |
|---------|------|---------|
| phase1 | VPC (Endpoint専用) + EKS + Karpenter + GPU NodePool | 60分 |
| phase2 | vLLM デプロイ + モデルサービング + S3モデルキャッシュ | 45分 |
| phase3 | DCGM + OTEL + AMP + AMG 可観測性スタック | 45分 |
| phase4 | AI Gateway (FastAPI) + コスト認識ルーティング + Bedrock Fallback | 45分 |
| phase5 | KEDA + scale-to-zero + コストダッシュボード + Chatwork通知 | 30分 |
| phase6 | 負荷試験 + ADR + STAR面接準備 + Zenn記事アウトライン | 60分 |

---

## 重要技術ポイント (面接で語れる深さ)

### vLLM の PagedAttention
KVキャッシュを仮想メモリ的にページ管理し、GPUメモリ断片化を排除。
連続バッチ処理と組み合わせることでGPUスループットを最大化。

### Karpenter の GPU Spot統合
`karpenter.k8s.aws/instance-gpu-manufacturer: nvidia` ラベルと
`capacity-type: spot` を NodePool に明示。Spot中断時は `terminationGracePeriodSeconds`
を使ってvLLMを graceful shutdown しKEDA がreplica 0 にスケールイン。

### KEDA vs HPA
HPA は CPU/Memory メトリクスに依存するが、推論ワークロードでは
「リクエストキュー深さ」や「GPU使用率」で制御するほうが本質的。
KEDA は AMP (Prometheus互換) メトリクスを直接スケールトリガーにできる。

### コスト認識ルーティング
vLLM (g4dn.xlarge Spot ~$0.16/h) vs Bedrock (Claude Haiku ~$0.25/1M tokens)。
リクエストのtoken数を事前推定し、時間コスト比較で最安ルートを選択。

---

## VPC Endpoint 必要一覧 (NAT GW代替)

```
Gateway型:
  - com.amazonaws.ap-northeast-1.s3           (モデル重みDL)

Interface型:
  - com.amazonaws.ap-northeast-1.ecr.api      (ECR認証)
  - com.amazonaws.ap-northeast-1.ecr.dkr      (イメージPull)
  - com.amazonaws.ap-northeast-1.sts          (IRSA)
  - com.amazonaws.ap-northeast-1.ec2          (Karpenter)
  - com.amazonaws.ap-northeast-1.logs         (CloudWatch Logs)
  - com.amazonaws.ap-northeast-1.ssm          (Parameter Store)
  - com.amazonaws.ap-northeast-1.ssmmessages  (SSM Session Manager)
  - com.amazonaws.ap-northeast-1.elasticloadbalancing
  - com.amazonaws.ap-northeast-1.aps          (AMP remote_write)
  - com.amazonaws.ap-northeast-1.bedrock-runtime
  - com.amazonaws.ap-northeast-1.eks          (EKS API)
```