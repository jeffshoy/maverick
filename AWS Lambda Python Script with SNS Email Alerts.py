import json
import boto3
import datetime

# Initialize AWS clients
cloudwatch = boto3.client('cloudwatch')
sns = boto3.client('sns')

# SNS Topic ARN (Replace with your SNS Topic ARN)
SNS_TOPIC_ARN = "arn:aws:sns:us-east-1:123456789012:CloudWatchAlerts"

# Define multiple EC2 instance IDs
INSTANCE_IDS = ["i-xxxxxxxxxxxxxxxx1", "i-xxxxxxxxxxxxxxxx2"]  # Add more as needed

# Define metrics with thresholds
METRICS = [
    {"Namespace": "AWS/EC2", "MetricName": "CPUUtilization", "Statistics": "Average", "Threshold": 80},  
    {"Namespace": "AWS/EC2", "MetricName": "NetworkIn", "Statistics": "Sum", "Threshold": 100000000},  
    {"Namespace": "AWS/EC2", "MetricName": "NetworkOut", "Statistics": "Sum", "Threshold": 100000000},  
    {"Namespace": "AWS/EC2", "MetricName": "DiskReadOps", "Statistics": "Sum", "Threshold": 5000},  
    {"Namespace": "AWS/EC2", "MetricName": "DiskWriteOps", "Statistics": "Sum", "Threshold": 5000},  
    {"Namespace": "AWS/Lambda", "MetricName": "CallCount", "Statistics": "Sum", "Threshold": 1000},  
    {"Namespace": "AWS/Lambda", "MetricName": "ErrorCount", "Statistics": "Sum", "Threshold": 10},  
    {"Namespace": "AWS/Lambda", "MetricName": "ThrottleCount", "Statistics": "Sum", "Threshold": 5},  
    {"Namespace": "AWS/CloudTrailMetrics", "MetricName": "EventCount", "Statistics": "Sum", "Threshold": 50},  
]

def get_cloudwatch_metric(namespace, metric_name, statistic, instance_id=None):
    """Retrieve CloudWatch metric data."""
    try:
        dimensions = []
        if instance_id and "EC2" in namespace:
            dimensions = [{"Name": "InstanceId", "Value": instance_id}]
        
        response = cloudwatch.get_metric_statistics(
            Namespace=namespace,
            MetricName=metric_name,
            Dimensions=dimensions,
            StartTime=datetime.datetime.utcnow() - datetime.timedelta(minutes=10),
            EndTime=datetime.datetime.utcnow(),
            Period=600,  # 10-minute interval
            Statistics=[statistic]
        )

        datapoints = response.get("Datapoints", [])
        return sorted(datapoints, key=lambda x: x["Timestamp"], reverse=True)[0][statistic] if datapoints else "No Data"
    except Exception as e:
        return f"Error: {str(e)}"

def send_sns_alert(subject, message):
    """Send an email alert using Amazon SNS."""
    try:
        response = sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=subject,
            Message=message
        )
        print(f"SNS Email Alert Sent: {response['MessageId']}")
    except Exception as e:
        print(f"Error sending SNS email alert: {str(e)}")

def lambda_handler(event, context):
    """AWS Lambda function to monitor CloudWatch metrics and send SNS email alerts."""
    results = {}
    alerts = []

    # Monitor EC2 instances
    for instance_id in INSTANCE_IDS:
        instance_metrics = {}
        for metric in METRICS:
            value = get_cloudwatch_metric(metric["Namespace"], metric["MetricName"], metric["Statistics"], instance_id)
            instance_metrics[metric["MetricName"]] = value
            
            if isinstance(value, (int, float)) and value > metric["Threshold"]:
                alert_msg = f"ALERT: {metric['MetricName']} for Instance {instance_id} exceeded threshold!\nValue: {value}, Threshold: {metric['Threshold']}"
                alerts.append(alert_msg)

        results[instance_id] = instance_metrics

    # Monitor account-wide AWS services (Lambda, CloudTrail, etc.)
    account_metrics = {}
    for metric in METRICS:
        if "EC2" not in metric["Namespace"]:  # Skip EC2 metrics here
            value = get_cloudwatch_metric(metric["Namespace"], metric["MetricName"], metric["Statistics"])
            account_metrics[metric["MetricName"]] = value

            if isinstance(value, (int, float)) and value > metric["Threshold"]:
                alert_msg = f"ALERT: {metric['MetricName']} exceeded threshold!\nValue: {value}, Threshold: {metric['Threshold']}"
                alerts.append(alert_msg)

    results["Account_Metrics"] = account_metrics

    # Send SNS email alert if any threshold is breached
    if alerts:
        alert_message = "\n".join(alerts)
        send_sns_alert("AWS CloudWatch Alert", alert_message)

    # Log the results
    print(json.dumps(results, indent=4))
    
    return {
        "statusCode": 200,
        "body": json.dumps(results)
    }
