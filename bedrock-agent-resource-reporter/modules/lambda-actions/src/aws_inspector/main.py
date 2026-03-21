import json
import os
import boto3
from datetime import datetime, timedelta

REGION = os.environ.get('REGION', 'ap-northeast-1')


def lambda_handler(event, context):
    action_group = event.get('actionGroup', '')
    api_path = event.get('apiPath', '')
    http_method = event.get('httpMethod', 'POST')

    try:
        if api_path == '/get_cost_and_usage':
            result = get_cost_and_usage()
        elif api_path == '/list_ec2_instances':
            body = {}
            rb = event.get('requestBody', {})
            if rb and 'content' in rb:
                body = json.loads(rb['content'].get('application/json', {}).get('body', '{}'))
            result = list_ec2_instances(body.get('region', 'ap-northeast-1'))
        elif api_path == '/get_cw_alarms':
            result = get_cw_alarms()
        else:
            return _build_response(action_group, api_path, http_method, 400, {'error': f'Unknown path: {api_path}'})
    except Exception as e:
        return _build_response(action_group, api_path, http_method, 500, {'error': str(e)})

    return _build_response(action_group, api_path, http_method, 200, result)


def get_cost_and_usage():
    ce = boto3.client('ce', region_name='us-east-1')
    end = datetime.now().strftime('%Y-%m-%d')
    start = (datetime.now() - timedelta(days=30)).strftime('%Y-%m-%d')
    resp = ce.get_cost_and_usage(
        TimePeriod={'Start': start, 'End': end},
        Granularity='MONTHLY',
        Metrics=['BlendedCost'],
        GroupBy=[{'Type': 'DIMENSION', 'Key': 'SERVICE'}]
    )
    costs = {}
    for r in resp.get('ResultsByTime', []):
        for g in r.get('Groups', []):
            costs[g['Keys'][0]] = f"{float(g['Metrics']['BlendedCost']['Amount']):.4f} {g['Metrics']['BlendedCost']['Unit']}"
    return {'period': f"{start} to {end}", 'costs': costs}


def list_ec2_instances(region='ap-northeast-1'):
    ec2 = boto3.client('ec2', region_name=region)
    resp = ec2.describe_instances()
    instances = []
    for rsv in resp.get('Reservations', []):
        for i in rsv.get('Instances', []):
            name = next((t['Value'] for t in i.get('Tags', []) if t['Key'] == 'Name'), '')
            instances.append({
                'instance_id': i['InstanceId'],
                'instance_type': i['InstanceType'],
                'state': i['State']['Name'],
                'name': name,
                'launch_time': str(i.get('LaunchTime', ''))
            })
    return {'region': region, 'instances': instances, 'count': len(instances)}


def get_cw_alarms():
    cw = boto3.client('cloudwatch', region_name=REGION)
    resp = cw.describe_alarms()
    alarms = [
        {
            'name': a['AlarmName'],
            'state': a['StateValue'],
            'metric': a.get('MetricName', ''),
            'description': a.get('AlarmDescription', '')
        }
        for a in resp.get('MetricAlarms', [])
    ]
    return {'alarms': alarms, 'count': len(alarms)}


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
