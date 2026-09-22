# Step 1 — VPC プロンプト集

## コードを改造して学ぶ

```
01_vpc/variables.tf の public_subnet_cidrs を 3つに増やして、
3つ目の AZ のパブリックサブネットも作成されるように変更してください。
変更後に terraform plan で差分を確認し、追加されるリソースを説明してください。
```

```
01_vpc/main.tf に VPC Flow Logs を追加してください。
ログの送り先は CloudWatch Logs とし、IAM Role も Terraform で作成してください。
なぜ Flow Logs が必要か（セキュリティ上の意味）も説明してください。
```

```
01_vpc/main.tf の locals に Terraform を実行したユーザーの情報を
タグとして追加する方法を調べて実装してください。
（ヒント: data "aws_caller_identity"）
```
