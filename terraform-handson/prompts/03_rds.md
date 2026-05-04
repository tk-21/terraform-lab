# Step 3 — RDS プロンプト集

## 学習目標
- DB Subnet Group で RDS を特定サブネットに配置する
- Security Group で EC2 からのみ DB 接続を許可する
- `sensitive = true` で機密変数を安全に扱う
- パラメータグループで文字コードを設定する

---

## 🟢 Step 1: 初期構築・動作確認

```
03_rds ディレクトリで terraform apply を実行してください。

以下のコマンドで前 Step の値を取得してから apply してください:
  VPC_ID=$(cd ../01_vpc && terraform output -raw vpc_id)
  PRIV_SUBNETS=$(cd ../01_vpc && terraform output -json private_subnet_ids | jq -c '.')
  EC2_SG=$(cd ../02_ec2 && terraform output -raw security_group_id)

  terraform apply \
    -var="vpc_id=$VPC_ID" \
    -var="private_subnet_ids=$PRIV_SUBNETS" \
    -var="ec2_security_group_id=$EC2_SG" \
    -var="db_password=Handson1234!"

※ RDS の作成には 5〜10 分かかります。待機中に次の理解確認を進めてください。
```

```
apply 完了後、02_ec2 の EC2 に SSH またはセッションマネージャーで接続し、
RDS エンドポイントに MySQL クライアントで接続できることを確認してください。

  # EC2 上で実行
  sudo dnf install -y mariadb105
  mysql -h <db_endpoint> -u admin -p handsondb
  # パスワード: Handson1234!

  # MySQL 接続後に実行
  SHOW DATABASES;
  CREATE TABLE users (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(100));
  INSERT INTO users (name) VALUES ('terraform'), ('handson');
  SELECT * FROM users;
```

---

## 🔵 Step 2: コードを読んで理解する

```
03_rds/main.tf の Security Group で ingress の cidr_blocks ではなく
security_groups = [var.ec2_security_group_id] を使っている理由を説明してください。
CIDR 指定と SG 指定のセキュリティ上の違いは何ですか？
```

```
03_rds/main.tf で RDS をプライベートサブネットに配置している理由と、
publicly_accessible = false の意味を説明してください。
もし publicly_accessible = true にしたらどうなりますか？
```

```
03_rds/variables.tf の db_password に sensitive = true を設定しています。
これを設定しないとどんな問題が起きますか？
terraform plan と terraform apply の出力でどう違いが出ますか？
```

```
03_rds/main.tf の aws_db_parameter_group で utf8mb4 を設定しています。
utf8 と utf8mb4 の違いと、utf8mb4 を使うべき理由を説明してください。
```

---

## 🟡 Step 3: コードを改造して学ぶ

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

---

## 🔴 トラブルシュート

```
RDS の apply に失敗しました（または 15 分以上かかっています）。
現在の状態を確認して、原因と対処法を教えてください。

よくある原因:
- プライベートサブネットが2つ存在しない
- DB Subnet Group のサブネットが異なる AZ にない
- パスワードが要件を満たさない（8文字以上・英数字記号含む）
```

```
EC2 から RDS に接続できません（接続タイムアウト）。
以下を順番に確認してください:
1. RDS の Security Group の ingress ルール
2. ingress に指定している EC2 の SG ID が正しいか
3. RDS の publicly_accessible 設定
4. EC2 と RDS が同じ VPC にあるか
```

```
terraform plan でこのエラーが出ました。原因と修正方法を教えてください。
---
[エラーをここに貼り付ける]
---
```
