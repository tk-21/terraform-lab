# Runbook: tgw-multi-vpc-lab

## 構成確認

### TGWルートテーブル確認
```bash
SPOKE_RT_ID=$(terraform -chdir=envs/ap-northeast-1 output -raw spoke_route_table_id)
HUB_RT_ID=$(terraform -chdir=envs/ap-northeast-1 output -raw hub_route_table_id)

# Spoke RTのルート一覧
aws ec2 search-transit-gateway-routes \
  --transit-gateway-route-table-id "$SPOKE_RT_ID" \
  --filters "Name=state,Values=active"

# Hub RTのルート一覧
aws ec2 search-transit-gateway-routes \
  --transit-gateway-route-table-id "$HUB_RT_ID" \
  --filters "Name=state,Values=active"
```

### アタッチメントとルートテーブルの関連付け確認
```bash
SPOKE_RT_ID=$(terraform -chdir=envs/ap-northeast-1 output -raw spoke_route_table_id)

aws ec2 get-transit-gateway-route-table-associations \
  --transit-gateway-route-table-id "$SPOKE_RT_ID"
```

## トラブルシューティング

### 症状: Spoke-A → Hub に ping が通らない

確認手順:
1. TGWアタッチメントのStateがavailableか確認
2. Spoke RTにHubのCIDR（10.0.0.0/16）のルートが存在するか確認
3. Hub RTにSpoke-AのCIDR（10.1.0.0/16）のルートが存在するか確認
4. Spoke-AのVPCルートテーブルにTGWへのルートが存在するか確認
5. EC2のセキュリティグループがICMPを許可しているか確認

### 症状: SSM Session Managerで接続できない

確認手順:
1. VPCエンドポイント（ssm, ssmmessages, ec2messages）が存在するか確認
2. エンドポイントのSGがEC2からの443を許可しているか確認
3. EC2のIAMロールにAmazonSSMManagedInstanceCoreが付与されているか確認
4. SSMエージェントが起動しているか確認（起動直後は2〜3分待つ）
