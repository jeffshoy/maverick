import boto3
import json

# AWS Clients
ec2 = boto3.client('ec2')
guardduty = boto3.client('guardduty')

# Set your GuardDuty Detector ID and Security Group ID
GUARDDUTY_DETECTOR_ID = "your-guardduty-detector-id"
SECURITY_GROUP_ID = "your-security-group-id"
BLOCKED_PORT = 22  # SSH

def lambda_handler(event, context):
    try:
        # Get GuardDuty findings
        findings = guardduty.list_findings(DetectorId=GUARDDUTY_DETECTOR_ID)
        
        if not findings["FindingIds"]:
            print("No new GuardDuty findings.")
            return {"message": "No new threats detected."}

        # Get details of each finding
        for finding_id in findings["FindingIds"]:
            finding = guardduty.get_findings(DetectorId=GUARDDUTY_DETECTOR_ID, FindingIds=[finding_id])
            for item in finding["Findings"]:
                if "Brute Force" in item["Title"] and "SSH" in item["Description"]:
                    attacker_ip = item["Resource"]["InstanceDetails"]["NetworkInterfaces"][0]["PublicIp"]

                    print(f"Blocking IP: {attacker_ip}")

                    # Block IP in Security Group
                    ec2.authorize_security_group_ingress(
                        GroupId=SECURITY_GROUP_ID,
                        IpPermissions=[{
                            'IpProtocol': 'tcp',
                            'FromPort': BLOCKED_PORT,
                            'ToPort': BLOCKED_PORT,
                            'IpRanges': [{'CidrIp': f"{attacker_ip}/32"}]
                        }]
                    )
                    print(f"IP {attacker_ip} blocked successfully.")

        return {"message": "Blocking process completed."}

    except Exception as e:
        print(f"Error: {str(e)}")
        return {"error": str(e)}
