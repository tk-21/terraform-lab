# ADR 003: Secrets Manager による自動ローテーション戦略

## Status
Accepted

## Context

Aurora の DB ユーザー認証情報をどのように管理・ローテーションするかを決める必要がある。
手動ローテーションは運用ミスのリスクがあり、ECS タスクへの影響を最小化したい。

## Decision

<!-- ここは自分の言葉で書く。7日ローテーション・Lambda Rotator の採用理由 -->

## Consequences

<!-- ここは自分の言葉で書く。RDS Proxy がローテーション中断なく接続を維持できる理由 -->
