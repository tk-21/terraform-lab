import * as cdk from 'aws-cdk-lib';
import * as s3 from 'aws-cdk-lib/aws-s3';
import { Construct } from 'constructs';

export interface StorageProps {
  prefix: string;
  accountId: string;
  commonTags: Record<string, string>;
}

// 【TerraformとCDKの違い・ストレージ層】
//   Terraform: aws_s3_bucket / aws_s3_bucket_versioning / aws_s3_bucket_public_access_block を
//              個別リソースとして宣言する（各設定が明示的）
//   CDK L2:    s3.Bucket のプロパティでバージョニング・パブリックアクセスブロックを一括設定できる
//              → コード量が少ない反面、デフォルト値の挙動を把握していないと意図せず設定が変わる
export class Storage extends Construct {
  public readonly artifactsBucket: s3.Bucket;

  constructor(scope: Construct, id: string, props: StorageProps) {
    super(scope, id);

    // S3バケット名: 全AWSアカウントでグローバルユニークにするためアカウントIDをサフィックスに使用
    // infra-spec.md 準拠: itl-dev-artifacts-{account_id}
    const bucketName = `${props.prefix}-artifacts-${props.accountId}`;

    this.artifactsBucket = new s3.Bucket(this, 'ArtifactsBucket', {
      bucketName,
      // バージョニング有効: 誤削除からの復旧を可能にする
      versioned: true,
      // パブリックアクセス全ブロック: セキュリティ原則（infra-spec.md）
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      // パブリックアクセスポリシーを拒否
      publicReadAccess: false,
      // スタック削除時のバケット保護: RETAIN でデータ保護
      // 検証ラボでも誤ってterraform destroyした際のデータ保護のため
      // CDKではRemovalPolicyで指定、TerraformではDeletionProtectionに相当
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      // 転送中の暗号化を強制（HTTPS only）
      enforceSSL: true,
      // サーバーサイド暗号化: S3管理キー（SSE-S3）
      // 検証ラボのためKMSは使用しない（コスト削減）
      encryption: s3.BucketEncryption.S3_MANAGED,
    });

    cdk.Tags.of(this.artifactsBucket).add('Name', bucketName);
    Object.entries(props.commonTags).forEach(([key, value]) => {
      cdk.Tags.of(this.artifactsBucket).add(key, value);
    });
  }
}
