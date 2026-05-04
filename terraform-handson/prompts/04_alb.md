# Step 4 — ALB + Auto Scaling プロンプト集

## 学習目標
- ALB / Target Group / Listener の3層構造を理解する
- Launch Template で EC2 の雛形を定義する
- ASG でスケーラブルな構成を体験する
- ヘルスチェックとスケーリングポリシーの仕組みを理解する

---

## 🟢 Step 1: 初期構築・動作確認

```
04_alb ディレクトリで terraform apply を実行してください。

  VPC_ID=$(cd ../01_vpc && terraform output -raw vpc_id)
  PUB_SUBNETS=$(cd ../01_vpc && terraform output -json public_subnet_ids | jq -c '.')

  terraform apply \
    -var="vpc_id=$VPC_ID" \
    -var="public_subnet_ids=$PUB_SUBNETS"

apply 完了後、terraform output の web_url にブラウザでアクセスし、
ページを何度かリロードして、Instance ID が変わることを確認してください。
（ALB が複数の EC2 にリクエストを振り分けていることを体感する）
```

```
AWS コンソールの EC2 > ターゲットグループ から Target Group のヘルスチェック状態を確認してください。
全インスタンスが "healthy" になっていますか？
"initial" のまま時間がかかっている場合は理由を教えてください。
```

---

## 🔵 Step 2: コードを読んで理解する

```
04_alb/main.tf の Security Group が ALB 用と EC2 用の2つに分かれている理由を説明してください。
1つにまとめることもできますが、2つに分けることでどんなメリットがありますか？
```

```
04_alb/main.tf の aws_lb_target_group のヘルスチェック設定を読んで、
以下を説明してください:
- healthy_threshold / unhealthy_threshold / interval / timeout の意味
- EC2 が unhealthy と判定されると ASG はどう動作しますか？
```

```
04_alb/main.tf の aws_launch_template と aws_autoscaling_group の関係を説明してください。
Launch Template を直接 EC2 に使う場合と ASG で使う場合の違いは何ですか？
```

```
04_alb/main.tf の aws_autoscaling_policy の target_tracking_configuration について、
CPU 60% をターゲットにするとはどういう意味か説明してください。
スケールアウト・スケールインそれぞれのタイミングも説明してください。
```

---

## 🟡 Step 3: コードを改造して学ぶ（スケーリング体験）

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

---

## 🔴 トラブルシュート

```
ALB の Target Group でインスタンスが "unhealthy" になっています。
以下を順番に確認してください:
1. EC2 上で Apache が起動しているか（UserData が正常に実行されたか）
2. EC2 の Security Group が ALB からの 80 番を許可しているか
3. ヘルスチェックのパス（/）で 200 が返っているか
4. health_check_grace_period が短すぎないか

確認結果を報告して原因を特定してください。
```

```
リロードしても同じ EC2 にしかアクセスされません。
ALB のセッションスティッキー設定を確認してください。
また、スティッキーセッションを無効化する方法を教えてください。
```

```
terraform apply でこのエラーが出ました。原因と修正方法を教えてください。
---
[エラーをここに貼り付ける]
---
```

---

## 🏁 ハンズオン終了時

```
ハンズオンが終了したら、コスト削減のため全リソースを削除してください。
依存関係があるため、以下の順番で destroy を実行してください:

  cd 04_alb && terraform destroy -auto-approve
  cd ../03_rds && terraform destroy \
    -var="vpc_id=$(cd ../01_vpc && terraform output -raw vpc_id)" \
    -var='private_subnet_ids=[]' \
    -var="ec2_security_group_id=dummy" \
    -var="db_password=dummy" \
    -auto-approve
  cd ../02_ec2 && terraform destroy \
    -var="vpc_id=$(cd ../01_vpc && terraform output -raw vpc_id)" \
    -var="public_subnet_id=dummy" \
    -auto-approve
  cd ../01_vpc && terraform destroy -auto-approve

全ての destroy 完了後、AWS コンソールでリソースが残っていないか確認してください。
```
