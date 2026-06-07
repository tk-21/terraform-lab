# ADR 004: NAT Gateway を廃止し VPC Endpoint のみを使用する

## Status
Accepted

## Context

Private Subnet 内の ECS Fargate タスクが AWS マネージドサービス（ECR、Secrets Manager、SSM など）に
アクセスするための手段として、NAT Gateway と VPC Endpoint の2択がある。
NAT Gateway は HA 構成で2台必要になり、月額コストが約 $65（東京リージョン）発生する。

## Decision

<!-- NAT Gateway との比較をした上での判断を自分の言葉で -->

## Consequences

<!-- コスト・セキュリティ・運用上のトレードオフを自分の言葉で -->
