# Step 3 — RDS プロンプト集

## コードを改造して学ぶ

```
RDS のパスワードを -var で渡すのではなく terraform.tfvars ファイルで
管理するように変更してください。
また、terraform.tfvars が .gitignore に含まれていることを確認してください。
なぜ tfvars を Git に含めてはいけないか理由も説明してください。
```

```
03_rds/main.tf に以下を追加してください:
- RDS の自動バックアップを有効化（retention: 7日）
- バックアップウィンドウを "19:00-20:00"（JST 04:00-05:00 UTC）に設定
- メンテナンスウィンドウを "mon:20:00-mon:21:00" に設定

変更後に plan で差分を確認し、これらの設定が本番でなぜ重要か説明してください。
```

```
RDS の Enhanced Monitoring を有効化してください。
必要な IAM Role も Terraform で作成し、monitoring_interval = 60 に設定してください。
Enhanced Monitoring で何が監視できるか説明してください。
```
