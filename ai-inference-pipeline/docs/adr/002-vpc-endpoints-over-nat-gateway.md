# ADR-002: NAT GatewayではなくVPC Endpointを採用

## ステータス
Accepted

## コンテキスト
ECS FargateタスクおよびLambdaがECR、S3、Bedrock、DynamoDB等の
AWSサービスにアクセスする手段が必要だった。

## 決定
NAT Gatewayを使用せず、VPC Endpointのみでプライベート通信を実現する。

## 決定の根拠
<!-- 自分の言葉で記述（AI生成禁止） -->
<!-- 以下を含めること: -->
<!-- - NAT Gatewayのコストをざっくり計算してみた結果 -->
<!-- - Gateway型とInterface型を使い分けた判断基準 -->
<!-- - Bedrock用のInterface Endpointがなぜ必要か -->

（ここに自分の言葉で記述する）

## 検討した代替案とその棄却理由
<!-- 自分の言葉で記述 -->

## 結果と振り返り
<!-- 実装後に感じたこと・気づきを自分の言葉で記述 -->
