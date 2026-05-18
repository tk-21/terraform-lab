import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import { Construct } from 'constructs';

export interface NetworkProps {
  prefix: string;
  commonTags: Record<string, string>;
}

// Q1: ec2.Vpc L2 Constructは内部で何個のCloudFormationリソースを生成するか？
//     → cdk synth 後に cdk.out/ のCFnテンプレートで確認（VPC/Subnet/IGW/RouteTable/RouteTableAssociation等）
//     Terraformで明示的に書いた vpc.tf の5〜6リソースがここに隠蔽されている
//
// 【TerraformとCDKの違い・ネットワーク層】
//   Terraform: aws_vpc, aws_subnet, aws_internet_gateway, aws_route_table, aws_route_table_association
//              を個別リソースとして宣言する → 「何が作られるか」が完全に可視
//   CDK L2:   ec2.Vpc 1つで上記すべてを内部生成する → 「便利だが何が作られるかが不透明」
//              学習目的では透明性が高いTerraformの方がインフラの理解が深まる
export class Network extends Construct {
  public readonly vpc: ec2.Vpc;
  public readonly publicSubnet: ec2.ISubnet;

  constructor(scope: Construct, id: string, props: NetworkProps) {
    super(scope, id);

    this.vpc = new ec2.Vpc(this, 'Vpc', {
      // infra-spec.md 準拠: VPC CIDR = 10.10.0.0/16
      ipAddresses: ec2.IpAddresses.cidr('10.10.0.0/16'),
      // maxAzs: 1 → ap-northeast-1a のみ使用（コスト最小化）
      maxAzs: 1,
      // NAT Gateway禁止: $32/月のコスト削減（infra-spec.md コスト設計ファースト原則）
      // TerraformではNATを書かなければ存在しないが、CDKはデフォルトで生成しようとする
      // → natGateways: 0 で明示的に無効化が必要
      natGateways: 0,
      subnetConfiguration: [
        {
          // infra-spec.md 準拠: Public Subnet = 10.10.1.0/24
          // CDK L2はVPCのCIDRブロック先頭から順にサブネットを割り当てるため、
          // 10.10.0.0/24 をreserved（未作成スキップ）にして 10.10.1.0/24 を確保する
          // Terraformでは cidr_block を直接指定できるため、このような工夫は不要
          name: 'reserved',
          subnetType: ec2.SubnetType.PRIVATE_ISOLATED,
          cidrMask: 24,
          reserved: true, // 実リソースを作成せずCIDRブロックを予約するだけ
        },
        {
          name: 'itl-dev-public',
          subnetType: ec2.SubnetType.PUBLIC,
          cidrMask: 24,
        },
      ],
      // VPC Flow Logs: コスト削減のため無効（検証ラボ用途）
      // 本番環境では必ず有効化すること
      enableDnsHostnames: true,
      enableDnsSupport: true,
    });

    // L2が生成したパブリックサブネットを取得
    this.publicSubnet = this.vpc.publicSubnets[0];

    // タグ付与: CDKではcdk.Tags.of()を使う
    // TerraformではリソースのTagsブロックに直接書くが、
    // CDKはConstructツリー全体にタグを伝播させる仕組みが特徴的
    cdk.Tags.of(this.vpc).add('Name', `${props.prefix}-vpc`);
    cdk.Tags.of(this.publicSubnet).add('Name', `${props.prefix}-public-1a`);
    Object.entries(props.commonTags).forEach(([key, value]) => {
      cdk.Tags.of(this.vpc).add(key, value);
    });
  }
}
