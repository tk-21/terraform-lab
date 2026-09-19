# Zenn記事アウトライン

## タイトル案

**第一候補**:
「KEDAを使わずKubernetes Operatorをゼロから書いてGPU推論をオートスケールした話」

**第二候補**:
「Goで書くKubernetes Operator: vLLM on EKSのスケーリング・フォールバック・自己修復をCRD一枚で管理する」

**対象読者**: Kubernetesに慣れているが、Operatorパターンを実装したことはないエンジニア

---

## 章立て

### 0. はじめに(600字)

- このプロジェクトを始めた動機: KEDAやKarpenterを「使う」プロジェクトはやったが、
  その裏で何が起きているか理解できていないと感じた
- 「1人でシステム全レイヤーの意思決定をする」体験の価値を宣言する
- 成果物の概要: AIInferenceService CRD + Operator + Terraform + CI/CD

---

### 1. Operatorパターンとは何か、なぜ自作するのか(1200字)

- reconcile loopの説明: 「現状と理想の差分を埋め続けるループ」
- KEDAとの比較: KEDAはスケール判定だけ、自作するとフォールバック・自己修復・通知を統合できる
- controller-runtime / kubebuilder の位置づけ
- **使う数値**: KEDA polling 15秒 vs 自作 5秒の検知レイテンシ差

---

### 2. CRD設計: AIInferenceServiceのspec設計で悩んだこと(1500字)

- CRDのspecを見せる(コードブロック)
- `scalingMetric`の型選択: queueDepth / gpuUtilization の2種類にした理由
- `bedrockFallback`を同一specに含めることへの是非(賛否を正直に書く)
- Finalizer設計: なぜFinalizer無しだとGPUノードが残留するか
- **ADRとの対応**: ADR 0001, 0002

---

### 3. Reconcileループ実装: 状態遷移図を書いてからコードを書く(2000字)

```
Running → Provisioning → Fallback → Running
Running → Degraded (手動介入必要)
```

- 状態ごとのreconcile処理の切り分け方
- `status.conditions`の設計(KEDAのCondition仕様を参考にしつつ独自化)
- 冪等性の担保: `controllerutil.CreateOrUpdate`の使い方
- **実装で詰まったポイント**: roleBinding/ServiceAccountの更新ループ

---

### 4. カスタムオートスケーリング: ヒステリシスがなぜ必要か(1800字)

- 単純閾値でのフラッピング再現(ログを貼る)
- `scaleDownThresholdRatio=0.7`で解消した仕組みの説明
- SQSキュー深度メトリクスの取得方法(Prometheus Exporter経由)
- **使う図**: benchmarks/scaling-latency.md の計測表
- **使う数値**: 5s vs 15s ポーリングの比較(TBD → 実測後に更新)

---

### 5. Bedrockフォールバック: GPUコールドスタートの現実と対処(2000字)

- g5g.xlargeコールドスタートの実測値と内訳(TBD)
- 90秒タイムアウトの根拠: BEP計算(25リクエスト/4分)を見せる
- `status.activeBackend`でフォールバック中かどうかを可視化する設計
- 切り戻し時の「偽の劣化」問題とクールダウン設計
- **使う計算式**: benchmarks/gpu-coldstart-vs-bedrock-cost.md のBEP計算

---

### 6. 自己修復: OOMKilledをOperatorが自動で直す(1500字)

- OOMKillの検知方法: Pod.status.containerStatuses[].lastState.terminated.reason
- メモリlimitを25%増量してrolling updateする実装
- `status.restartCount`をK8s標準のPod restartCountと別管理にした理由
- `maxRestartAttempts=3`でDegradedに遷移させる判断
- Chatwork通知との統合

---

### 7. Admission Webhook: 「入口で弾く」の価値(1200字)

- ValidatingWebhookでGPU limit必須チェック等を実装した経緯
- MutatingWebhookでdefault値を埋める責務分担
- 「既存CRDにWebhookを後から追加する」場合のfailurePolicy切り替え手順
- cert-managerを使ったTLS証明書管理

---

### 8. Observability: Operatorを監視するPrometheusメトリクス設計(1200字)

- 公開したカスタムメトリクスの一覧と選定理由
  - `gpu_inference_reconcile_duration_seconds`
  - `gpu_inference_fallback_total`
  - `gpu_inference_oom_recovery_total`
  - `gpu_inference_scaling_events_total`
- PrometheusRuleでアラート設計した項目
- Grafanaダッシュボードの構成

---

### 9. CI/CD: OIDC + arm64マルチアーキビルドの詰まりポイント(1200字)

- GitHub Actions OIDC認証の設定: `aud`クレームで詰まった話
- `docker buildx`のマルチアーキビルドとECRへのpush
- golangci-lint / envtestの並列実行でCI時間を短縮した方法
- **使う数値**: CI実行時間(TBD)

---

### 10. 1人で全レイヤーを決めて得たもの(終章 / 1500字)

- 小規模チーム・ひとりプロジェクトで全意思決定をした文脈を強みとして書く
  - TerraformからKubernetesコントローラーからCI/CDまで、依頼先がない状態で設計する体験
  - 「正解がない中でトレードオフを文章化する」(ADR)習慣の価値
- 未解決課題を正直に書く
  - 実EKSでの実測値がTBD
  - 段階的切り戻し(traffic weight)はPhaseアウトのスコープ
  - GPU利用率メトリクス(DCGM Exporter)との連携は試験的
- 次にやるなら何を変えるか
  - AI Gateway(Envoy)を挟んでtraffic splittingを本格対応
  - 動的フォールバック閾値(履歴から自動調整)

---

## 各章で使う実測データ・図の対応表

| 章 | 使う素材 | ファイル |
|---|---|---|
| 1 | KEDA 15s vs 自作 5s レイテンシ | benchmarks/scaling-latency.md |
| 4 | スケール検知レイテンシ比較表 | benchmarks/scaling-latency.md |
| 5 | BEP計算・コールドスタート実測 | benchmarks/gpu-coldstart-vs-bedrock-cost.md |
| 全体 | アーキテクチャ図 | docs/architecture.mmd |
| 3 | 状態遷移図 | controllers/aiinferenceservice_controller.go |

---

## 執筆の優先順位

1. 章 5(Bedrockフォールバック): BEP計算があり最も独自性が高い
2. 章 3(Reconcileループ): Operatorパターンの核心、読者ニーズが高い
3. 章 6(自己修復): OOMKill実装の経験談は差別化になる
4. 章 4(ヒステリシス): フラッピング再現ログが取れれば説得力が増す
5. その他章: 実測データが揃い次第更新

---

## 公開タイミングの判断基準

- [ ] 実EKSでスケーリングレイテンシを実測し、benchmarks/scaling-latency.md を埋める
- [ ] コールドスタート実測値を benchmarks/gpu-coldstart-vs-bedrock-cost.md に記入する
- [ ] ADR全件のDecisionセクションを自分の言葉で書く
- [ ] 章1〜6の下書きが揃う
