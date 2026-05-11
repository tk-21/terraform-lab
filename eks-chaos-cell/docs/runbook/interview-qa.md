# 技術面接 想定Q&A

## Q1: Cell Architectureとは何ですか？なぜ必要ですか？

**A**: Amazonが大規模サービスで採用している可用性設計パターンです。
システムを独立した「Cell」に分割し、1つのCellの障害が他のCellに
伝播しないようにすることで、障害の影響範囲（Blast Radius）を
意図的に小さく制限します。

今回の実装では：
- Cell-A（AZ-a）とCell-B（AZ-c）が独立したKarpenter NodePoolを持つ
- 各Cellは独立したALB Target Groupに登録される
- FISでCell-AのEC2を全停止しても、Cell-BのPodとNodeはまったく影響を受けない

これをFIS実験で実証し、Cell-Bのエラー率が実測でX%だったことを確認しました。

---

## Q2: KarpenterとCluster Autoscalerの違いは何ですか？

**A**: 最大の違いはノード選択の単位です。

Cluster AutoscalerはNode Groupのサイズを増減します。
つまり「どのEC2タイプを使うか」はNode Group作成時に決まります。

KarpenterはPendingなPodの要求（CPU・Memory・NodeSelector）を見て、
最適なEC2インスタンスタイプをリアルタイムで選択してRunInstancesします。
Node Groupを経由しないため、スポットと On-Demandの混在、
arm64とx86_64の使い分けがNodePool定義1つで実現できます。

今回の実装ではFIS実験後にKarpenterが新規ノードをXX秒で起動することを確認しました。

---

## Q3: PodDisruptionBudgetはなぜ必要ですか？

**A**: PDBがないと、ノードドレイン（KarpenterのConsolidationやKubernetes upgrade）時に、
同じノードに乗っているPodが全て同時に退避される可能性があります。

minAvailable: 2 を設定することで、4Pod中常に2台以上の稼働を保証します。
FIS実験でEC2が停止されてKarpenterがドレインをかける際も、
PDBの制約内でローリングに退避が行われるため、サービス断が発生しません。

---

## Q4: カオスエンジニアリングをやるにあたって気をつけたことは？

**A**: 3つの安全機構を設計しました。

1. **ターゲットタグによる絞り込み**: `chaos-target=true` `chaos-cell=cell-a` タグが
   付いたEC2のみをFIS実験のターゲットにしました。システムノード（Karpenter自体が動くノード）
   には `chaos-target=false` を付けて絶対に触らないようにしました。

2. **Stop Condition**: ALBの5xxエラーが1分間に10件を超えたらFIS実験が自動停止します。
   実験が意図以上の影響を出し始めた瞬間に自動で止まります。

3. **実験時間の上限**: 全テンプレートに6分の上限を設定しました。
   Stop Conditionが発火しなくても自動終了します。

---

## Q5: なぜGrafanaをセルフホストではなくAMGにしたのですか？

**A**: 観測基盤自体が単一障害点になることを避けるためです。

EKSクラスター上にGrafanaをデプロイした場合、EKSクラスターの障害時に
観測基盤も同時に失われます。AMGはEKSとは独立したマネージドサービスのため、
EKSクラスターが落ちている最中でもGrafanaから障害の様子を観測できます。

これがFIS実験中にリアルタイムで回復の様子を確認できた理由です。
