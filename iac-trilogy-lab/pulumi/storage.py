"""
ストレージ層: S3 バケット

【Terraform / CDK / Pulumi の S3 設定比較】

Terraform では S3 の各設定（バージョニング・暗号化・パブリックアクセスブロック等）が
個別の aws_s3_bucket_* リソースとして分離している（プロバイダーv4以降）。

CDK(L2) では aws_s3.Bucket() コンストラクトの引数で一括設定できる。
    new s3.Bucket(this, 'Bucket', {
        versioned: true,
        encryption: s3.BucketEncryption.S3_MANAGED,
        blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
    })

Pulumi は Terraform に近く、各設定を個別の aws.s3.* リソースとして分けて定義する。
これは「低レベル操作」の特徴 — AWS API の構造をそのまま反映している。

どちらが良いかはユースケース次第:
  CDK の一括設定 → コードが短く、デフォルト設定の恩恵を受けやすい
  Pulumi/Terraform の個別設定 → 変更差分が明確、設定漏れを意識しやすい
"""
import pulumi_aws as aws

from config import ARTIFACTS_BUCKET_NAME, COMMON_TAGS


def create_storage() -> aws.s3.BucketV2:
    """
    S3 アーティファクトバケットを作成する。

    Returns:
        aws.s3.BucketV2: 他モジュールが参照するバケットリソース
    """

    # -----------------------------------------------------------------------
    # S3 バケット本体
    # -----------------------------------------------------------------------
    bucket = aws.s3.BucketV2(
        ARTIFACTS_BUCKET_NAME,
        bucket=ARTIFACTS_BUCKET_NAME,
        # 検証完了後に destroy する前提のため force_destroy を有効化
        # 本番環境では False にしてオブジェクトの誤削除を防ぐこと
        force_destroy=True,
        tags={**COMMON_TAGS, "Name": ARTIFACTS_BUCKET_NAME},
    )

    # -----------------------------------------------------------------------
    # バージョニング: 有効化
    # -----------------------------------------------------------------------
    # オブジェクトの上書き・削除からの復旧を可能にする
    # Terraform: aws_s3_bucket_versioning リソース（分離設定）
    # CDK:       Bucket の versioned: true 引数（一括設定）
    # Pulumi:    aws.s3.BucketVersioningV2 リソース（Terraform と同じ分離スタイル）
    aws.s3.BucketVersioningV2(
        f"{ARTIFACTS_BUCKET_NAME}-versioning",
        bucket=bucket.id,
        versioning_configuration=aws.s3.BucketVersioningV2VersioningConfigurationArgs(
            status="Enabled",
        ),
    )

    # -----------------------------------------------------------------------
    # パブリックアクセスブロック: 全設定を有効化
    # -----------------------------------------------------------------------
    # S3 バケットポリシーや ACL によるパブリック公開を完全に遮断
    # 誤設定によるデータ漏洩を防ぐための多層防御
    aws.s3.BucketPublicAccessBlock(
        f"{ARTIFACTS_BUCKET_NAME}-pab",
        bucket=bucket.id,
        block_public_acls=True,
        block_public_policy=True,
        ignore_public_acls=True,
        restrict_public_buckets=True,
    )

    # -----------------------------------------------------------------------
    # サーバーサイド暗号化: AES-256 (SSE-S3)
    # -----------------------------------------------------------------------
    # KMS を使わない理由: 検証ラボではコスト最小化優先
    # 本番環境では aws:kms + カスタマーキーへの移行を検討すること
    aws.s3.BucketServerSideEncryptionConfigurationV2(
        f"{ARTIFACTS_BUCKET_NAME}-sse",
        bucket=bucket.id,
        rules=[
            aws.s3.BucketServerSideEncryptionConfigurationV2RuleArgs(
                apply_server_side_encryption_by_default=aws.s3.BucketServerSideEncryptionConfigurationV2RuleApplyServerSideEncryptionByDefaultArgs(
                    sse_algorithm="AES256",
                ),
                # バケット内の全オブジェクトに暗号化を強制（暗号化なしのアップロードを拒否）
                bucket_key_enabled=True,
            )
        ],
    )

    # -----------------------------------------------------------------------
    # バケットオーナーシップ: BucketOwnerEnforced
    # -----------------------------------------------------------------------
    # ACL を無効化し、バケットポリシーのみでアクセス制御する現代的な設定
    aws.s3.BucketOwnershipControls(
        f"{ARTIFACTS_BUCKET_NAME}-ownership",
        bucket=bucket.id,
        rule=aws.s3.BucketOwnershipControlsRuleArgs(
            object_ownership="BucketOwnerEnforced",
        ),
    )

    return bucket
