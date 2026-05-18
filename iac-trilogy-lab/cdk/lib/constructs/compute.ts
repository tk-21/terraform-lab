import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as s3 from 'aws-cdk-lib/aws-s3';
import { Construct } from 'constructs';

export interface ComputeProps {
  prefix: string;
  vpc: ec2.IVpc;
  subnet: ec2.ISubnet;
  artifactsBucket: s3.IBucket;
  commonTags: Record<string, string>;
}

// 【TerraformとCDKの違い・コンピューティング層】
//   Terraform: IAMロール/ポリシーアタッチメント/インスタンスプロファイル/EC2を個別リソースで管理
//   CDK L2:    ec2.Instance がRole/Profile/SGを自動生成する選択肢もあるが、
//              このConstructでは明示的にiam.Roleを分離して可視性を保持している
//
// 【L1エスケープハッチの使用箇所】
//   IMDSv2強制: ec2.Instance L2 ConstructはIMDSv2の設定プロパティを持たない（CDK v2.254時点）
//   → CloudFormationレベル(L1: CfnInstance)に直接プロパティを注入するエスケープハッチが必要
//   Terraformでは metadata_options { http_tokens = "required" } で直接書ける点と対照的
export class Compute extends Construct {
  public readonly instance: ec2.Instance;
  public readonly securityGroup: ec2.SecurityGroup;
  public readonly instanceRole: iam.Role;

  constructor(scope: Construct, id: string, props: ComputeProps) {
    super(scope, id);

    // Q2: Terraformの for_each に相当するCDKのパターンは何か？
    //     → Array.from() や map() でConstructをループ生成する（TypeScriptのネイティブ構文を使える）
    //     例: ['dev', 'stg'].map(env => new Compute(this, `Compute-${env}`, {...}))

    // -----------------------------------------------------------------------
    // Security Group: SSHなし・Egress全開（SSM接続のため）
    // -----------------------------------------------------------------------
    this.securityGroup = new ec2.SecurityGroup(this, 'AppSg', {
      vpc: props.vpc,
      securityGroupName: `${props.prefix}-app-sg`,
      description: 'itl-dev EC2 security group - SSM only, no SSH',
      // デフォルトでEgress All Openが付与される（CDK L2の挙動）
      // TerraformではEgressを明示しなければ付与されないため、この差異に注意
      allowAllOutbound: true,
    });
    // Ingress は一切追加しない: SSMはHTTPSアウトバウンドのみで動作するため不要
    cdk.Tags.of(this.securityGroup).add('Name', `${props.prefix}-app-sg`);

    // -----------------------------------------------------------------------
    // IAM Role: EC2用最小権限
    // -----------------------------------------------------------------------
    this.instanceRole = new iam.Role(this, 'Ec2Role', {
      roleName: `${props.prefix}-ec2-role`,
      description: 'EC2インスタンス用IAMロール（SSM接続・S3アクセス）',
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
    });

    // SSM Session Manager接続に必要な最小限のポリシー
    this.instanceRole.addManagedPolicy(
      iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore')
    );

    // S3アクセス: インラインポリシーで最小権限を保証
    // TerraformのinlineポリシーとCDKのaddToPolicy()は同等の概念
    this.instanceRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'S3ArtifactsBucketAccess',
        effect: iam.Effect.ALLOW,
        actions: ['s3:GetObject', 's3:PutObject', 's3:DeleteObject', 's3:ListBucket'],
        // バケットARNを明示して最小権限を保証（全S3バケットへのアクセスを禁止）
        resources: [props.artifactsBucket.bucketArn, `${props.artifactsBucket.bucketArn}/*`],
      })
    );

    cdk.Tags.of(this.instanceRole).add('Name', `${props.prefix}-ec2-role`);

    // -----------------------------------------------------------------------
    // EC2 Instance
    // -----------------------------------------------------------------------
    // arm64 AMI: Amazon Linux 2023 (Graviton2)
    // Graviton2選択理由: x86_64比で約20%コスト削減・同等性能
    // t4g.nano は検証ラボ用途に十分。本番移行時は t4g.small へのスケールアップを検討
    const machineImage = ec2.MachineImage.latestAmazonLinux2023({
      cpuType: ec2.AmazonLinuxCpuType.ARM_64,
    });

    this.instance = new ec2.Instance(this, 'AppInstance', {
      instanceName: `${props.prefix}-app`,
      instanceType: new ec2.InstanceType('t4g.nano'),
      machineImage,
      vpc: props.vpc,
      vpcSubnets: { subnets: [props.subnet] },
      securityGroup: this.securityGroup,
      role: this.instanceRole,
      // SSMエージェントはAmazon Linux 2023にデフォルト搭載済み
      // 起動確認と自動起動設定を保証するためuser_dataで明示的に有効化
      userData: ec2.UserData.custom([
        '#!/bin/bash',
        'systemctl enable amazon-ssm-agent',
        'systemctl start amazon-ssm-agent',
        'echo "SSM Agent started at $(date)" >> /var/log/user-data.log',
      ].join('\n')),
      blockDevices: [
        {
          deviceName: '/dev/xvda',
          volume: ec2.BlockDeviceVolume.ebs(8, {
            volumeType: ec2.EbsDeviceVolumeType.GP3,
            deleteOnTermination: true,
            // ルートボリュームを暗号化（デフォルト暗号化が無効な場合に備えて明示）
            encrypted: true,
          }),
        },
      ],
      // CDKのL2ではIMDSv2の直接設定プロパティが存在しない
      // → L1エスケープハッチ（下記）で対応
    });

    // -----------------------------------------------------------------------
    // L1エスケープハッチ: IMDSv2強制設定
    // -----------------------------------------------------------------------
    // ec2.Instance L2 ConstructはIMDSv2(MetadataOptions)の設定をサポートしていない
    // CloudFormationリソース(CfnInstance)に直接プロパティを注入することで実現する
    // これはCDKの抽象化が「漏れる」場面。Terraformでは metadata_options ブロックで直接書ける。
    //
    // IMDSv2強制の理由: IMDSv1はSSRF攻撃によるメタデータ漏洩リスクがある
    // http_tokens = "required" により、セッショントークンなしのリクエストを拒否
    const cfnInstance = this.instance.node.defaultChild as ec2.CfnInstance;
    cfnInstance.addPropertyOverride('MetadataOptions.HttpTokens', 'required');
    cfnInstance.addPropertyOverride('MetadataOptions.HttpPutResponseHopLimit', 1);
    cfnInstance.addPropertyOverride('MetadataOptions.HttpEndpoint', 'enabled');

    cdk.Tags.of(this.instance).add('Name', `${props.prefix}-app`);
  }
}
