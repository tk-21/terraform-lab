# ADR-001: AZ分離ではなくCell Architectureを採用する

## ステータス

採用（Accepted）

## コンテキスト

EKSの高可用性設計において以下の選択肢を検討した。

| アプローチ | 説明 |
|-----------|------|
| AZ分散 | topologySpreadConstraintsでPodをAZ間に分散 |
| Cell Architecture | AZ単位でWorkload・NodePool・NetworkingをCell化 |
| Multi-Cluster | AZごとに独立したEKSクラスター |

## 決定

**Cell Architectureを採用する**

## 理由

### AZ分散だけでは不十分な理由

AZ分散はPodの配置を分散するが、以下の問題が残る。

1. **Kubernetes Control Plane の単一障害点**: kube-apiserver障害でCell全体に影響
2. **DaemonSet の同一ノード問題**: DaemonSetはノード単位で動くため、ノード障害で複数PodのDaemonSetが同時に失われる
3. **ノードドレイン時の影響範囲**: KarpenterのConsolidationが両AZのPodを同時に退避する可能性がある
4. **Blast Radiusが計算できない**: 「AZ-aが落ちたら何%のトラフィックが影響を受けるか」が不明瞭

### Cell Architectureが解決すること

- **明確なBlast Radius**: Cell-A障害はCell-Aの50%トラフィックにのみ影響（2 Cell構成なのでALBが均等分散）
- **独立したNodePool**: KarpenterのConsolidationがCell境界を越えない
- **独立したTarget Group**: ALBがCell単位でヘルスチェックするため、Cell-A全滅時も Cell-BへのルーティングがALBレイヤーで保証される

### Multi-Clusterを採用しなかった理由

- 管理コストが高い（2倍のControl Plane費用・2倍のADD管理）
- ArgoCDやFluxによるGitOps設定が2倍になる
- 本プロジェクトの目的（実証・学習）には過剰

## トレードオフ

- NodePoolをCell単位で分けることでノードの利用効率が下がる可能性がある
- Cell-AとCell-Bで同一アプリを動かすためリソースが2倍必要

## 結果

FIS実験で Cell-AのEC2を全停止した際、Cell-B への影響がゼロであることを実測で確認した。
