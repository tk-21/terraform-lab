#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { ItlDevStack } from '../lib/itl-dev-stack';

const app = new cdk.App();

// CDKではenvをコード上で明示することで、Terraformのprovider設定に相当する役割を果たす
// CDK_DEFAULT_ACCOUNT / CDK_DEFAULT_REGION は `cdk deploy` 実行時の認証情報から自動解決される
new ItlDevStack(app, 'ItlDevStack', {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: 'ap-northeast-1',
  },
  notificationEmail: process.env.NOTIFICATION_EMAIL ?? 'o.takuya.0220@gmail.com',
  // スタックの説明: CloudFormationコンソールで確認可能
  description: 'iac-trilogy-lab Phase 2: CDK実装（Terraform実装との比較検証用）',
});
