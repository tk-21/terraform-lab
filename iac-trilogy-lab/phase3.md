# ✅Phase 3: Pulumi (Python) 実装

> **このフェーズの問い**:
> 「プログラミング言語ファーストのIaCは、HCLや TypeScriptと何が本質的に異なるか？
>  PulumiのOutputとPromiseの概念は、なぜTerraform経験者が最初に戸惑うのか？」

## 前提確認

- Phase 1（Terraform）・Phase 2（CDK）が完了していること
- `pulumi/` ディレクトリで作業すること
- Python: >= 3.11
- Pulumi CLI: >= 3.x（`pip install pulumi pulumi-aws`）
- infra-spec.mdの仕様をTerraform / CDK実装と同一にすること

---

## セットアップ手順（Claude Codeが実施）

```bash
mkdir -p pulumi && cd pulumi

# Pulumi Pythonプロジェクト初期化
pulumi new aws-python --name itl-trilogy-lab --stack itl-dev --yes

# 依存パッケージ
pip install pulumi pulumi-aws

# スタック設定
pulumi config set aws:region ap-northeast-1
pulumi config set notificationEmail your@email.com --secret

# 確認
pulumi version
```

---

## タスク

`pulumi/` に以下のファイル構造でPulumiコードを生成すること。

```
pulumi/
├── __main__.py          # エントリーポイント（全リソース統合）
├── network.py           # VPC / Subnet / IGW / Route Table
├── compute.py           # EC2 / IAM Role / Instance Profile
├── storage.py           # S3バケット
├── monitoring.py        # Budgets / CloudWatch / SNS
├── config.py            # 設定値・共通タグ管理
├── Pulumi.yaml          # プロジェクト設定
├── Pulumi.itl-dev.yaml  # スタック設定
└── requirements.txt     # pulumi, pulumi-aws
```

---

## 実装要件

### config.py（共通設定）

```python
import pulumi
import pulumi_aws as aws

# Pulumiの設定値取得（pulumi config setで管理）
config = pulumi.Config()

# 共通タグ（全リソースに付与）
# Terraformのlocals、CDKのcdk.Tags.of()に相当する
COMMON_TAGS = {
    "Project": "iac-trilogy-lab",
    "Env": "dev",
    "ManagedBy": "pulumi",  # ← Terraform/CDK実装との差別化
    "CostOwner": "takuya",
}

PREFIX = "itl-dev"

# 通知先メール（secretとして管理）
NOTIFICATION_EMAIL = config.require_secret("notificationEmail")
# コメント: Terraformでは terraform.tfvars + .gitignore で管理していたsensitive値を
# Pulumiはスタック設定にsealed secretとして保存する。暗号化はPulumiクラウドまたはAWS KMS。
```

### network.py

```python
# Pulumi最大の学習ポイント: Output[T] 型
#
# TerraformではリソースのID参照を直接書けた:
#   subnet_id = aws_subnet.public.id
#
# PulumiではOutput[str]として扱う:
#   subnet_id = subnet.id  # これはstr型ではなくOutput[str]型
#
# Output[str]を文字列として使いたい場合:
#   subnet.id.apply(lambda id: f"subnet-{id}")
#
# これがTerraform経験者が最初に戸惑う「Pulumiの哲学」

import pulumi_aws as aws
from config import COMMON_TAGS, PREFIX

def create_network():
    """
    VPC / Subnet / IGW / Route Tableを作成する。
    Terraformと異なり、Pythonの関数でリソースをグループ化できる。
    CDKのConstructと似ているが、クラスを強制されない点が異なる。
    """

    vpc = aws.ec2.Vpc(
        f"{PREFIX}-vpc",
        cidr_block="10.10.0.0/16",
        enable_dns_hostnames=True,
        enable_dns_support=True,
        tags={**COMMON_TAGS, "Name": f"{PREFIX}-vpc"},
        # コメント: **dict展開でタグをマージ。TerraformのmergeのPython相当。
    )

    subnet = aws.ec2.Subnet(
        f"{PREFIX}-public-1a",
        vpc_id=vpc.id,  # Output[str]型 - Pulumiが依存関係を自動解決
        cidr_block="10.10.1.0/24",
        availability_zone="ap-northeast-1a",
        map_public_ip_on_launch=True,
        tags={**COMMON_TAGS, "Name": f"{PREFIX}-public-1a"},
    )

    igw = aws.ec2.InternetGateway(
        f"{PREFIX}-igw",
        vpc_id=vpc.id,
        tags={**COMMON_TAGS, "Name": f"{PREFIX}-igw"},
    )

    route_table = aws.ec2.RouteTable(
        f"{PREFIX}-public-rt",
        vpc_id=vpc.id,
        routes=[
            aws.ec2.RouteTableRouteArgs(
                cidr_block="0.0.0.0/0",
                gateway_id=igw.id,
            )
        ],
        tags={**COMMON_TAGS, "Name": f"{PREFIX}-public-rt"},
    )

    aws.ec2.RouteTableAssociation(
        f"{PREFIX}-public-rta",
        subnet_id=subnet.id,
        route_table_id=route_table.id,
    )

    return vpc, subnet
```

### compute.py

