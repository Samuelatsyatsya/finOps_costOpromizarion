"""
Deploys the AWS Config REQUIRED_TAGS rule to enforce CostCenter tag
on EC2 instances and EBS volumes.
Usage:
    python deploy_config_rule.py
    python deploy_config_rule.py --region eu-west-1
"""

# ── Standard library imports ──────────────────────────────────────────────────
import boto3    # AWS SDK — used to call the AWS Config API
import json     # Serialises the InputParameters dict into the JSON string the API expects
import argparse # Parses the optional --region CLI flag

# ── Config rule definition ────────────────────────────────────────────────────
# Defined at module level so it can be inspected or imported without running main().
#
# REQUIRED_TAGS is an AWS-managed rule (Owner: "AWS") — no Lambda function needed.
# It evaluates resources at creation time and on a periodic schedule.
#
# Scope limits evaluation to EC2 instances and EBS volumes only;
# other resource types are ignored by this rule.
#
# InputParameters specifies which tag key(s) must be present.
# "tag1Key": "CostCenter" means every in-scope resource must have a CostCenter tag.
# Up to 6 tag keys (tag1Key–tag6Key) can be enforced by a single REQUIRED_TAGS rule.
RULE = {
    "ConfigRuleName": "require-costcenter-tag-on-ec2",
    "Description": "Checks that EC2 instances and EBS volumes have a CostCenter tag.",
    "Source": {
        "Owner": "AWS",                    # AWS-managed rule — no custom Lambda required
        "SourceIdentifier": "REQUIRED_TAGS",
    },
    "Scope": {
        # Only these two resource types are evaluated; everything else is out of scope
        "ComplianceResourceTypes": [
            "AWS::EC2::Instance",
            "AWS::EC2::Volume",
        ]
    },
    # The API requires InputParameters as a JSON-encoded string, not a dict
    "InputParameters": json.dumps({"tag1Key": "CostCenter"}),
}

# ── Main entry point ──────────────────────────────────────────────────────────
def main():
    # ── CLI argument parsing ──────────────────────────────────────────────────
    # --region is optional; defaults to boto3's resolution chain
    # (AWS_DEFAULT_REGION env var → ~/.aws/config → instance metadata)
    parser = argparse.ArgumentParser()
    parser.add_argument("--region", default=None)
    args = parser.parse_args()

    # ── AWS client setup ──────────────────────────────────────────────────────
    # AWS Config is a regional service — the rule is deployed to one region at a time.
    # To enforce tagging across all regions, run this script once per active region.
    config = boto3.client("config", region_name=args.region)

    # ── Rule deployment ───────────────────────────────────────────────────────
    # put_config_rule is idempotent: calling it again with the same name updates the rule
    # rather than creating a duplicate. Safe to re-run after changing parameters.
    config.put_config_rule(ConfigRule=RULE)

    # ── Confirmation output ───────────────────────────────────────────────────
    # AWS Config evaluates existing resources asynchronously after the rule is created.
    # Non-compliant resources typically appear in the console within ~10 minutes.
    print(f"Config rule '{RULE['ConfigRuleName']}' deployed successfully.")
    print("Non-compliant resources will appear in AWS Config > Rules within ~10 minutes.")

# ── Script entry guard ────────────────────────────────────────────────────────
if __name__ == "__main__":
    main()
