# ADR-003: スケーリング戦略 (KEDA vs HPA vs 手動)

## ステータス
承認済み

## コンテキスト
vLLMのスケーリング方法として以下を比較した:

**HPA (Horizontal Pod Autoscaler)**
- CPU/Memory メトリクスベース
- 推論ワークロードではCPUが低くてもGPU/キューが溢れるケースがあり不適合

**KEDA (Kubernetes Event Driven Autoscaler)**
- 任意のメトリクスでスケーリング可能
- AMP Prometheus メトリクス (`vllm_num_requests_waiting`) を直接トリガーに使用可能
- scale-to-zero をネイティブサポート

**手動スケーリング**
- 運用負荷が高く、24/7 監視が必要

## 決定
KEDA + AMP Prometheus スケーラーを採用。

## 決定理由
<!-- ハンズオン後に記述: vllm_num_requests_waiting をトリガーにした判断の妥当性 -->
<!-- HPAで実現しようとすると何が困難だったかを具体的に記述 -->

## コールドスタート問題
scale-to-zero により5分のコールドスタートが発生する。
これを許容した理由: (ハンズオン後に記述)
対策: AI Gateway の Bedrock フォールバックで UX を維持。
