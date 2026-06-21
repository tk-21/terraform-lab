# ADR 003 — ECS デプロイ戦略の選定

## ステータス
採用

## 背景
[ECS のデプロイ方法がいくつかある中でどれを選ぶか検討した経緯]

## 決定
Blue/Green デプロイ (CodeDeploy) を採用する

## 理由
[Blue/Green を選んだ実際の理由を書く — 実際に設定してわかったことを含めて]

## トレードオフ
[Blue/Green のデメリット: 設定の複雑さ、コスト、制約など]

## 代替案
- Rolling Update (ECS デフォルト)
- Canary デプロイ
- CodeDeployDefault.ECSLinear10PercentEvery1Minute
