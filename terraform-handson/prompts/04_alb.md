# Step 4 — ALB + Auto Scaling プロンプト集

## コードを改造して学ぶ

```
ASG の desired_capacity を 1 に変更して terraform apply してください。
その後ブラウザで何度アクセスしても同じ Instance ID が表示されることを確認してください。
次に desired_capacity を 3 に戻して、再度リロードして振り分けを確認してください。
```

```
04_alb/main.tf に ALB のアクセスログを記録する S3 バケットを追加してください。
aws_lb リソースの access_logs ブロックを有効化し、
バケットポリシーも Terraform で設定してください（ALB からの書き込み権限が必要）。
```

```
ALB に HTTP → HTTPS リダイレクトの設定を追加してください。
（実際の SSL 証明書がなくても、Listener の設定構造を理解することが目的です）
443 番の Listener と aws_acm_certificate の使い方をコード例として示してください。
```
