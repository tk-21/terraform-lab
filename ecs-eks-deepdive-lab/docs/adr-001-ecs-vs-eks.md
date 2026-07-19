# ADR-001: ECS Fargate vs EKS Karpenter 選定基準

## Status
Accepted

## Date
<!-- 実施日を記入 -->

## Context

同一ワークロード（FastAPI API + SQS Worker）をECS FargateとEKS Karpenterの
両環境にデプロイし、スケーリング速度・レイテンシ・運用コストを定量比較した。

### 比較対象

| 項目 | ECS (Fargate) | EKS (Karpenter) |
|------|--------------|-----------------|
| スケーリングトリガー | CloudWatch Alarm (60s評価) | KEDA (15sポーリング) |
| コンピュート確保 | Fargate 即時 | Karpenter NodePool |
| ゼロスケール | 非対応 (min=1) | 対応 (minReplicaCount=0) |
| 設定ファイル数 | Terraform HCL のみ | HCL + Kubernetes マニフェスト |
| 学習コスト | 低 | 高 (k8s知識必須) |

### 実測データ（Phase 4 計測値）

<!-- 自分の計測値を記入すること -->
- ロードテスト (200 jobs / 20 concurrency)
  - ECS: p50=___ms, p95=___ms, p99=___ms
  - EKS: p50=___ms, p95=___ms, p99=___ms
- スケールアウト開始まで
  - ECS: ___秒（CloudWatch Alarm評価待ち）
  - EKS: ___秒（KEDA 15s + Karpenter起動）
- Karpenter ノード起動時間: ___秒

---

## Decision

<!-- ⚠️ このセクションは必ずTakuya自身が書くこと。AIによる生成禁止。
     実際にデプロイして感じたこと、驚いたこと、難しかったことを書く。
     計測値を根拠に「自分ならどちらを選ぶか」を論じること。

     以下は問いかけ（削除して自分の言葉で置き換えること）:
     - 計測値を見て、予想と違った点は何か？
     - KEDA + Karpenter の組み合わせを実際に動かしてみてどう感じたか？
     - Fargate Spotの中断リスクとSIGTERMハンドリングをどう評価するか？
     - 自分が次のプロジェクトでどちらを選ぶか、その理由は？
-->
