"""
Garbage Collector: Unassociated Elastic IPs
Finds and releases all Elastic IPs in a VPC that are not associated with any
running instance or network interface.
Usage:
    python garbage_collect_eips.py              # dry-run (lists only)
    python garbage_collect_eips.py --release    # actually releases
"""

import boto3
import argparse


def get_unassociated_eips(ec2):
    response = ec2.describe_addresses(Filters=[{"Name": "domain", "Values": ["vpc"]}])
    return [a for a in response["Addresses"] if "AssociationId" not in a]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--release", action="store_true", help="Release unassociated EIPs (default is dry-run)")
    parser.add_argument("--region", default=None, help="AWS region (default: uses boto3 default)")
    args = parser.parse_args()

    ec2 = boto3.client("ec2", region_name=args.region)
    eips = get_unassociated_eips(ec2)

    if not eips:
        print("No unassociated Elastic IPs found.")
        return

    cost_per_ip = 3.65
    total_cost = len(eips) * cost_per_ip
    print(f"\nFound {len(eips)} unassociated Elastic IP(s) — ~${total_cost:.2f}/month wasted\n")

    print(f"{'AllocationId':<25} {'PublicIp':<18} {'Name'}")
    print("-" * 65)
    for a in eips:
        name = next((t["Value"] for t in a.get("Tags", []) if t["Key"] == "Name"), "-")
        print(f"{a['AllocationId']:<25} {a.get('PublicIp', 'N/A'):<18} {name}")

    if not args.release:
        print("\n[DRY-RUN] No EIPs released. Re-run with --release to remove them.")
        return

    print("\nReleasing EIPs...")
    released, failed = 0, 0
    for a in eips:
        try:
            ec2.release_address(AllocationId=a["AllocationId"])
            print(f"  ✓ Released {a['AllocationId']} ({a.get('PublicIp', 'N/A')})")
            released += 1
        except Exception as e:
            print(f"  ✗ Failed  {a['AllocationId']}: {e}")
            failed += 1

    print(f"\nDone. Released: {released} | Failed: {failed} | Saved: ~${released * cost_per_ip:.2f}/month")


if __name__ == "__main__":
    main()
