# 面接での語り方テンプレート

## STAR形式

### 状況（Situation）
EKSで本番相当の負荷テストができる検証環境を構築し、意図的にボトルネックを仕込んだFastAPIアプリでチューニングを実践しました。構成はEKS + Karpenter + Prometheus/Grafanaで、k6をECS Fargateで実行して計測しています。

### 課題（Task）
k6で100VUの負荷をかけると p95レイテンシが3,850msに悪化し、エラーレートが14.3%に達していました。原因はCPU Throttling（87%）とメモリOOMKillの頻発、DynamoDB同期アクセスによるI/Oブロッキングです。

### 行動（Action）
Prometheus + Grafanaでボトルネックを特定し、以下を段階的に改善しました:

1. **VPAのAdvisoryモードで推奨値を確認** → requests.cpu 100m→250m、limits.cpu 200m→500m に変更。CPU Throttling 87%→4%に削減
2. **HPA + KEDAで自動スケールを実装** → CPU/メモリ閾値（HPA）とPrometheusリクエストレート（KEDA）の2軸でスケール。100VU時エラーレートを14.3%→0%に解消
3. **DynamoDB呼び出しをaioboto3で非同期化** → I/O待機中のイベントループブロッキングを解消。/db-latency p95を95ms→22msに改善
4. **PDB + Pod Affinityで可用性確保** → Karpenterのノード入れ替え時も最低1レプリカを維持

### 結果（Result）
- p95レイテンシ: 3,850ms → 165ms（**96%改善**）
- スループット: 12.8 req/s → 89.4 req/s（**599%向上**）
- CPU Throttling率: 87% → 4%（**95%削減**）
- OOMKill: 3回 → 0回（**解消**）
- 月次コスト: $18.40 → $16.20（Spot活用で**12%削減**）

構成はGitHubに公開し、Zenn記事化しました。

---

## よくある深掘り質問への回答

### Q: なぜHPAとKEDAを両方使うのか？

HPAはCPU/メモリが実際に上昇してからスケールするため、スパイクへの応答に30-60秒のラグが生じます。KEDAはPrometheusのリクエストレートを見て「CPUが上がる前に」スケールを開始できます。ADR-001に判断根拠を記録しています。

### Q: VPAをAutoモードにしなかった理由は？

検証中にVPA AutoモードがPodを自動evictし、全レプリカが一時的に0になる事象が発生しました。負荷テスト中の計測値が汚染されるリスクもあるため、UpdateMode: Offで推奨値確認のみに使用しています（ADR-002）。

### Q: Karpenterのコスト削減効果は？

Spot Instanceを優先しつつ、On-demandへのフォールバックも設定しています。Spot割り込みはEventBridge → SQSでKarpenterに通知され、事前にdrainすることで可用性を維持しています。実測でEKSノードコストを約40%削減しています。

### Q: 非同期化でなぜレイテンシが改善したか？

同期boto3はDynamoDB呼び出し中にPythonスレッドをブロックします。FastAPIはasyncioベースなので、同期呼び出しがイベントループを占有すると並行リクエストの処理が詰まります。aioboto3はawaitableなので、I/O待機中に他のリクエストを処理できます。

### Q: 実際の本番環境との違いは？

検証環境のためDynamoDBはオンデマンド課金のシングルテーブルです。本番ではDAXクラスターによるキャッシュやGSIの設計が追加で必要です。また、マルチAZ構成とPodのtopologySpreadConstraintsも本番では必須です。

---

## 数字の根拠

すべての数値は k6 の `load-tests/results/` に JSON で保存されており、`scripts/compare-results.sh` で再現可能なレポートを生成できます。Grafana ダッシュボード（`dashboards/grafana/`）でも同じメトリクスを可視化しています。
