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

	instanceInfo, err := ssmClient.DescribeInstanceInformation(nil)
	require.NoError(t, err)
	require.NotNil(t, instanceInfo)

	// SSM Onlineステータスの確認
	for _, info := range instanceInfo.InstanceInformationList {
		if *info.InstanceId == instanceID {
			assert.Equal(t, "Online", string(info.PingStatus),
				"EC2インスタンスがSSM Onlineになっていること")
			break
		}
	}

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
		name        string
		azCount     int
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
