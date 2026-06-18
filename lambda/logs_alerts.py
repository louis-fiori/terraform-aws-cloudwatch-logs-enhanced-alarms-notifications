"""CloudWatch Logs enhanced alerts.

The same function is invoked through two paths:

1. CloudWatch Logs Subscription Filter (event contains ``awslogs``):
   for every log event we either alert immediately (first occurrence or
   back-off window elapsed) or count it silently inside the current
   back-off window.

2. DynamoDB Stream (event contains ``Records``): items expired by TTL,
   i.e. a back-off window that just closed. If errors were counted during
   that window we publish a summary notification.

The back-off window grows over time (Fibonacci-like, capped at ``MAX``)
so that a persistent error does not spam the channel.
"""

import hashlib

import boto3

from base64 import b64decode
from botocore.exceptions import ClientError
from datetime import datetime, timezone
from gzip import decompress
from json import dumps, loads
from os import environ
from re import compile, escape
from time import time


MAX = int(environ['MAX'])
REGION = environ.get('AWS_REGION', 'eu-central-1')
DYNAMODB_TABLE = environ['DYNAMODB_TABLE']
SNS_ARN = environ['SNS_ARN']

NO_TRACE_ID = '1-00000000-000000000000000000000000'

dynamodb_client = boto3.client('dynamodb')
sns_client = boto3.client('sns')


def aws_url_encode(text):
    replace_map = {
        '/': '$252F',
        '[': '$255B',
        '$': '$2524',
        ']': '$255D',
    }
    rx = compile('|'.join(map(escape, replace_map)))
    return rx.sub(lambda match: replace_map[match.group(0)], text)


def error_key(message, log_group):
    """Stable, fixed-length partition key for a given (message, log group)."""
    return hashlib.sha256(f'{message}-{log_group}'.encode('utf-8')).hexdigest()


def unload_payload(data):
    return loads(decompress(b64decode(data)))


def extract_trace_id(message):
    """Return the trace id when the log message is JSON carrying one."""
    try:
        parsed = loads(message)
    except (ValueError, TypeError):
        return None
    if isinstance(parsed, dict):
        return parsed.get('trace_id')
    return None


def build_details(payload, log_event):
    details = {
        'log_group': payload['logGroup'],
        'log_stream': payload['logStream'],
        'owner': payload['owner'],
        'timestamp': log_event['timestamp'],
        'message': log_event['message'],
    }

    trace_id = extract_trace_id(log_event['message'])
    if trace_id:
        details['trace_id'] = trace_id

    return details


def error_analysis(key, details):
    """Deduplicate and apply the exponential back-off.

    Returns ``(is_trigger, counter)`` where ``counter`` is the number of
    occurrences accumulated during the previous window (used to enrich a
    re-alert message).
    """
    now = int(time())

    response = dynamodb_client.get_item(
        TableName=DYNAMODB_TABLE,
        Key={'error_message_hash': {'S': key}},
    )
    item = response.get('Item')

    # First occurrence: create the tracking item and alert immediately.
    if item is None:
        try:
            dynamodb_client.put_item(
                TableName=DYNAMODB_TABLE,
                Item={
                    'error_message_hash': {'S': key},
                    'timestamp': {'N': str(now + 60)},
                    'n': {'N': '1'},
                    'm': {'N': '1'},
                    'counter': {'N': '0'},
                    'details': {'S': dumps(details)},
                    'ttl': {'N': str(now + 120)},
                },
                ConditionExpression='attribute_not_exists(error_message_hash)',
            )
            return True, 0
        except dynamodb_client.exceptions.ConditionalCheckFailedException:
            # A concurrent invocation created it first; fall through to count.
            item = dynamodb_client.get_item(
                TableName=DYNAMODB_TABLE,
                Key={'error_message_hash': {'S': key}},
            ).get('Item')
            if item is None:
                return False, 0

    window_open_at = int(item['timestamp']['N'])

    # Back-off window elapsed: re-alert and widen the next window.
    if now > window_open_at:
        n = int(item['n']['N'])
        m = int(item['m']['N'])
        counter = int(item['counter']['N'])
        window = min(n + m * 60, MAX)
        try:
            dynamodb_client.update_item(
                TableName=DYNAMODB_TABLE,
                Key={'error_message_hash': {'S': key}},
                UpdateExpression='SET #timestamp = :ts, #n = :n, #m = :m, #ttl = :ttl, #counter = :zero',
                ConditionExpression='#timestamp = :prev_ts',
                ExpressionAttributeNames={
                    '#timestamp': 'timestamp',
                    '#n': 'n',
                    '#m': 'm',
                    '#ttl': 'ttl',
                    '#counter': 'counter',
                },
                ExpressionAttributeValues={
                    ':ts': {'N': str(now + window)},
                    ':n': {'N': str(m)},
                    ':m': {'N': str(m + n)},
                    ':ttl': {'N': str(now + 2 * window)},
                    ':zero': {'N': '0'},
                    ':prev_ts': {'N': str(window_open_at)},
                },
            )
            return True, counter
        except dynamodb_client.exceptions.ConditionalCheckFailedException:
            # Another invocation already re-alerted; just count this one.
            pass

    # Inside the back-off window: count silently, atomically (no lost updates).
    dynamodb_client.update_item(
        TableName=DYNAMODB_TABLE,
        Key={'error_message_hash': {'S': key}},
        UpdateExpression='ADD #counter :one',
        ExpressionAttributeNames={'#counter': 'counter'},
        ExpressionAttributeValues={':one': {'N': '1'}},
    )
    return False, 0


