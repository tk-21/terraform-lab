import json
import boto3
import os
from datetime import datetime

SNS_TOPIC_ARN = os.environ.get('SNS_TOPIC_ARN', '')
REGION = os.environ.get('REGION', 'ap-northeast-1')


def lambda_handler(event, context):
    action_group = event.get('actionGroup', '')
    api_path = event.get('apiPath', '')
    http_method = event.get('httpMethod', 'POST')

    try:
        body = {}
        rb = event.get('requestBody', {})
        if rb and 'content' in rb:
            body = json.loads(rb['content'].get('application/json', {}).get('body', '{}'))

        if api_path == '/send_sns_notification':
            result = send_sns_notification(body)
        else:
            return _build_response(action_group, api_path, http_method, 400, {'error': f'Unknown path: {api_path}'})
    except Exception as e:
        return _build_response(action_group, api_path, http_method, 500, {'error': str(e)})

    return _build_response(action_group, api_path, http_method, 200, result)


def send_sns_notification(params):
    sns = boto3.client('sns', region_name=REGION)
    subject = params.get('subject', 'AWS Resource Report Notification')
    message = params.get('message', '')
    report_uri = params.get('report_uri', '')

    full_msg = message
    if report_uri:
        full_msg += f"\n\nReport saved to: {report_uri}"
    full_msg += f"\n\nTimestamp: {datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')}"

    resp = sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=subject[:100],
        Message=full_msg
    )
    return {
        'message_id': resp['MessageId'],
        'topic_arn': SNS_TOPIC_ARN,
        'subject': subject
    }


def _build_response(action_group, api_path, http_method, status_code, result):
    return {
        'messageVersion': '1.0',
        'response': {
            'actionGroup': action_group,
            'apiPath': api_path,
            'httpMethod': http_method,
            'httpStatusCode': status_code,
            'responseBody': {
                'application/json': {
                    'body': json.dumps(result, ensure_ascii=False)
                }
            }
        }
    }