```python
# IMDSv2設定（Terraform: metadata_options, CDK: L1エスケープハッチ, Pulumi: ?)
#
# PulumiではInstance リソースのmetadata_optionsプロパティで直接指定できる。
# CDKのL1エスケープハッチが不要な点がTerraformに近い。
# これは「抽象化レベル」の差: Pulumi ≈ Terraform > CDK(L2)

import pulumi_aws as aws
from config import COMMON_TAGS, PREFIX

def create_compute(vpc, subnet):
    # IAMロール（SSM接続用 + S3読み書き権限）
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
        tags={**COMMON_TAGS, "Name": f"{PREFIX}-ec2-role"},
    )

    # SSMポリシーアタッチ
    aws.iam.RolePolicyAttachment(
        f"{PREFIX}-ssm-policy",
        role=role.name,
        policy_arn="arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    )

    instance_profile = aws.iam.InstanceProfile(
        f"{PREFIX}-ec2-profile",
        role=role.name,
        tags={**COMMON_TAGS, "Name": f"{PREFIX}-ec2-profile"},
    )

    # Security Group（SSH禁止・Egress全開放）
    sg = aws.ec2.SecurityGroup(
        f"{PREFIX}-app-sg",
        vpc_id=vpc.id,
        description="itl-dev app security group - no SSH",
        egress=[
            aws.ec2.SecurityGroupEgressArgs(
                protocol="-1",
                from_port=0,
                to_port=0,
                cidr_blocks=["0.0.0.0/0"],
            )
        ],
        # Ingress未設定 = SSH禁止
        tags={**COMMON_TAGS, "Name": f"{PREFIX}-app-sg"},
    )

    # Amazon Linux 2023 arm64 AMI動的取得
    al2023_ami = aws.ec2.get_ami(
        most_recent=True,
        owners=["amazon"],
        filters=[
            aws.ec2.GetAmiFilterArgs(name="name", values=["al2023-ami-*-arm64"]),
        ],
    )

    instance = aws.ec2.Instance(
        f"{PREFIX}-app",
        ami=al2023_ami.id,
        instance_type="t4g.nano",
        # arm64(Graviton2): x86比コスト約20%削減
        subnet_id=subnet.id,
        vpc_security_group_ids=[sg.id],
        iam_instance_profile=instance_profile.name,
        metadata_options=aws.ec2.InstanceMetadataOptionsArgs(
            http_tokens="required",  # IMDSv2強制
            # TerraformもPulumiもここは同じ書き方。CDKのL1エスケープハッチより直感的。
        ),
        tags={**COMMON_TAGS, "Name": f"{PREFIX}-app"},
    )

    return instance, sg
```

### __main__.py（統合）

```python
import pulumi
from network import create_network
from compute import create_compute
from storage import create_storage
from monitoring import create_monitoring

# Pythonの関数呼び出しでリソースを構成する
# TerraformのmoduleコールやCDKのConstruct instantiationに相当するが、
# 「ただのPython関数」であることがPulumiの特徴

vpc, subnet = create_network()
instance, sg = create_compute(vpc, subnet)
bucket = create_storage()
create_monitoring(instance)

# Outputs（Terraformのoutputs.tfに相当）
pulumi.export("vpc_id", vpc.id)
pulumi.export("instance_id", instance.id)
pulumi.export("bucket_name", bucket.id)
# コメント: Output[T]型の値はpulumi.exportで外部に公開できる
# pulumi stack output コマンドで確認可能
```

---

## コーディング規則

1. **全リソースに日本語コメントで「Terraform / CDKとの差異」を明記**
2. **Output[T]型の扱いに関するコメントを必ず含める**
3. **Pythonのリスト内包表記・dict展開を積極的に使い、TerraformのHCLとの対比をコメントで示す**
4. **型ヒント（Type hints）を付与する**（`from typing import Tuple` 等）

---

## 実装後の自己確認チェック（Claude Codeが実施）

```bash
cd pulumi

# プレビュー（Terraformのplan、CDKのdiffに相当）
pulumi preview

# リソース数確認（Terraform / CDKと比較）
pulumi preview --json | python3 -c "
import json, sys
data = json.load(sys.stdin)
steps = data.get('steps', [])
creates = [s for s in steps if s.get('op') == 'create']
print(f'作成リソース数: {len(creates)}')
for s in creates:
    print(f'  - {s[\"urn\"].split(\"::\")[-1]}')
"

# SSH(22)が含まれていないことを確認
pulumi preview --json | python3 -c "
import json, sys
data = json.load(sys.stdin)
text = json.dumps(data)
if '\"22\"' in text or 'port 22' in text.lower():
    print('❌ SSH(22)検出 - 要確認')
else:
    print('✅ SSHなし')
"
```

---

## 完了後にやること（手動）

1. `pulumi up` を実行
2. EC2にSSM接続できることを確認
3. infra-spec.mdの「検証完了条件」をチェック
4. `pulumi stack` で状態確認（Terraform stateとの違いを観察）
5. **「Output[T]型がなぜ存在するか」を15分間口頭で説明できるか確認**

---

## Phase 3 完了の定義

- [ ] `pulumi up` が成功する
- [ ] SSM接続確認済み
- [ ] コスト監視設定済み
- [ ] IMDSv2強制が設定されている
- [ ] 全リソースに「Terraform/CDKとの差異」コメントがある
- [ ] `adr/adr-003-pulumi-vs-hcl.md` に以下を自分の言葉で記述:
  - 「Output[T]型で戸惑った箇所とその理解」
  - 「PythonがHCLより強力だと感じた場面・逆に不便だった場面」
  - 「Pulumiのstateと Terraform stateの根本的な違い」