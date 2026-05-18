"""
コンピューティング層: EC2 / IAM Role / Instance Profile / Security Group

【IMDSv2 設定の比較】

Terraform:  metadata_options { http_tokens = "required" }
CDK(L2):    L2 Construct に直接プロパティがなく、L1 エスケープハッチが必要だった
              (instance.instance.addPropertyOverride('MetadataOptions', {...}))
Pulumi:     InstanceMetadataOptionsArgs(http_tokens="required") で直接指定可能

CDK の L1 エスケープハッチが不要な点は Terraform に近い「低レベル直接操作」の感覚。
Pulumi は「AWS SDK に近い薄いラッパー」として設計されており、
CDK の高度な抽象化（L2/L3）と対比すると、抽象化レベルが低い分だけ設定の自由度が高い。

【get_policy_document の比較】

Terraform: data "aws_iam_policy_document" {} ブロックで宣言的に定義
CDK:       iam.PolicyDocument.fromJson({...}) またはメソッドチェーン
Pulumi:    aws.iam.get_policy_document() 関数呼び出し（同期的に Python で実行）

Pulumi のデータソース（get_*）は Python 関数として同期実行される。
戻り値は通常の Python オブジェクトであり、Output[T] ではない点に注意。
"""
import json
from typing import Tuple

import pulumi_aws as aws

from config import ARTIFACTS_BUCKET_NAME, COMMON_TAGS, PREFIX


