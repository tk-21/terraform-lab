# ADR-002: 3 シナリオ設計（Task Kill / Network Disruption / Desired Count 0）

## ステータス: Accepted

## コンテキスト

FIS で検証する ECS 障害シナリオを選定する。ECS Service の回復性を多角的に検証するため、
代表的な障害パターンをカバーするシナリオ構成を定める必要がある。

## 決定

Task Kill / Network Disruption / Desired Count 0 の 3 シナリオを採用する。

## 理由

3 種類が「プロセス障害」「ネットワーク障害」「意図的スケールダウン」をそれぞれ代表する。
異なる障害モードを組み合わせることで ECS Service の回復性を多角的に検証できる。

| シナリオ | 障害種別 | 使用 FIS アクション |
|----------|----------|---------------------|
| Task Kill | プロセス障害 | `aws:ecs:stop-task` |
| Network Disruption | ネットワーク障害 | `aws:ecs:task-network-blackhole-port` |
| Desired Count 0 | 意図的スケールダウン | `aws:lambda:invoke` |

## 各シナリオの観測ポイント

- **S1 (Task Kill)**: ECS Service Controller の自動 Task 再起動速度。desired_count=2 を維持する
  ための新 Task 起動が 120 秒以内に完了することを確認する
- **S2 (Network Disruption)**: ALB ヘルスチェックと Unhealthy Target の切り離し速度。
  Task のネットワークが遮断された際に ALB が 503 を返し、FIS 終了後 60 秒以内に 200 に復旧することを確認する
- **S3 (Desired Count 0)**: DesiredCount 操作による意図的なゼロスケールと復旧手順を確立する。
  Lambda を FIS アクションとして組み込み、意図的な全 Task 停止→手動復旧の手順を文書化する

## トレードオフ

- FIS がネイティブに DesiredCount 変更アクションを持たないため、S3 は Lambda 経由の実装となる
- S2 は PERCENT(50) 以下の遮断率に留めないと ALB が全 Unhealthy になりサービス完全断になる
- 3 シナリオは独立して実行するため、複合障害シナリオ（同時障害）はスコープ外とする
