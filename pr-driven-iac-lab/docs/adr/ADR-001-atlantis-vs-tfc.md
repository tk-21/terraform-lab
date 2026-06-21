# ADR-001: AtlantisとTerraform Cloud の選択

## Status
Proposed

## Context
PR-driven IaC ワークフローを導入するにあたり、Atlantis（Self-hosted）と
Terraform Cloud（SaaS）のどちらを採用するかを検討した。

## Options Considered

### Option A: Atlantis on ECS Fargate
- Self-hosted のため、ネットワーク・IAM・インフラ管理が必要
- カスタマイズ性が高い
- コスト: ECS Fargate + ALB の実行コスト

### Option B: Terraform Cloud (Free Tier)
- SaaS のためインフラ管理不要
- 500リソースまで無料
- State管理・UI・監査ログが付属

## Decision

<!-- ここはTakuya本人が記述すること。AIによる記入禁止。 -->
<!-- Phase 5完了後、両方を体験した上で記述する -->

## Consequences

<!-- Phase 5完了後に記述 -->
