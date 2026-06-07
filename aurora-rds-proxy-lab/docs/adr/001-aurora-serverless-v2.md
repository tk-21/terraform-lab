# ADR 001: Aurora Serverless v2 を採用する

## Status
Accepted

## Context

このラボでは ECS Fargate アプリケーションのバックエンドとして PostgreSQL 互換の RDB を用意する必要がある。
選択肢として Aurora Provisioned、Aurora Serverless v2、RDS for PostgreSQL が挙げられた。
dev 環境では常時高負荷が発生しないため、アイドル時のコストを最小化したい。

## Decision

<!-- 以下の観点を自分の言葉で記述する（口頭説明の素材になる） -->

<!--
考慮点:
- なぜ db.t3.micro (Provisioned) ではなく Serverless v2 を選んだか
  - ハンズオン環境でのコスト最適化（アイドル時間の長さ）
  - ACU スケーリングの恩恵（負荷テスト時の応答性）
- min_capacity = 0.5 ACU にした根拠
  - cold start 回避 vs コスト最小化のトレードオフ
- manage_master_user_password = true を使った理由
  - Secrets Manager との統合を AWS に任せる（自前で random_password + secret を作らない）
  - Phase 4 のローテーション設計への布石
- engine_mode = "provisioned" なのに「Serverless」と呼ぶ理由
  - Serverless v1 (engine_mode=serverless) との違い
-->

## Consequences

<!-- 以下の観点を自分の言葉で記述する -->

<!--
考慮点:
- ACU スケーリングの遅延（数秒程度）: ハンズオン用途では許容できるか
- コスト予測:
  - idle 時: 0.5 ACU × $0.12/ACU-hr × 24h = ~$1.44/日
  - ピーク時: 4 ACU × $0.12/ACU-hr（短時間のみ）
- Performance Insights + Enhanced Monitoring を有効にしたコスト影響
  - PI: 7日間無料、60日間 $0.02/vCPU-hr
  - Enhanced Monitoring 60秒間隔: $0.50/インスタンス/月
- deletion_protection = true による cleanup 手順の複雑化
  - Phase 6 で一時解除が必要な理由の明記
-->
