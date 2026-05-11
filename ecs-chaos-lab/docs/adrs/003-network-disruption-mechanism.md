# ADR-003: ネットワーク遮断の実装方式（aws:ecs:task-network-blackhole-port）

## ステータス: Accepted

## コンテキスト

ECS Fargate Task のネットワーク遮断を実現する FIS アクションの選定と、
その動作原理を理解した上で設計を確定する。

## 決定

`aws:ecs:task-network-blackhole-port` アクションを採用する。

## 決定と背景

### Fargate / awsvpc モードにおける動作原理

1. Fargate Task は awsvpc ネットワークモードで起動するため、Task ごとに専用の ENI が割り当てられる
2. FIS はこの ENI に対して一時的なネットワーク ACL ルールを追加し、指定ポート（TCP:80）への
   インバウンドトラフィックをブラックホール化する
3. FIS 実験の終了（正常終了・手動停止・停止条件トリガー）と同時にルールが削除され、通信が復旧する

### EC2 起動タイプとの違い

| 項目 | EC2 起動タイプ | Fargate (awsvpc) |
|------|----------------|------------------|
| FIS アクション | `aws:network:disrupt-connectivity` | `aws:ecs:task-network-blackhole-port` |
| 操作対象 | EC2 インスタンスの NIC | Task の ENI |
| 粒度 | インスタンス単位 | Task 単位（精密） |
| awsvpc 要件 | 不要 | 必須 |

## 注意事項

- `trafficType: ingress` + `port: 80` で ALB からの HTTP ヘルスチェックをブラックホール化する
- 遮断対象は PERCENT(50) 以下に設定すること（本実装では PERCENT(50) を採用）。
  PERCENT(100) にすると全 Task が Unhealthy になりサービス完全断になる
- FIS 実験の duration は `PT3M`（3 分）に設定し、長期間の断を防ぐ
- 停止条件に `HealthyHostCount = 0` アラームを設定し、全断を自動検知して実験を強制停止する