def publish_message(details, counter):
    datetime_error = datetime.fromtimestamp(details['timestamp'] / 1000, tz=timezone.utc)
    log_group_path = details['log_group'].replace('/', '%252F')

    try:
        slack_message = {
            "version": "1.0",
            "source": "custom",
            "content": {
                "textType": "client-markdown",
                "title": f":rotating_light: Error on `{details['log_group'].split('/')[-1]}` | Account: `{details['owner']}` | The: `{datetime_error.strftime('%d-%m-%Y')}` at `{datetime_error.strftime('%H:%M:%S')}`",
                "description": f'''
                    :arrow_right: Timestamp: `{datetime_error.strftime('%d-%m-%Y %H:%M:%S')} UTC` \n:arrow_right: Log stream: <https://{REGION}.console.aws.amazon.com/cloudwatch/home?region={REGION}#logsV2:log-groups/log-group/{log_group_path}/log-events/{aws_url_encode(details['log_stream'])}|{details['log_stream']}> \n:arrow_right: Error: `{details['message']}` \n
                '''
            }
        }

        if counter != 0:
            slack_message["content"]["description"] += f"\n :warning: Number of errors since last notification: `{counter}`"

        if details.get("trace_id") and details["trace_id"] != NO_TRACE_ID:
            slack_message["content"]["description"] += f"\n :information_source: Trace ID: <https://{REGION}.console.aws.amazon.com/cloudwatch/home?region={REGION}#xray:traces/{details['trace_id']}|{details['trace_id']}>"

        sns_client.publish(
            TopicArn=SNS_ARN,
            Subject='Cloudwatch Logs Error',
            Message=dumps({'default': dumps(slack_message)}),
            MessageStructure='json'
        )

    except ClientError as e:
        print("An error occured: %s" % e)


def lambda_handler(event, context):
    if "awslogs" in event:
        # CloudWatch Logs Subscription Filter (gzip + base64). A single batch
        # can carry several log events: process them all.
        payload = unload_payload(event['awslogs']['data'])
        for log_event in payload["logEvents"]:
            details = build_details(payload, log_event)
            key = error_key(log_event["message"], payload["logGroup"])
            trigger, counter = error_analysis(key, details)
            if trigger:
                publish_message(details, counter)
    else:
        # DynamoDB Stream: TTL-expired items. A batch can carry several records.
        for record in event['Records']:
            item = record['dynamodb']['OldImage']
            counter = int(item['counter']['N'])
            if counter > 0:
                details = loads(item['details']['S'])
                publish_message(details, counter)
