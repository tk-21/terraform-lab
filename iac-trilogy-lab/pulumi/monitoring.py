"""
監視層: AWS Budgets / SNS / CloudWatch Alarm

【Output[T] と apply() の実践例】

PulumiのOutput[T]が最も問題になるのは「文字列を構築したいとき」。

例: SNS トピック ARN を文字列フォーマットに埋め込む
    # ❌ これは動かない（Output[str] を str として使っている）
    message = f"Topic ARN: {topic.arn}"

    # ✅ apply() で解決する
    message = topic.arn.apply(lambda arn: f"Topic ARN: {arn}")

    # ✅ pulumi.Output.concat() も使える
    message = pulumi.Output.concat("Topic ARN: ", topic.arn)

ただし、別リソースの引数に Output[str] を渡す場合は apply() 不要 —
Pulumi エンジンが依存グラフを解析して自動的に順序を決定してくれる。

【Budgets の比較】

Terraform: aws_budgets_budget リソース（HCL で宣言的）
CDK:       CfnBudget (L1 Construct) — L2 が存在しない（2024 年時点）
Pulumi:    aws.budgets.Budget リソース — Terraform と構造がほぼ同一

CDK だけが「L2 がなく L1 を直接使う必要がある」という制約があった。
Pulumi と Terraform は AWS API を薄くラップする設計のため、
Budgets のような比較的新しいサービスでも一貫した書き方ができる。
"""
import pulumi
import pulumi_aws as aws

from config import COMMON_TAGS, NOTIFICATION_EMAIL, PREFIX


def create_monitoring(instance: aws.ec2.Instance) -> None:
    """
    コスト監視・EC2 CPU アラートを設定する。

    Args:
        instance: CloudWatch Alarm の監視対象 EC2 インスタンス
    """

    # -----------------------------------------------------------------------
    # SNS トピック: アラート通知共通
    # -----------------------------------------------------------------------
    topic = aws.sns.Topic(
        f"{PREFIX}-alerts",
        name=f"{PREFIX}-alerts",
        # 転送中のメッセージを KMS で暗号化
        # SNS トピックにコスト情報・EC2 メトリクスが流れるため
        # kms_master_key_id を指定しない場合は SSE-SNS（管理キー）が使われる
        kms_master_key_id="alias/aws/sns",
        tags={**COMMON_TAGS, "Name": f"{PREFIX}-alerts"},
    )

    # SNS メール購読
    # 注意: apply 後、指定アドレスに確認メールが届く。
    # リンクをクリックして購読を確認しないとアラートが届かない。
    #
    # NOTIFICATION_EMAIL は Output[str] 型（Pulumi secret）
    # aws.sns.TopicSubscription の endpoint 引数は Output[str] を受け取れる
    aws.sns.TopicSubscription(
        f"{PREFIX}-alerts-email",
        topic=topic.arn,
        protocol="email",
        endpoint=NOTIFICATION_EMAIL,
        # Output[T] 型の値をリソース引数に直接渡せる。apply() は不要。
        # Pulumi エンジンが依存グラフを解析して NOTIFICATION_EMAIL の解決を待つ。
    )

    # -----------------------------------------------------------------------
    # AWS Budgets: 月次コストアラート
    # -----------------------------------------------------------------------
    # Pulumi の aws.budgets.Budget は Terraform の aws_budgets_budget とほぼ同構造
    # CDK が L1 (CfnBudget) を使う必要があったのと対照的に、
    # Pulumi では通常のリソース定義で完結する
    aws.budgets.Budget(
        f"{PREFIX}-monthly-budget",
        name=f"{PREFIX}-monthly-budget",
        budget_type="COST",
        limit_amount="10",
        limit_unit="USD",
        # MONTHLY: 月初にリセット。検証ラボの $1〜3/月 に対して $10 の余裕を持たせる
        time_unit="MONTHLY",
        notifications=[
            aws.budgets.BudgetNotificationArgs(
                comparison_operator="GREATER_THAN",
                # 80% 超え（= $8 超過見込み）で早期警告
                threshold=80,
                threshold_type="PERCENTAGE",
                notification_type="ACTUAL",
                subscriber_email_addresses=[NOTIFICATION_EMAIL],
                # Output[str] のリストも直接渡せる
            ),
            aws.budgets.BudgetNotificationArgs(
                comparison_operator="GREATER_THAN",
                # 100% 超え（= $10 超過確定）でも別途通知
                # 80% 通知だけでは実際の超過に気づくのが遅れる可能性があるため
                threshold=100,
                threshold_type="PERCENTAGE",
                notification_type="ACTUAL",
                subscriber_email_addresses=[NOTIFICATION_EMAIL],
            ),
        ],
    )

    # -----------------------------------------------------------------------
    # CloudWatch Alarm: EC2 CPU 使用率監視
    # -----------------------------------------------------------------------
    # Pulumi の書き方は Terraform の aws_cloudwatch_metric_alarm と構造が近い
    # CDK の cloudwatch.Alarm (L2) は型安全なメソッドチェーンスタイルだったが、
    # Pulumi は AWS API の引数名をそのまま使う（低レベル操作）
    #
    # instance.id は Output[str] 型
    # dimensions の値に Output[str] を使う場合は apply() が必要:
    #   dimensions=instance.id.apply(lambda id: {"InstanceId": id})
    alarm = aws.cloudwatch.MetricAlarm(
        f"{PREFIX}-cpu-alarm",
        name=f"{PREFIX}-cpu-alarm",
        alarm_description="EC2 CPU 使用率が 80% を 2 回連続で超えた場合にアラート",
        comparison_operator="GreaterThanThreshold",
        evaluation_periods=2,
        metric_name="CPUUtilization",
        namespace="AWS/EC2",
        # period = 300 (5 分): 短すぎるとノイズが多く、長すぎると反応が遅れる
        period=300,
        statistic="Average",
        threshold=80,
        # dimensions に Output[str] を含むため apply() で解決する
        # これが Terraform 経験者が最初に戸惑う「Pulumi の哲学」の典型例
        dimensions=instance.id.apply(lambda id: {"InstanceId": id}),
        alarm_actions=[topic.arn],
        # アラーム解除時も通知: 復旧確認のため
        ok_actions=[topic.arn],
        # データポイント不足時の動作: notBreaching
        # インスタンス停止中に誤アラートが発火するのを防ぐ
        treat_missing_data="notBreaching",
        tags={**COMMON_TAGS, "Name": f"{PREFIX}-cpu-alarm"},
    )

    # Pulumi Outputs として公開（pulumi stack output で確認可能）
    pulumi.export("sns_topic_arn", topic.arn)
    pulumi.export("cloudwatch_alarm_name", alarm.name)
