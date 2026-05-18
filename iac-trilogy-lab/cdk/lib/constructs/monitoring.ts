import * as cdk from 'aws-cdk-lib';
import * as budgets from 'aws-cdk-lib/aws-budgets';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as actions from 'aws-cdk-lib/aws-cloudwatch-actions';
import * as sns from 'aws-cdk-lib/aws-sns';
import * as subscriptions from 'aws-cdk-lib/aws-sns-subscriptions';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import { Construct } from 'constructs';

export interface MonitoringProps {
  prefix: string;
  notificationEmail: string;
  instance: ec2.Instance;
  commonTags: Record<string, string>;
}

// 【TerraformとCDKの違い・監視層】
//   AWS Budgets は CDK の L2 Construct が存在しない（v2.254時点）
//   → budgets.CfnBudget（L1: CloudFormation相当）を直接使う必要がある
//   TerraformのHCLで宣言的に書いた aws_budgets_budget と比較すると、
//   CDKではJSONライクなオブジェクトを渡す形式になる（型補完あり）
//
//   CloudWatch Alarm は L2 Construct（cloudwatch.Alarm）が利用可能
//   → Terraformの aws_cloudwatch_metric_alarm と比較して型安全に書ける
export class Monitoring extends Construct {
  public readonly alertsTopic: sns.Topic;

  constructor(scope: Construct, id: string, props: MonitoringProps) {
    super(scope, id);

    // -----------------------------------------------------------------------
    // SNS トピック: アラート通知共通
    // -----------------------------------------------------------------------
    this.alertsTopic = new sns.Topic(this, 'AlertsTopic', {
      topicName: `${props.prefix}-alerts`,
      displayName: 'itl-dev Alerts',
      // 転送中のメッセージをKMSで暗号化（SNSトピックにコスト情報・EC2メトリクスが流れるため）
      // CDK L2の masterKey プロパティで設定。Terraformの kms_master_key_id と同等
      masterKey: undefined, // SSE-SNS（管理キー）を使用
    });

    // SNSメール購読
    // 注意: デプロイ後、指定アドレスに確認メールが届く。
    // リンクをクリックして購読を確認しないとアラートが届かない。
    this.alertsTopic.addSubscription(
      new subscriptions.EmailSubscription(props.notificationEmail)
    );

    cdk.Tags.of(this.alertsTopic).add('Name', `${props.prefix}-alerts`);

    // -----------------------------------------------------------------------
    // AWS Budgets: 月次コストアラート（L1 Construct使用）
    // -----------------------------------------------------------------------
    // L2がないためCfnBudgetを直接使用。型補完は効くが、
    // プロパティ名がCloudFormationの仕様そのままなのでTerraformより冗長に感じる
    new budgets.CfnBudget(this, 'MonthlyBudget', {
      budget: {
        budgetName: `${props.prefix}-monthly-budget`,
        budgetType: 'COST',
        timeUnit: 'MONTHLY',
        // MONTHLY: 月初にリセット。検証ラボの $1〜3/月 に対して $10 の余裕を持たせる
        budgetLimit: {
          amount: 10,
          unit: 'USD',
        },
      },
      // Budgets の通知設定: TerraformのNotificationブロックに相当
      // CDKでは notificationsWithSubscribers の配列で複数通知を定義
      notificationsWithSubscribers: [
        {
          notification: {
            // 80%超え（= $8 超過見込み）で早期警告
            comparisonOperator: 'GREATER_THAN',
            threshold: 80,
            thresholdType: 'PERCENTAGE',
            notificationType: 'ACTUAL',
          },
          subscribers: [
            {
              subscriptionType: 'EMAIL',
              address: props.notificationEmail,
            },
          ],
        },
        {
          notification: {
            // 100%超え（= $10 超過確定）でも別途通知
            // 80%通知だけでは実際の超過に気づくのが遅れる可能性があるため
            comparisonOperator: 'GREATER_THAN',
            threshold: 100,
            thresholdType: 'PERCENTAGE',
            notificationType: 'ACTUAL',
          },
          subscribers: [
            {
              subscriptionType: 'EMAIL',
              address: props.notificationEmail,
            },
          ],
        },
      ],
    });

    // -----------------------------------------------------------------------
    // CloudWatch Alarm: EC2 CPU使用率監視（L2 Construct使用）
    // -----------------------------------------------------------------------
    // L2が使えるためTerraformよりも型安全に記述できる
    // cloudwatch.Alarm の型補完によりnamespace/metricNameのタイポを防げる
    const cpuAlarm = new cloudwatch.Alarm(this, 'Ec2CpuAlarm', {
      alarmName: `${props.prefix}-cpu-alarm`,
      alarmDescription: 'EC2 CPU使用率が80%を2回連続で超えた場合にアラート',
      metric: new cloudwatch.Metric({
        namespace: 'AWS/EC2',
        metricName: 'CPUUtilization',
        dimensionsMap: {
          InstanceId: props.instance.instanceId,
        },
        // period = 5分: 短すぎるとノイズが多く、長すぎると反応が遅れる。5分が標準的な妥協点
        period: cdk.Duration.minutes(5),
        statistic: 'Average',
      }),
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      threshold: 80,
      evaluationPeriods: 2,
      // データポイント不足時: NOTBREACHING → インスタンス停止中の誤アラートを防ぐ
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });

    // アラーム発火時・解除時にSNS通知
    cpuAlarm.addAlarmAction(new actions.SnsAction(this.alertsTopic));
    // アラーム解除時も通知: 復旧確認のため
    cpuAlarm.addOkAction(new actions.SnsAction(this.alertsTopic));

    cdk.Tags.of(cpuAlarm).add('Name', `${props.prefix}-cpu-alarm`);
  }
}
