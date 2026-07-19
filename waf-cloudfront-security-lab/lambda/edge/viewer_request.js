'use strict';

// CloudFront が付与するカスタムヘッダーの期待値
// Lambda@Edge は環境変数が使えないため、Terraform の local_file リソースで
// "__REPLACE_AT_DEPLOY__" をデプロイ時に SSM の値へ置換して埋め込む
const EXPECTED_SECRET = '__REPLACE_AT_DEPLOY__';

exports.handler = async (event) => {
  const request = event.Records[0].cf.request;
  const headers = request.headers;

  // 1. CloudFront カスタムヘッダー検証
  //    CloudFront を経由せずに ALB へ直接アクセスするリクエストは
  //    このヘッダーを持たないため 403 で返す
  const cfSecret = headers['x-cloudfront-secret'];
  if (!cfSecret || cfSecret[0].value !== EXPECTED_SECRET) {
    return {
      status: '403',
      statusDescription: 'Forbidden',
      body: 'Access Denied',
    };
  }

  // 2. Host ヘッダー検証（ホストヘッダーインジェクション対策）
  const host = headers['host'];
  if (!host) {
    return {
      status: '400',
      statusDescription: 'Bad Request',
      body: 'Missing Host Header',
    };
  }

  // 3. 検証を通過したリクエストをそのままオリジンへ転送
  return request;
};
