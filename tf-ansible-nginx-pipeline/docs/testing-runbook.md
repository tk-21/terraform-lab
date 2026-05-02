# テスト実行ランブック

## 1. 静的解析（ローカル開発時・毎回）

```bash
# Terraform
cd terraform/environments/dev
terraform validate
terraform fmt -check -recursive
# tflint（追加インストール推奨）
tflint --recursive

# Ansible
cd ansible
ansible-lint site.yml
```

## 2. Molecule単体テスト（PR作成前・毎回）

```bash
cd ansible
molecule test  # create → converge → idempotency → verify → destroy の完全実行

# 冪等性だけを確認したい場合
molecule converge  # 1回目適用
molecule idempotency  # 2回目適用してchanged=0を確認
```

冪等性チェックの合格基準:
```
PLAY RECAP *******
nginx-test : ok=8  changed=0  unreachable=0  failed=0
                                ^^^^^^^^
                         ここが0であること
```

## 3. Terratest統合テスト（大きな変更のPRマージ前）

```bash
cd tests/terratest
go test -v -timeout 30m -run TestVPCModule

# 特定テストのみ実行
go test -v -timeout 30m -run TestVPCModuleAZVariants/シングルAZ
```

**注意**: 実際のAWSリソースを作成するためコストが発生する。
テスト完了後は t.Cleanup() で自動destroyされることを確認すること。

## 4. Inspecセキュリティ検証（terraform apply後・毎回）

```bash
# Inspecのインストール
gem install inspec inspec-aws

cd tests/inspec
inspec exec . -t aws://ap-northeast-1 --reporter cli json:report.json

# 特定コントロールのみ実行
inspec exec . -t aws://ap-northeast-1 --controls ec2-sg-no-inbound-ssh
```

## 5. Drift検知（毎日自動実行）

GitHub ActionsのDrift Detectionワークフローが毎日午前9時（JST）に実行される。
手動で確認したい場合:

```bash
cd terraform/environments/dev
terraform plan -detailed-exitcode
# exit code 0: 差分なし
# exit code 2: 差分あり（Driftが発生している）
```

## トラブルシューティング

### Moleculeテストが冪等にならない場合

以下を確認:
1. `changed_when: false` を設定すべきタスクに設定されているか
2. タスクが毎回同じ副作用を起こしていないか
3. `notify` の対象が不必要にhandlerを呼び出していないか

### Terratestがタイムアウトする場合

NAT GatewayやVPCエンドポイントの作成は時間がかかる:
```go
// タイムアウト値を増やす
MaxRetries: 5,
TimeBetweenRetries: 10 * 60, // 10分
```
