# ✅Phase 5: テスト・検証方法論

## このフェーズで達成すること

「壊れたら気づく」仕組みを多層的に構築する。
Terratest（Goでのインフラ検証）、Molecule（Ansible冪等性）、Inspec（ポリシー準拠）、
Drift検知（terraform plan in CI）の4層テスト体制を実装する。

## Phase 4からの引き継ぎ

- Terraform × Ansible × GitHub Actionsの統合パイプラインが完成済み
- EC2にnginxがデプロイ済み

---

## Task 5-1: テスト戦略ドキュメントの生成

`docs/testing-strategy.md` を作成してください:

```markdown
# インフラテスト戦略

## テストピラミッド（インフラ版）

```
         /\
        /  \
       / E2E \      ← Inspec: 本番環境のポリシー準拠確認
      /--------\
     / 統合テスト \   ← Terratest: apply→assert→destroyの完全サイクル
    /------------\
   /  単体テスト   \  ← Molecule: Ansible Role単体の冪等性確認
  /--------------\
 /  静的解析      \  ← terraform validate, fmt, tflint, ansible-lint
/------------------\
```

## 各テスト層の責務

| 層 | ツール | 何を確認するか | 実行タイミング |
|----|--------|--------------|--------------|
| 静的解析 | terraform validate/fmt, ansible-lint | 構文・スタイル | PRのpush時（毎回）|
| 単体テスト | Molecule | Roleの冪等性・機能 | PRのpush時（毎回）|
| 統合テスト | Terratest | リソース作成の正確性 | PRのマージ前 |
| E2E/ポリシー | Inspec | セキュリティポリシー準拠 | apply後（毎回）|
| Drift検知 | terraform plan in CI | 手動変更の検出 | 定期実行（毎日）|

## テストの設計原則

1. **テストコードはIaCコードと同じリポジトリで管理する**
   - インフラとテストのバージョンを一致させるため

2. **テストは実際のAWSリソースを作成して確認する（Terratest）**
   - モックでは検証できない依存関係やIAMポリシーの問題を発見するため

3. **テスト後は必ずterraform destroyする**
   - コスト管理と環境のクリーン性を維持するため

4. **冪等性テストは必ず2回実行する（Molecule）**
   - 1回目: リソースの作成（changed > 0）
   - 2回目: 再実行してchanged = 0を確認する
```

---

## Task 5-2: Terratestコードの生成

`tests/terratest/vpc_test.go` を作成してください:

