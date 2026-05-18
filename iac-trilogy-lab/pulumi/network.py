"""
ネットワーク層: VPC / Subnet / IGW / Route Table

【Pulumi 最大の学習ポイント: Output[T] 型】

Terraform ではリソースの属性参照を直接書けた:
    subnet_id = aws_subnet.public.id   # str型として扱われる

Pulumi では Output[str] として扱う:
    subnet_id = subnet.id              # これは str ではなく Output[str]

Output[T] は「将来解決される値の約束」。
JavaScript の Promise、Python の asyncio.Future に相当する概念。
Pulumi のエンジンが apply 実行時に並列依存解決するために必要な設計。

Output[str] を文字列として加工したい場合:
    subnet.id.apply(lambda id: f"subnet-id-is-{id}")

ただし、別のリソースの引数に渡す場合は apply() 不要 —
Pulumi エンジンが自動的に依存関係を解析してくれる。

この「暗黙的依存解決」が Terraform の depends_on 明示と異なる点。
"""
from typing import Tuple

import pulumi_aws as aws

from config import COMMON_TAGS, PREFIX, SUBNET_AZ, SUBNET_CIDR, VPC_CIDR


def create_network() -> Tuple[aws.ec2.Vpc, aws.ec2.Subnet]:
    """
    VPC / Subnet / IGW / Route Table を作成する。

    Terraform と異なり、Python の関数でリソースをグループ化できる。
    CDK の Construct と似ているが、クラスを強制されない点が異なる。
    「ただの Python 関数」としてネットワーク層を表現できるのが Pulumi の特徴。

    Returns:
        Tuple[aws.ec2.Vpc, aws.ec2.Subnet]: 他モジュールが参照する VPC と Subnet
    """

    # -----------------------------------------------------------------------
    # VPC
    # -----------------------------------------------------------------------
    vpc = aws.ec2.Vpc(
        f"{PREFIX}-vpc",
        cidr_block=VPC_CIDR,
        enable_dns_hostnames=True,
        enable_dns_support=True,
        # **dict展開でタグをマージ: Terraform の merge() 関数の Python 相当
        # CDK では cdk.Tags.of(vpc).add() を個別呼び出しする必要があった
        tags={**COMMON_TAGS, "Name": f"{PREFIX}-vpc"},
    )

    # -----------------------------------------------------------------------
    # パブリックサブネット
    # -----------------------------------------------------------------------
    subnet = aws.ec2.Subnet(
        f"{PREFIX}-public-1a",
        # vpc.id は Output[str] 型 — Pulumi エンジンが依存関係を自動解決する
        # Terraform: vpc_id = aws_vpc.main.id  （HCL 内で直接参照）
        # CDK:       vpcId: vpc.vpcId           （TypeScript の型推論で解決）
        # Pulumi:    vpc_id=vpc.id              （Output[str] をそのまま渡す）
        vpc_id=vpc.id,
        cidr_block=SUBNET_CIDR,
        availability_zone=SUBNET_AZ,
        map_public_ip_on_launch=True,
        tags={**COMMON_TAGS, "Name": f"{PREFIX}-public-1a"},
    )

    # -----------------------------------------------------------------------
    # Internet Gateway
    # -----------------------------------------------------------------------
    igw = aws.ec2.InternetGateway(
        f"{PREFIX}-igw",
        vpc_id=vpc.id,
        tags={**COMMON_TAGS, "Name": f"{PREFIX}-igw"},
    )

    # -----------------------------------------------------------------------
    # Route Table + デフォルトルート（0.0.0.0/0 → IGW）
    # -----------------------------------------------------------------------
    # Terraform では aws_route と aws_route_table を分けることもできるが
    # Pulumi では RouteTable の routes 引数にインラインで定義するのが慣習
    # CDK は addRoute() メソッドで後から追加する命令型スタイル
    route_table = aws.ec2.RouteTable(
        f"{PREFIX}-public-rt",
        vpc_id=vpc.id,
        routes=[
            aws.ec2.RouteTableRouteArgs(
                cidr_block="0.0.0.0/0",
                # igw.id も Output[str]: Pulumi が apply 時に IGW 作成完了を待ってから参照する
                gateway_id=igw.id,
            )
        ],
        tags={**COMMON_TAGS, "Name": f"{PREFIX}-public-rt"},
    )

    # Route Table とサブネットの関連付け
    # NAT Gateway を使わない理由: コストゼロ設計（$32/月の節約）
    aws.ec2.RouteTableAssociation(
        f"{PREFIX}-public-rta",
        subnet_id=subnet.id,
        route_table_id=route_table.id,
    )

    return vpc, subnet
