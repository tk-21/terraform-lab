# gpu-inference-operator-lab

## プロジェクトの目的

AI推論ワークロード(vLLM on EKS)のライフサイクル管理・オートスケーリング・コスト最適化・自己修復を担う
**カスタムKubernetes Operator**をGo(controller-runtime / kubebuilder)でゼロから自作する。

KEDAやCloudWatch Alarmのような既存ツールを「使う」のではなく、その裏側にある reconcile loop・
custom scaling logic・admission webhook の仕組みを自分の手で実装し、定量的な比較データを取得することで
以下を証明することを狙う。

- KEDAのポーリング間隔(15秒)やCloudWatch Alarmの評価間隔(60秒)に対し、自作コントローラーの反応速度がどう違うか
- Karpenter GPUノードのコールドスタート待ち時間中、Bedrockへの自動フォールバックでどれだけレイテンシとコストが変わるか
- CrashLoopBackOff/OOMKilledパターンを自動検知・自己修復するロジックが、平均復旧時間(MTTR)をどれだけ短縮するか

既存プロジェクト `eks-ai-inference-platform`(vLLM+Karpenter+KEDA+観測基盤)とは役割を分ける。
そちらは「ツールを組み合わせて動かす」プロジェクト、本プロジェクトは「コントローラー自体を書く」プロジェクト。

## 成果物として目指すCRD

```yaml
apiVersion: inference.takuya.dev/v1alpha1
kind: AIInferenceService
metadata:
  name: llama-3-8b
spec:
  modelImage: <ECRイメージ>
  gpuNodePoolRef: karpenter-gpu-g5g
  minReplicas: 0
  maxReplicas: 4
  scalingMetric:
    type: queueDepth   # or gpuUtilization
    targetValue: 10
  bedrockFallback:
    enabled: true
    modelId: <BedrockモデルID>
    gpuProvisionTimeoutSeconds: 90
  selfHealing:
    restartOnOOM: true
    maxRestartAttempts: 3
status:
  phase: Running | Provisioning | Fallback | Degraded
  conditions: [...]
  lastScaleTime: ...
  activeBackend: gpu | bedrock
```

## 技術スタック

- Go 1.22+ / controller-runtime / kubebuilder
- EKS 1.30+ / Karpenter (GPU NodePool: g5g系, Graviton2+NVIDIA T4G ※arm64制約に準拠)
- Terraform (EKSクラスタ・IAM・VPC。既存labとの重複を避けるため最小構成の専用クラスタ、またはKind+実クラスタのハイブリッド)
- Prometheus client-go (DCGM Exporterメトリクス取得)
- Amazon Bedrock (フォールバック推論先)
- Chatwork API (Operatorイベント通知)
- envtest / Kind (コントローラーのテスト)
- GitHub Actions (OIDC, arm64マルチアーキビルド, ECR push)

## 全プロジェクト共通の制約条件

- NAT Gatewayは使用しない。VPC Endpointsのみで完結させる
- コンピュートはarm64/Graviton2で統一する(GPUノードもg5g系でarm64に揃える)
- IAM: ワイルドカード禁止、ロール名は64文字以内
- Terraformは`for_each`を使用し`count`は使わない
- シークレットはSSM Parameter Store経由(ハードコード禁止)
- インラインコメントは日本語で「なぜそうしたか」を書く。「何をしているか」は書かない
- GitHub ActionsはOIDC認証のみ。IAMアクセスキーは発行しない
- 通知はChatwork API(`POST /v2/rooms/{room_id}/messages`, `X-ChatWorkToken`ヘッダー, `application/x-www-form-urlencoded`)
- リージョンは`ap-northeast-1`をデフォルトとする

## 進め方のルール(重要)

2. **前フェーズ要約の引き継ぎ**: phase2以降の実行前に、直前フェーズで実際に実装した内容(コミットログ・READMEの差分要約)を
   そのフェーズファイル冒頭の「前フェーズ実施結果」セクションに手動で追記してから実行すること。Claude Codeに要約させて
   そのまま貼るのではなく、自分の言葉で3〜5行にまとめる(この作業自体が理解の定着になる)
3. **ADRのDecisionセクションは必ず自分で書く**: 各フェーズで生成するADR(`docs/adr/xxxx.md`)のうち、
   Context/Optionsまでは生成AIの補助を受けてよいが、**Decision(なぜその選択をしたか)は人間が書く**。
   このプロジェクトにおいてAI生成を明示的に禁止する箇所。理由: 面接で語れる価値は「再現されたテキスト」ではなく
   「実体験に基づくトレードオフの言語化」から生まれるため
4. **15分説明チェックポイント**: 各フェーズ完了後、資料なしで以下を口頭説明できるか自己チェックする
   - このフェーズで何を実装したか
   - なぜその技術・設計を選んだか(代替案との比較)
   - 実装中に何が難しかったか
5. **四部構成での言語化フレームワーク**: 各フェーズのSTAR回答・Zenn記事下書きは以下の順で書く
   - 課題の定量化(何が問題で、どう数値化したか)
   - 技術選定の理由(なぜこの技術/設計を選んだか、比較検討した代替案)
   - 効果・インパクト(定量的なBefore/After)
   - 何が難しかったか(最も面接官が聞きたがる部分。省略しない)

## リポジトリ構成(想定)

```
gpu-inference-operator-lab/
├── CLAUDE.md
├── api/v1alpha1/           # CRD型定義
├── controllers/            # reconcileループ本体
├── internal/
│   ├── scaling/             # カスタムオートスケーリングロジック
│   ├── fallback/            # Bedrockフォールバック判定
│   ├── selfheal/             # 自己修復ロジック
│   └── notify/               # Chatwork通知
├── webhooks/                # Admission Webhook(validating/mutating)
├── config/                  # kubebuilder manifests (CRD, RBAC, webhook)
├── terraform/                # EKS/Karpenter/IAM
├── test/e2e/                  # envtest/Kind E2Eテスト
├── docs/
│   ├── adr/
│   ├── architecture.mmd     # Mermaid構成図
│   ├── runbook.md
│   └── star-interview-qa.md
└── .github/workflows/
```

## 各フェーズの概要

| Phase | 内容 |
|---|---|
| 1 | 環境構築・CRD設計・kubebuilderスキャフォールド |
| 2 | Reconcileループ基本実装(Deployment/Service管理) |
| 3 | カスタムオートスケーリング(GPU使用率/キュー深度連携) |
| 4 | Bedrockフォールバックとコスト最適化ロジック |
| 5 | 自己修復ロジックとAdmission Webhook |
| 6 | Operator自体のオブザーバビリティ |
| 7 | CI/CDパイプライン構築 |
| 8 | ドキュメント化・STAR面接想定問答・Zenn記事アウトライン |
