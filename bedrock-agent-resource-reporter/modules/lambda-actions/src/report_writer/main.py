import json
import boto3
import os
from datetime import datetime, timedelta

BUCKET_NAME = os.environ.get('REPORTS_BUCKET_NAME', '')


def lambda_handler(event, context):
    action_group = event.get('actionGroup', '')
    api_path = event.get('apiPath', '')
    http_method = event.get('httpMethod', 'POST')

    try:
        body = {}
        rb = event.get('requestBody', {})
        if rb and 'content' in rb:
            body = json.loads(rb['content'].get('application/json', {}).get('body', '{}'))

        if api_path == '/generate_report':
            result = generate_report(body)
        elif api_path == '/save_to_s3':
            result = save_to_s3(body)
        elif api_path == '/list_past_reports':
            result = list_past_reports()
        else:
            return _build_response(action_group, api_path, http_method, 400, {'error': f'Unknown path: {api_path}'})
    except Exception as e:
        return _build_response(action_group, api_path, http_method, 500, {'error': str(e)})

    return _build_response(action_group, api_path, http_method, 200, result)


def generate_report(params):
    title = params.get('title', 'AWS Resource Report')
    data = params.get('data', {})

    lines = [
        f"# {title}",
        "",
        f"**Generated at:** {datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')}",
        "",
        "## Summary",
        ""
    ]

    if 'ec2_instances' in data:
        inst = data['ec2_instances']
        lines += [
            "### EC2 Instances",
            "",
            f"Region: {inst.get('region')} | Count: {inst.get('count', 0)}",
            ""
        ]
        lines += [
            f"- `{i.get('instance_id')}` ({i.get('instance_type')}) - {i.get('state')} - {i.get('name', 'unnamed')}"
            for i in inst.get('instances', [])[:10]
        ]
        lines.append("")

    if 'costs' in data:
        costs = data['costs']
        lines += [
            "### Cost Summary",
            "",
            f"Period: {costs.get('period')}",
            ""
        ]
        lines += [f"- {s}: {a}" for s, a in list(costs.get('costs', {}).items())[:10]]
        lines.append("")

    if 'alarms' in data:
        alarms = data['alarms']
        lines += [
            "### CloudWatch Alarms",
            "",
            f"Total: {alarms.get('count', 0)}",
            ""
        ]
        lines += [f"- {a.get('name')}: {a.get('state')}" for a in alarms.get('alarms', [])[:10]]
        lines.append("")

    content = "\n".join(lines)
    return {'title': title, 'content': content, 'lines': len(lines)}


def save_to_s3(params):
    s3 = boto3.client('s3')
    title = params.get('title', 'report')
    content = params.get('content', '')
    key = f"reports/{datetime.utcnow().strftime('%Y-%m-%d')}/{title.replace(' ', '_')[:50]}.md"
    s3.put_object(
        Bucket=BUCKET_NAME,
        Key=key,
        Body=content.encode('utf-8'),
        ContentType='text/markdown'
    )
    return {
        'bucket': BUCKET_NAME,
        'key': key,
        's3_uri': f"s3://{BUCKET_NAME}/{key}",
        'size_bytes': len(content.encode('utf-8'))
    }


def list_past_reports():
    s3 = boto3.client('s3')
    cutoff = (datetime.utcnow() - timedelta(days=30)).strftime('%Y-%m-%d')
    resp = s3.list_objects_v2(Bucket=BUCKET_NAME, Prefix='reports/')
    reports = [
        {
            'key': o['Key'],
            's3_uri': f"s3://{BUCKET_NAME}/{o['Key']}",
            'last_modified': str(o['LastModified']),
            'size_bytes': o['Size']
        }
        for o in resp.get('Contents', [])
        if (o['Key'].split('/')[1] if len(o['Key'].split('/')) > 2 else '') >= cutoff
    ]
    return {'reports': reports, 'count': len(reports)}


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
