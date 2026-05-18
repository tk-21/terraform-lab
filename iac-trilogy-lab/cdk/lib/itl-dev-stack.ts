import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import { Network } from './constructs/network';
import { Compute } from './constructs/compute';
import { Storage } from './constructs/storage';
import { Monitoring } from './constructs/monitoring';

// Props定義: TypeScriptの型安全性を活かしてPropsを明示する
// Terraformのvariables.tfに相当するが、型チェックがコンパイル時に行われる点が異なる
export interface ItlDevStackProps extends cdk.StackProps {
  notificationEmail?: string;
}

// Q3: Terraform state に相当するCDKの状態管理はどこにあるか？
//     → CloudFormationスタックがAWS側でスタック状態を管理する（ローカルstateファイル不要）
//     Terraformは .tfstate をS3+DynamoDBで管理するが、CDKはCloudFormationに委譲している
//     この差異がチームコラボレーションの観点でどちらが有利かはユースケース次第
export class ItlDevStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: ItlDevStackProps = {}) {
    super(scope, id, props);

    const prefix = 'itl-dev';
    const notificationEmail = props.notificationEmail ?? 'o.takuya.0220@gmail.com';

    // 共通タグ: infra-spec.md 準拠
    // ManagedBy = "cdk" でTerraform/Pulumi実装との差別化を明確にする
    // CDKではcdk.Tags.of(this)でスタック全体にタグを伝播できる（Terraformのdefault_tagsに相当）
    const commonTags: Record<string, string> = {
      Project: 'iac-trilogy-lab',
      Env: 'dev',
      ManagedBy: 'cdk',
      CostOwner: 'takuya',
    };

    // スタック全体へのタグ付与
    // CDKの強み: タグをConstructツリーのルートで1回設定すれば全子Constructに伝播する
    // Terraformでは各resourceブロックにタグを書くか、default_tagsを使う必要がある
    Object.entries(commonTags).forEach(([key, value]) => {
      cdk.Tags.of(this).add(key, value);
    });

    // -----------------------------------------------------------------------
    // ネットワーク層
    // -----------------------------------------------------------------------
    const network = new Network(this, 'Network', {
      prefix,
      commonTags,
    });

    // -----------------------------------------------------------------------
    // ストレージ層
    // -----------------------------------------------------------------------
    // this.account: CDKが自動解決するアカウントID
    // Terraformの data.aws_caller_identity.current.account_id に相当
    const storage = new Storage(this, 'Storage', {
      prefix,
      accountId: this.account,
      commonTags,
    });

    // -----------------------------------------------------------------------
    // コンピューティング層
    // -----------------------------------------------------------------------
    const compute = new Compute(this, 'Compute', {
      prefix,
      vpc: network.vpc,
      subnet: network.publicSubnet,
      artifactsBucket: storage.artifactsBucket,
      commonTags,
    });

    // -----------------------------------------------------------------------
    // 監視層
    // -----------------------------------------------------------------------
    new Monitoring(this, 'Monitoring', {
      prefix,
      notificationEmail,
      instance: compute.instance,
      commonTags,
    });

    // -----------------------------------------------------------------------
    // Outputs: CloudFormationスタックの出力
    // -----------------------------------------------------------------------
    // Terraformのoutputs.tfに相当するが、CDKではcdk.CfnOutputを使う
    // CloudFormationコンソールから確認可能

    new cdk.CfnOutput(this, 'VpcId', {
      description: 'VPC ID',
      value: network.vpc.vpcId,
      exportName: `${prefix}-vpc-id`,
    });

    new cdk.CfnOutput(this, 'PublicSubnetId', {
      description: 'パブリックサブネット ID',
      value: network.publicSubnet.subnetId,
      exportName: `${prefix}-public-subnet-id`,
    });

    new cdk.CfnOutput(this, 'InstanceId', {
      description: 'EC2インスタンス ID（SSM接続確認用）',
      value: compute.instance.instanceId,
      exportName: `${prefix}-instance-id`,
    });

    new cdk.CfnOutput(this, 'ArtifactsBucketName', {
      description: 'S3アーティファクトバケット名',
      value: storage.artifactsBucket.bucketName,
      exportName: `${prefix}-artifacts-bucket`,
    });

    new cdk.CfnOutput(this, 'SsmConnectCommand', {
      description: 'SSM Session Manager接続コマンド',
      value: `aws ssm start-session --target ${compute.instance.instanceId} --region ap-northeast-1`,
    });
  }
}
