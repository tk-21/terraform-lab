# ADR 002: RDS Proxy の認証に IAM 認証を採用する

## Status
Accepted

## Context

ECS Fargate タスクから Aurora へ接続する際、認証情報の管理方法を決める必要がある。
選択肢として、Secrets Manager からパスワードを取得する方式と、IAM 認証トークンを使う方式がある。

## Decision

<!-- ここは自分の言葉で書く。なぜ IAM 認証を選んだのか -->

## Consequences

<!-- ここは自分の言葉で書く。IAM 認証トークンの有効期限・取得コスト・ECS タスクへの権限付与 -->