def create_compute(
    vpc: aws.ec2.Vpc,
    subnet: aws.ec2.Subnet,
) -> Tuple[aws.ec2.Instance, aws.ec2.SecurityGroup]:
    """
    EC2 インスタンスと関連する IAM・Security Group を作成する。

    Args:
        vpc:    ネットワーク層で作成した VPC（Output[str] 属性を持つ）
        subnet: ネットワーク層で作成したサブネット

    Returns:
        Tuple[aws.ec2.Instance, aws.ec2.SecurityGroup]
    """

    # -----------------------------------------------------------------------
    # IAM ロール（EC2 サービス用・最小権限）
    # -----------------------------------------------------------------------
    # aws.iam.get_policy_document() はデータソース（読み取り専用）
    # Terraform の data "aws_iam_policy_document" に相当
    # 戻り値は同期的な Python オブジェクト（Output[T] ではない）
    assume_role_policy = aws.iam.get_policy_document(
        statements=[
            aws.iam.GetPolicyDocumentStatementArgs(
                actions=["sts:AssumeRole"],
                principals=[
                    aws.iam.GetPolicyDocumentStatementPrincipalArgs(
                        type="Service",
                        identifiers=["ec2.amazonaws.com"],
                    )
                ],
            )
        ]
    )

    role = aws.iam.Role(
        f"{PREFIX}-ec2-role",
        assume_role_policy=assume_role_policy.json,
        description="EC2 インスタンス用 IAM ロール（SSM 接続・S3 アクセス）",
        tags={**COMMON_TAGS, "Name": f"{PREFIX}-ec2-role"},
    )

    # SSM Session Manager 接続用ポリシー（マネージドポリシー）
    # AmazonSSMManagedInstanceCore: SSM エージェント動作・セッション開始・ログ送信に必要
    aws.iam.RolePolicyAttachment(
        f"{PREFIX}-ssm-policy",
        role=role.name,
        policy_arn="arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    )

    # S3 アクセス用インラインポリシー（最小権限: 特定バケットのみ）
    # Terraform では aws_iam_role_policy リソース、CDK では role.addToPolicy()
    # Pulumi では aws.iam.RolePolicy（インラインポリシーを直接アタッチ）
    s3_policy_doc = json.dumps({
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "S3ArtifactsBucketAccess",
                "Effect": "Allow",
                "Action": [
                    "s3:GetObject",
                    "s3:PutObject",
                    "s3:DeleteObject",
                    "s3:ListBucket",
                ],
                # バケット名を明示して最小権限を保証（全 S3 へのアクセスを禁止）
                "Resource": [
                    f"arn:aws:s3:::{ARTIFACTS_BUCKET_NAME}",
                    f"arn:aws:s3:::{ARTIFACTS_BUCKET_NAME}/*",
                ],
            }
        ],
    })

    aws.iam.RolePolicy(
        f"{PREFIX}-ec2-s3-policy",
        role=role.id,
        policy=s3_policy_doc,
    )

    # -----------------------------------------------------------------------
    # IAM Instance Profile
    # -----------------------------------------------------------------------
    instance_profile = aws.iam.InstanceProfile(
        f"{PREFIX}-ec2-profile",
        role=role.name,
        tags={**COMMON_TAGS, "Name": f"{PREFIX}-ec2-profile"},
    )

    # -----------------------------------------------------------------------
    # Security Group（SSH 禁止・Egress 全開放）
    # -----------------------------------------------------------------------
    # Ingress を未設定 = SSH(22) を含む全インバウンド通信を拒否
    # SSM Session Manager は EC2 → SSM エンドポイントへのアウトバウンドで動作するため
    # インバウンドルールは不要
    sg = aws.ec2.SecurityGroup(
        f"{PREFIX}-app-sg",
        vpc_id=vpc.id,
        description=f"{PREFIX} app security group - SSM only, no SSH",
        egress=[
            aws.ec2.SecurityGroupEgressArgs(
                protocol="-1",   # -1 = 全プロトコル
                from_port=0,
                to_port=0,
                cidr_blocks=["0.0.0.0/0"],
            )
        ],
        # ingress を指定しない = 全インバウンド拒否
        # Terraform: ingress ブロック未定義と同等
        tags={**COMMON_TAGS, "Name": f"{PREFIX}-app-sg"},
    )

    # -----------------------------------------------------------------------
    # Amazon Linux 2023 arm64 AMI 動的取得
    # -----------------------------------------------------------------------
    # aws.ec2.get_ami() は同期的なデータソース呼び出し
    # Terraform の data "aws_ami" {} に相当
    # CDK では ec2.MachineImage.latestAmazonLinux2023() という L2 ヘルパーが存在したが
    # Pulumi では AWS API を直接呼ぶスタイルになる（低レベル操作）
    al2023_ami = aws.ec2.get_ami(
        most_recent=True,
        owners=["amazon"],   # 公式 Amazon AMI のみを対象（サードパーティ混入防止）
        filters=[
            aws.ec2.GetAmiFilterArgs(name="name", values=["al2023-ami-*-arm64"]),
            aws.ec2.GetAmiFilterArgs(name="virtualization-type", values=["hvm"]),
            aws.ec2.GetAmiFilterArgs(name="architecture", values=["arm64"]),
        ],
    )

    # -----------------------------------------------------------------------
    # EC2 インスタンス
    # -----------------------------------------------------------------------
    instance = aws.ec2.Instance(
        f"{PREFIX}-app",
        ami=al2023_ami.id,
        # arm64 (Graviton2) を選択: x86_64 比で約 20% コスト削減・同等性能
        # t4g.nano は検証ラボ用途に十分。本番移行時は t4g.small へのスケールアップを検討
        instance_type="t4g.nano",
        subnet_id=subnet.id,
        vpc_security_group_ids=[sg.id],
        iam_instance_profile=instance_profile.name,
        metadata_options=aws.ec2.InstanceMetadataOptionsArgs(
            # IMDSv2 強制: IMDSv1 は SSRF 攻撃によるメタデータ漏洩リスクがある
            # http_tokens="required" によりセッショントークンなしのリクエストを拒否
            # Terraform: metadata_options { http_tokens = "required" } と同一
            # CDK(L2):   L1 エスケープハッチ経由が必要だった（Pulumi はより直感的）
            http_tokens="required",
            http_put_response_hop_limit=1,
            http_endpoint="enabled",
        ),
        root_block_device=aws.ec2.InstanceRootBlockDeviceArgs(
            volume_type="gp3",
            volume_size=8,
            delete_on_termination=True,
            # ルートボリューム暗号化（デフォルト暗号化が無効な場合に備えて明示）
            encrypted=True,
        ),
        # SSM エージェント起動確認用 user_data
        # Amazon Linux 2023 では SSM エージェントはデフォルトインストール済みだが
        # 起動時の状態確認と自動起動設定を保証するために明示的に実行する
        user_data="""#!/bin/bash
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent
echo "SSM Agent started at $(date)" >> /var/log/user-data.log
""",
        tags={**COMMON_TAGS, "Name": f"{PREFIX}-app"},
    )

    return instance, sg