```go
// =============================================================================
// Terratest: VPCモジュールの統合テスト
// 設計思想:
//   1. 実際のAWSにリソースを作成して検証する（モックなし）
//   2. テスト完了後は必ずdestroyして費用を最小化する
//   3. Goのt.Cleanup()でテスト失敗時も確実にdestroyする
// =============================================================================

package test

import (
	"testing"
	"fmt"

	"github.com/gruntwork-io/terratest/modules/aws"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestVPCModule(t *testing.T) {
	// テスト並列実行を許可（Terratestのベストプラクティス）
	t.Parallel()

	awsRegion := "ap-northeast-1"

	terraformOptions := &terraform.Options{
		// テスト専用の一時的なディレクトリを指定
		TerraformDir: "../../terraform/environments/dev",

		// テスト用変数（本番設定を上書き）
		Vars: map[string]interface{}{
			"environment": fmt.Sprintf("test-%s", t.Name()),
		},

		// Terraform操作のタイムアウト設定
		// NAT Gatewayの作成には5-10分かかる
		MaxRetries:         3,
		TimeBetweenRetries: 5 * 60, // 5分
	}

	// テスト終了時（成功・失敗問わず）に必ずdestroyする
	// t.Cleanup() はテスト失敗時も実行されることが保証される
	t.Cleanup(func() {
		terraform.Destroy(t, terraformOptions)
	})

	// terraform init & apply
	terraform.InitAndApply(t, terraformOptions)

	// ==========================================================================
	// 検証1: VPC IDが取得できること
	// ==========================================================================
	vpcID := terraform.Output(t, terraformOptions, "vpc_id")
	require.NotEmpty(t, vpcID, "VPC IDが空です")

	// AWSに実際に存在するVPCかどうかを確認
	vpc := aws.GetVpcById(t, vpcID, awsRegion)
	assert.Equal(t, "10.0.0.0/16", vpc.CidrBlock,
		"VPCのCIDRブロックが期待値と異なります")

	// ==========================================================================
	// 検証2: プライベートサブネットが正しく作成されていること
	// ==========================================================================
	// terraform outputはJSON配列として返る
	privateSubnetIDs := terraform.OutputList(t, terraformOptions, "private_subnet_ids")
	assert.Equal(t, 2, len(privateSubnetIDs),
		"プライベートサブネットが2つ作成されていること（az_count=2のため）")

	for _, subnetID := range privateSubnetIDs {
		subnet := aws.GetSubnetById(t, subnetID, awsRegion)

		// サブネットがVPCに紐付いていること
		assert.Equal(t, vpcID, subnet.VpcId)

		// プライベートサブネットはパブリックIPの自動割り当てをしないこと
		assert.False(t, subnet.MapPublicIpOnLaunch,
			"プライベートサブネットはMapPublicIpOnLaunchがfalseであるべき")
	}

	// ==========================================================================
	// 検証3: EC2インスタンスがSSMで管理されていること
	// ==========================================================================
	instanceID := terraform.Output(t, terraformOptions, "instance_id")
	require.NotEmpty(t, instanceID)

	// SSMマネージドインスタンスとして登録されているか確認
	// （IAMロールとSSMエージェントが正しく設定されている証明）
	ssmClient := aws.NewSsmClient(t, awsRegion)

	// インスタンスがSSMに登録されるまで最大5分待機
	aws.WaitForSsmInstance(t, awsRegion, instanceID, 30)

	instanceInfo, err := ssmClient.DescribeInstanceInformation(...)
	require.NoError(t, err)
	assert.Equal(t, "Online", instanceInfo.PingStatus,
		"EC2インスタンスがSSM Onlineになっていること")

	// ==========================================================================
	// 検証4: セキュリティグループにインバウンドルールがないこと
	// ==========================================================================
	// EC2のSGはアウトバウンドのみ（SSMセッションマネージャーを使うため）
	ec2SGID := terraform.Output(t, terraformOptions, "ec2_security_group_id")
	sg := aws.GetSecurityGroupById(t, ec2SGID, awsRegion)

	assert.Empty(t, sg.IpPermissions,
		"EC2セキュリティグループにインバウンドルールが存在してはいけません（SSM設計）")
}

// =============================================================================
// Terratestのコツ: テーブル駆動テストで複数シナリオを検証
// =============================================================================
func TestVPCModuleAZVariants(t *testing.T) {
	t.Parallel()

	testCases := []struct {
		name    string
		azCount int
		wantSubnets int
	}{
		{"シングルAZ", 1, 1},
		{"マルチAZ", 2, 2},
	}

	for _, tc := range testCases {
		tc := tc // ループ変数のキャプチャ（Goのよくある落とし穴）
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			opts := &terraform.Options{
				TerraformDir: "../../terraform/environments/dev",
				Vars: map[string]interface{}{
					"az_count":    tc.azCount,
					"environment": fmt.Sprintf("test-%s", tc.name),
				},
			}

			t.Cleanup(func() { terraform.Destroy(t, opts) })
			terraform.InitAndApply(t, opts)

			subnets := terraform.OutputList(t, opts, "private_subnet_ids")
			assert.Equal(t, tc.wantSubnets, len(subnets))
		})
	}
}
```

`tests/terratest/go.mod` を作成してください:

```
module github.com/your-org/tf-ansible-nginx-pipeline/tests

go 1.21

require (
	github.com/gruntwork-io/terratest v0.46.7
	github.com/stretchr/testify v1.8.4
)
```

---

## Task 5-3: Inspecコントロールの生成

`tests/inspec/controls/security.rb` を作成してください:

```ruby
# =============================================================================
# InSpec: インフラのセキュリティポリシー準拠確認
# 設計思想: 「こうあるべき」をコードで表現し、継続的に検証する
# これにより手動確認を排除し、ポリシー逸脱を自動検知できる
# =============================================================================

# EC2インスタンスのセキュリティ確認
control 'ec2-sg-no-inbound-ssh' do
  impact 1.0
  title 'EC2セキュリティグループにSSH(22)インバウンドが存在しないこと'
  desc 'SSMセッションマネージャーを使用するため、SSH接続は不要かつ禁止'

  aws_security_groups.where(group_name: /handson-dev-ec2/).entries.each do |sg|
    describe aws_security_group(group_id: sg.group_id) do
      it { should_not have_inbound_rule(port: 22) }
      it { should_not have_inbound_rule(port: 3389) } # RDPも禁止
    end
  end
end

control 'ec2-ebs-encrypted' do
  impact 1.0
  title 'EC2のEBSボリュームが暗号化されていること'
  desc '静止時暗号化はセキュリティ要件'

  aws_ec2_instances.where(tags: { 'Project' => 'handson' }).instance_ids.each do |id|
    describe aws_ec2_instance(id) do
      it { should have_root_volume_encrypted }
    end
  end
end

control 's3-tfstate-not-public' do
  impact 1.0
  title 'tfstateバケットがパブリックアクセスブロックされていること'
  desc 'tfstateにはシークレット情報が含まれるため、公開厳禁'

  describe aws_s3_bucket(bucket_name: 'handson-dev-tfstate') do
    it { should have_access_control_list_enabled }
    it { should_not be_public }
    it { should have_default_encryption_enabled }
  end
end

control 'iam-no-wildcard-actions' do
  impact 0.7
  title 'IAMポリシーにワイルドカードアクションが存在しないこと'

  # handsonプロジェクトのカスタムポリシーを全て確認
  aws_iam_policies.where(scope: 'Local').entries
    .select { |p| p.policy_name.start_with?('handson-') }
    .each do |policy|
      describe aws_iam_policy(policy_arn: policy.arn) do
        it { should_not have_statement(Action: '*') }
      end
    end
end
```

