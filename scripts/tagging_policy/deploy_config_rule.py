"""
Deploys the AWS Config REQUIRED_TAGS rule to enforce CostCenter tag
on EC2 instances and EBS volumes.

Sets up the full Config prerequisites if they don't already exist:
  1. S3 bucket for Config snapshots (delivery channel)
  2. IAM role for the Config service
  3. Configuration recorder
  4. Delivery channel
  5. Starts the recorder
  6. Creates the REQUIRED_TAGS rule

Usage:
    python3 deploy_config_rule.py
    python3 deploy_config_rule.py --region eu-central-1
"""

import boto3
import json
import argparse
import time

RULE = {
    "ConfigRuleName": "require-costcenter-tag-on-ec2",
    "Description": "Checks that EC2 instances and EBS volumes have a CostCenter tag.",
    "Source": {
        "Owner": "AWS",
        "SourceIdentifier": "REQUIRED_TAGS",
    },
    "Scope": {
        "ComplianceResourceTypes": [
            "AWS::EC2::Instance",
            "AWS::EC2::Volume",
        ]
    },
    "InputParameters": json.dumps({"tag1Key": "CostCenter"}),
}

CONFIG_SERVICE_PRINCIPAL = "config.amazonaws.com"

CONFIG_ROLE_POLICY = {
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": CONFIG_SERVICE_PRINCIPAL},
        "Action": "sts:AssumeRole"
    }]
}


def ensure_s3_bucket(s3, account_id, region):
    bucket_name = f"cost-detective-config-{account_id}"
    try:
        if region == "us-east-1":
            s3.create_bucket(Bucket=bucket_name)
        else:
            s3.create_bucket(
                Bucket=bucket_name,
                CreateBucketConfiguration={"LocationConstraint": region}
            )
        print(f"  ✓ S3 bucket created: {bucket_name}")
    except s3.exceptions.BucketAlreadyOwnedByYou:
        print(f"  ✓ S3 bucket already exists: {bucket_name}")
    except Exception as e:
        if "BucketAlreadyExists" in str(e):
            print(f"  ✓ S3 bucket already exists: {bucket_name}")
        else:
            raise

    # Attach a bucket policy allowing Config to write to it
    bucket_policy = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "AWSConfigBucketPermissionsCheck",
                "Effect": "Allow",
                "Principal": {"Service": CONFIG_SERVICE_PRINCIPAL},
                "Action": "s3:GetBucketAcl",
                "Resource": f"arn:aws:s3:::{bucket_name}"
            },
            {
                "Sid": "AWSConfigBucketDelivery",
                "Effect": "Allow",
                "Principal": {"Service": CONFIG_SERVICE_PRINCIPAL},
                "Action": "s3:PutObject",
                "Resource": f"arn:aws:s3:::{bucket_name}/AWSLogs/{account_id}/Config/*",
                "Condition": {
                    "StringEquals": {"s3:x-amz-acl": "bucket-owner-full-control"}
                }
            }
        ]
    }
    s3.put_bucket_policy(Bucket=bucket_name, Policy=json.dumps(bucket_policy))
    print("  ✓ Bucket policy applied")
    return bucket_name


def ensure_config_role(iam):
    role_name = "CostDetectiveConfigRole"
    try:
        role = iam.get_role(RoleName=role_name)
        print(f"  ✓ IAM role already exists: {role_name}")
        return role["Role"]["Arn"]
    except iam.exceptions.NoSuchEntityException:
        pass

    role = iam.create_role(
        RoleName=role_name,
        AssumeRolePolicyDocument=json.dumps(CONFIG_ROLE_POLICY),
        Description="Service role for AWS Config - Cost Detective audit",
    )
    iam.attach_role_policy(
        RoleName=role_name,
        PolicyArn="arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
    )
    print(f"  ✓ IAM role created: {role_name}")
    print("  ⏳ Waiting 15s for IAM propagation...")
    time.sleep(15)
    return role["Role"]["Arn"]


def ensure_recorder(config_client, role_arn):
    recorders = config_client.describe_configuration_recorders().get("ConfigurationRecorders", [])
    if recorders:
        print(f"  ✓ Configuration recorder already exists: {recorders[0]['name']}")
        return

    config_client.put_configuration_recorder(
        ConfigurationRecorder={
            "name": "cost-detective-recorder",
            "roleARN": role_arn,
            "recordingGroup": {
                "allSupported": False,
                "includeGlobalResourceTypes": False,
                "resourceTypes": [
                    "AWS::EC2::Instance",
                    "AWS::EC2::Volume"
                ]
            }
        }
    )
    print("  ✓ Configuration recorder created")


def ensure_delivery_channel(config_client, bucket_name):
    channels = config_client.describe_delivery_channels().get("DeliveryChannels", [])
    if channels:
        print(f"  ✓ Delivery channel already exists: {channels[0]['name']}")
        return

    config_client.put_delivery_channel(
        DeliveryChannel={
            "name": "cost-detective-delivery",
            "s3BucketName": bucket_name,
        }
    )
    print("  ✓ Delivery channel created")


def start_recorder(config_client):
    status = config_client.describe_configuration_recorder_status()
    statuses = status.get("ConfigurationRecordersStatus", [])
    if statuses and statuses[0].get("recording"):
        print("  ✓ Recorder already running")
        return

    config_client.start_configuration_recorder(
        ConfigurationRecorderName="cost-detective-recorder"
    )
    print("  ✓ Recorder started")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--region", default=None)
    parser.add_argument("--profile", default=None, help="AWS CLI profile name")
    args = parser.parse_args()

    session = boto3.session.Session(profile_name=args.profile)
    region = args.region or session.region_name or "eu-central-1"

    sts = session.client("sts", region_name=region)
    account_id = sts.get_caller_identity()["Account"]

    s3 = session.client("s3", region_name=region)
    iam = session.client("iam", region_name=region)
    config_client = session.client("config", region_name=region)

    print("\n[1/5] Setting up S3 delivery bucket...")
    bucket_name = ensure_s3_bucket(s3, account_id, region)

    print("\n[2/5] Setting up Config IAM role...")
    role_arn = ensure_config_role(iam)

    print("\n[3/5] Setting up configuration recorder...")
    ensure_recorder(config_client, role_arn)

    print("\n[4/5] Setting up delivery channel...")
    ensure_delivery_channel(config_client, bucket_name)

    print("\n[5/5] Starting recorder and deploying rule...")
    start_recorder(config_client)
    time.sleep(2)
    config_client.put_config_rule(ConfigRule=RULE)
    print(f"  ✓ Config rule '{RULE['ConfigRuleName']}' deployed")

    print("\nDone. Check AWS Config -> Rules in ~10 minutes for compliance results.")


if __name__ == "__main__":
    main()
