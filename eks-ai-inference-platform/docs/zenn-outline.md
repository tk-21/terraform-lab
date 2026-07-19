# Zenn記事タイトル (案)
「vLLM + EKS + Karpenter でつくるコスト最適化AI推論基盤 —
GPU Spot インスタンスを scale-to-zero して$0に近づける」

## ターゲット読者
- EKS を使っているが AI推論をどう乗せるか悩んでいるインフラエンジニア
- SageMaker 以外の選択肢を探している ML エンジニア

## 構成

### 1. なぜ自前でGPUサービングをするのか (500字)
- Bedrock だけでは OSS モデルが使えない
- SageMaker は常時稼働コストが高い
- vLLM + Karpenter の組み合わせがコスト最適

### 2. アーキテクチャ全体図 (Mermaid) (300字)
- コンポーネントとデータフローの説明

### 3. vLLM の PagedAttention とは (1000字)
- KV キャッシュの断片化問題
- ページ管理でGPUメモリ効率を最大化
- 実測値: GPU使用率 __% → __%

### 4. Karpenter で GPU Spot を動的管理 (1000字)
- NodePool 設計 (GPU/CPU 分離)
- Spot 中断ハンドリング (terminationGracePeriodSeconds)
- AL2 vs Bottlerocket を選んだ理由

### 5. KEDA で scale-to-zero (1000字)
- HPA では推論ワークロードに対応できない理由
- vllm_num_requests_waiting をトリガーにした設計
- scale-to-zero → Karpenter ノード返却の連鎖

### 6. OTEL + DCGM + AMP で可観測性 (800字)
- DCGM のインストールと GPU メトリクス
- OTELカスタムメトリクスでコストを可視化

### 7. 負荷試験結果と考察 (800字)
- Locust 実行結果
- コールドスタート問題と Bedrock フォールバック

### 8. まとめとコスト試算 (500字)
- scale-to-zero 前後のコスト比較表
- 今後の改善: GPU キャッシュウォームアップ、inf2 への移行

## GitHub リポジトリ
[eks-ai-inference-platform リンク]
