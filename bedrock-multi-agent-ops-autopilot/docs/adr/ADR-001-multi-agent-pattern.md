# ADR-001: Supervisor + Sub-agentパターンの採用

**ステータス**: Accepted  
**日付**: 2026-04-28

## コンテキスト

AWS運用タスクは障害調査・コスト分析・修復・レポートと多岐にわたる。
単一エージェントでは責務が大きくなりすぎ、プロンプトが複雑化する。
また、すべてのタスクに高性能モデルを使うとコストが増大する。

## 決定

Supervisor Agentが状況を判断し、専門Sub-agentに委譲するパターンを採用する。

- Supervisor: Claude 3.7 Sonnet（高度な推論・委譲判断）
- Sub-agents: Claude 3.5 Haiku（専門タスク実行・コスト削減）

## 理由

- 各Sub-agentのInstructionを専門化でき、プロンプトの品質が上がる
- Sub-agentにHaikuを使うことでコストを削減できる
- 責務分離により個別のテスト・改善が容易になる
- Bedrock Multi-Agent Collaborationのネイティブ機能を活用できる

## トレードオフ

| 観点 | メリット | デメリット |
|---|---|---|
| コスト | Sub-agentをHaikuで実行 | Agent呼び出し回数が増加 |
| 保守性 | 各Agentを独立して改善可能 | 複数AgentのIAM管理が複雑 |
| レイテンシ | 並列委譲が可能 | Agent間通信オーバーヘッドあり |
| 安全性 | Remediationを分離し承認フロー適用可 | 委譲ロジックの誤りリスク |

## 結果

- Bedrock Agent Collaborationでのネイティブ委譲を実装
- Remediationは必ず人間承認後に実行（DynamoDB承認テーブル経由）
- 月額コスト目標: $20以内