`tests/inspec/inspec.yml`:

```yaml
name: handson-security
title: Handson Infrastructure Security Controls
maintainer: your-name
summary: TF×Ansible×AWSハンズオンのセキュリティポリシー準拠確認
version: 0.1.0
inspec_version: ">= 6.0"
depends:
  - name: inspec-aws
    url: https://github.com/inspec/inspec-aws/archive/main.tar.gz
```

---

## Task 5-4: Drift検知ワークフローの生成

`.github/workflows/drift-detection.yml` を作成してください:

```yaml
# =============================================================================
# Drift検知: 毎日定期的にterraform planを実行し、手動変更を検出する
# 設計思想:
#   IaCで管理しているのに誰かが手動でコンソールを操作した場合、
#   差分が発生する。これをCIで自動検知し、即座に通知する。
# =============================================================================

name: Drift Detection

on:
  schedule:
    # 毎日午前9時（JST）に実行
    - cron: '0 0 * * *'
  workflow_dispatch:

permissions:
  id-token: write
  contents: read
  issues: write  # Drift検出時にIssueを作成するため

jobs:
  detect-drift:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: AWS OIDC認証
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ap-northeast-1

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.7.0"

      - name: terraform init
        working-directory: terraform/environments/dev
        run: terraform init

      - name: terraform plan（差分チェック）
        id: plan
        working-directory: terraform/environments/dev
        run: |
          terraform plan -detailed-exitcode -no-color 2>&1 | tee plan_output.txt
          echo "exit_code=${PIPESTATUS[0]}" >> $GITHUB_OUTPUT
        # exit code:
        #   0 = 差分なし（正常）
        #   1 = エラー
        #   2 = 差分あり（Driftが発生している）

      - name: Drift検出時にGitHub Issueを作成
        if: steps.plan.outputs.exit_code == '2'
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const planOutput = fs.readFileSync('terraform/environments/dev/plan_output.txt', 'utf8');

            await github.rest.issues.create({
              owner: context.repo.owner,
              repo: context.repo.repo,
              title: `🚨 Infrastructure Drift Detected - ${new Date().toISOString().split('T')[0]}`,
              body: `## Drift検出アラート

            Terraformで管理しているリソースに手動変更が検出されました。

            ### plan差分

            \`\`\`
            ${planOutput.substring(0, 3000)}
            \`\`\`

            ### 対応手順

            1. 差分の内容を確認する
            2. 意図的な変更の場合: terraform importまたはコード修正
            3. 意図しない変更の場合: terraform applyで状態を戻す

            **注意**: 手動変更は次のapplyで上書きされます。`,
              labels: ['infrastructure', 'drift', 'urgent']
            });

      - name: plan結果のサマリー出力
        run: |
          if [ "${{ steps.plan.outputs.exit_code }}" = "0" ]; then
            echo "✅ Drift検出なし: Terraformの管理状態と実インフラが一致しています"
          elif [ "${{ steps.plan.outputs.exit_code }}" = "2" ]; then
            echo "🚨 Drift検出: 手動変更が見つかりました。GitHubにIssueを作成しました。"
            exit 1
          fi
```

---

## Task 5-5: テスト実行手順書の生成

`docs/testing-runbook.md` を作成してください:

```markdown
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
```

---

## Phase 5 実行コマンド（全テストの実行）

```bash
# Step 1: 静的解析
cd terraform/environments/dev && terraform validate && terraform fmt -check
cd ansible && ansible-lint site.yml

# Step 2: Molecule単体テスト
cd ansible && molecule test

# Step 3: Terratest統合テスト（コストに注意）
cd tests/terratest && go test -v -timeout 30m ./...

# Step 4: Inspecセキュリティ検証
cd tests/inspec && inspec exec . -t aws://ap-northeast-1

# Step 5: Drift検知
cd terraform/environments/dev && terraform plan -detailed-exitcode
```

## ハンズオン完了後のクリーンアップ

```bash
# 全リソースの削除（課金停止）
cd terraform/environments/dev
terraform destroy

# ブートストラップリソース（手動削除が必要）
# S3バケットは prevent_destroy = true のため先にバケットを空にする
aws s3 rm s3://handson-dev-tfstate --recursive
cd terraform/bootstrap
terraform destroy
```