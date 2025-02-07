import boto3
import time

# Initialize EC2 client
ec2_client = boto3.client('ec2')

# Mapping instance sizes for scaling (Modify based on use case)
instance_types = {
    "t3.micro": "t3.small",
    "t3.small": "t3.medium",
    "t3.medium": "t3.large",
    "t3.large": "t3.xlarge"
}

def lambda_handler(event, context):
    instance_id = "i-xxxxxxxxxxxxxx"  # Replace with your instance ID

    # Get instance details
    response = ec2_client.describe_instances(InstanceIds=[instance_id])
    instance_type = response["Reservations"][0]["Instances"][0]["InstanceType"]
    state = response["Reservations"][0]["Instances"][0]["State"]["Name"]

    # Ensure instance is running
    if state != "running":
        print(f"Instance {instance_id} is not running.")
        return

    # Get latest CPU utilization from CloudWatch
    cloudwatch = boto3.client("cloudwatch")
    metric = cloudwatch.get_metric_statistics(
        Namespace="AWS/EC2",
        MetricName="CPUUtilization",
        Dimensions=[{"Name": "InstanceId", "Value": instance_id}],
        StartTime=time.time() - 3600,  # Last hour
        EndTime=time.time(),
        Period=300,  # 5-minute intervals
        Statistics=["Average"]
    )

    # Extract CPU usage
    if "Datapoints" in metric and metric["Datapoints"]:
        avg_cpu = metric["Datapoints"][-1]["Average"]
    else:
        print("No CPU data available.")
        return

    print(f"Instance {instance_id} - Current CPU Usage: {avg_cpu}%")

    # Check if scaling up is needed
    if avg_cpu > 80 and instance_type in instance_types:
        new_instance_type = instance_types[instance_type]
        print(f"Scaling up from {instance_type} to {new_instance_type}")
        modify_instance(instance_id, new_instance_type)

    # Check if scaling down is possible
    elif avg_cpu < 20:
        prev_instance_type = [key for key, value in instance_types.items() if value == instance_type]
        if prev_instance_type:
            new_instance_type = prev_instance_type[0]
            print(f"Scaling down from {instance_type} to {new_instance_type}")
            modify_instance(instance_id, new_instance_type)

def modify_instance(instance_id, new_type):
    """Modify the EC2 instance type."""
    ec2_client.stop_instances(InstanceIds=[instance_id])
    print(f"Stopping instance {instance_id}...")
    
    # Wait for the instance to stop
    waiter = ec2_client.get_waiter('instance_stopped')
    waiter.wait(InstanceIds=[instance_id])

    # Modify the instance type
    ec2_client.modify_instance_attribute(InstanceId=instance_id, InstanceType={"Value": new_type})
    print(f"Instance {instance_id} type changed to {new_type}")

    # Start the instance back
    ec2_client.start_instances(InstanceIds=[instance_id])
    print(f"Starting instance {instance_id}...")
