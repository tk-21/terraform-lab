# ADR-003: VPC Endpoint戦略（Gateway vs Interface）

## ステータス
採用

## 決定

| サービス | Endpoint型 | 理由 |
|---|---|---|
| S3 | Gateway | 無料・ルーティング自動・十分な機能 |
| DynamoDB | Gateway | 無料・S3と同じ理由 |
| SSM | Interface | Gateway型が存在しない |
| SSM Messages | Interface | Session Managerに必須 |
| EC2 Messages | Interface | Run Commandに必須 |

## Gateway型の仕組みと採用理由

- ルートテーブルに `pl-xxxxxx → vpce-xxx` のルートを自動追加
- ENIを作成しないためコストゼロ
- S3・DynamoDBのみ対応（AWSによる制限）
- Security Groupは不要（エンドポイントポリシーでアクセス制御）

## Interface型の仕組みと採用理由

- 指定サブネットにENI（プライベートIP）を作成
- `private_dns_enabled = true` により、DNS名が自動的にENIのIPに解決される
  - 例: `ssm.ap-northeast-1.amazonaws.com` → `10.1.10.x`
  - VPCの `enable_dns_hostnames = true` が前提条件
- 時間課金: $0.014/時/AZ（各Spoke 2AZ = $0.028/時）
- SSM等Gateway型が存在しないサービスに必要

## NAT GW不採用の理由

- Interface EndpointでAWS APIにアクセス可能
- コスト: NAT GW $0.062/時 vs Interface Endpoint $0.014/時/AZ × 2 = $0.028/時
- セキュリティ: インターネット経路を持たないことでアタックサーフェス削減
- Session Managerの動作原理: EC2 → ssmmessages Endpoint → AWSバックボーン → SSM Fleet Manager

## Security Group設計の判断

Interface Endpoint側のSGでEC2からのHTTPS（443）を許可し、EC2側SGはEndpoint SGへのegressのみを許可する。
この責務分離により、新しいEC2を追加してもEndpoint SGへの参照を設定するだけでよく、Inbound SGルールの変更が不要になる。
