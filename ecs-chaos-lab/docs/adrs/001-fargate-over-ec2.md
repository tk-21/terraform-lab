# ADR-001: ECS 起動タイプに Fargate を採用

## ステータス: Accepted

## コンテキスト

カオスエンジニアリング検証環境の ECS 起動タイプを選定する。
候補: Fargate / EC2 起動タイプ

## 決定

Fargate を採用する。

## 理由

- EC2 インスタンスの管理（パッチ・スケーリング）が不要でポートフォリオ実装に集中できる
- awsvpc ネットワークモードが標準のため、FIS `aws:ecs:task-network-blackhole-port` が使用可能
- Task ごとに ENI が割り当てられ、FIS のネットワーク遮断がタスクレベルで精密に動作する
- コスト: 使用時間のみ課金（検証後に Task 数 = 0 にすれば EC2 費用ゼロ）

## トレードオフ

- SSM Session Manager 経由のコンテナ接続は `ecs execute-command` が必要
- Fargate での FIS CPU ストレス注入は `aws:ecs:task-cpu-stress` アクション（実験的）
- EC2 起動タイプより若干コストが高い（0.25 vCPU の場合は誤差範囲）
