# Troubleshooting Slide Summary

発表スライドにそのまま転記しやすい、今回のつまずきポイントの要約版です。

## つまずいたポイント

- Terraform apply が EKS / IAM data source で止まった
  - 原因は Terraform 定義よりネットワーク不調
  - 学び: まず `aws sts get-caller-identity` で認証と疎通を確認する

- Ingress URL を開いても画面が出なかった
  - 原因は `internal` ALB
  - 学び: 本番確認は `port-forward` と `rollout status` でも十分

- MVP モードで何を聞いてもヒットしなかった
  - 原因はダミーチャンク固定 + 単純検索
  - 対応: `docs/sample_knowledge` をローカル検索対象に変更

- EKS に再デプロイしても修正が反映されなかった
  - 原因は `:dev` タグの再利用
  - 対応: ユニークタグで build/push し、`APP_IMAGE=... make deploy`

- Bedrock モデル周りで複数回つまずいた
  - `use case details` 未完了
  - `Legacy` モデル指定
  - Sonnet 4 は inference profile 必須
  - Marketplace 権限不足

## 発表用の一言まとめ

- ハマりどころはアプリ実装よりも「周辺条件」に多かった
- 特に Bedrock は、モデル名を入れるだけでは動かず、利用申請、モデル状態、呼び出し方式、Marketplace 権限まで考慮が必要だった
- その分、一度 README と IaC に反映すると、次回の再現性はかなり上がる

## 総括

- 躓きポイントは「権限まわり」だけではなく、認証、ネットワーク、ALB、Bedrock のサービス仕様まで含む周辺前提条件だった
- その中でも、最も影響が大きかったのは Bedrock の権限と利用条件の組み合わせだった

## スライド向け 3 行版

- Terraform / EKS / Bedrock の統合では、障害点がコード・認証・ネットワーク・サービス制約に分散する
- Bedrock は `Active/Legacy`、inference profile、Marketplace 権限など、モデルごとの運用条件確認が重要
- README と Terraform に学びを反映し、再デプロイ手順と切り分け精度を改善した
