# Zenn 記事アウトライン

## タイトル案

「ECS vs EKS を同一ワークロードで実測比較：スケーリング速度・コスト・運用の違い」

## ターゲット読者

- ECSは使ったことあるがEKSをまだ使っていないエンジニア
- 「ECSとEKS何が違うの？」という問いに答えられないエンジニア

## 構成

### 1. はじめに（400字）
- ECSとEKSの比較記事は多いが、定量データで比較しているものは少ない
- 同一ワークロードを両方にデプロイして実測した

### 2. アーキテクチャ概要（Mermaidで図示）（600字）
- FastAPI API + SQS Worker を ECS / EKS 両方に
- 共通: SQS, ALB, ECR
- ECS: Fargate + Service Connect + Step Scaling
- EKS: Karpenter + KEDA + Pod Identity

### 3. スケーリング設計の違い（メイン）（1200字）

#### ECS: CloudWatch Alarm → Step Scaling
```
SQSキュー深度 → CloudWatch Alarm(60s評価) → Step Scaling Policy → Fargate Task
```
- 60秒評価の意味: スパイク直後にスケールできない
- Fargate起動は約10秒で速い

#### EKS: KEDA → HPA → Karpenter
```
SQSキュー深度 → KEDA(15sポーリング) → HPA → Pod Pending → Karpenter Node起動
```
- 15秒ポーリング = 60秒評価の4倍速
- ただしノード起動（30-60s）がボトルネック

### 4. 実測データ（★差別化ポイント）（800字）
<!-- 実際の計測値を記入 -->
| 指標 | ECS | EKS |
|------|-----|-----|
| p50レイテンシ | ___ms | ___ms |
| p95レイテンシ | ___ms | ___ms |
| スケールアウト開始 | ___秒 | ___秒 |
| ゼロスケール | 非対応 | 対応 |

### 5. KEDA minReplicaCount=0 の実際（600字）
- キュー空 → Worker Pod 0台 → Karpenter ノード削除 → EC2 0台
- 夜間・週末のコスト削減が見込める

### 6. 選定基準まとめ（400字）
- チームにk8s経験者がいる → EKS + Karpenter
- 小規模・シンプルに始めたい → ECS Fargate
- ゼロスケールが必要 → EKS + KEDA 一択

### 7. まとめ（200字）
- GitHubリポジトリ、フィードバック歓迎

## 付記
- Mermaid アーキテクチャ図: docs/adr-001-ecs-vs-eks.md から流用
- コードスニペット: GitHub リポジトリへリンク
