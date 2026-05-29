"""
Garbage Collector: Unattached EBS Volumes
Finds and deletes all EBS volumes in 'available' state (not attached to any instance).
Usage:
    python garbage_collect_ebs.py              # dry-run (lists only)
    python garbage_collect_ebs.py --delete     # actually deletes
"""

# ── Standard library imports ──────────────────────────────────────────────────
import boto3          # AWS SDK for Python — used to call EC2 APIs
import argparse       # Parses --delete and --region CLI flags
from datetime import datetime, timezone  # Used to calculate how old each volume is

# ── Helper: fetch all unattached EBS volumes ──────────────────────────────────
# Uses a paginator so results are not truncated even in accounts with many volumes.
# The 'available' status filter means the volume exists but is not mounted to any instance.
def get_unattached_volumes(ec2):
    paginator = ec2.get_paginator("describe_volumes")
    volumes = []
    # Iterate every page of results and collect all matching volumes into one list
    for page in paginator.paginate(Filters=[{"Name": "status", "Values": ["available"]}]):
        volumes.extend(page["Volumes"])
    return volumes

# ── Helper: human-readable age string ─────────────────────────────────────────
# Converts a UTC datetime (the volume's CreateTime) into a "Xd Yh" string
# so the operator can quickly judge whether a volume is a recent accident or long-standing waste.
def format_age(create_time):
    age = datetime.now(timezone.utc) - create_time
    return f"{age.days}d {age.seconds // 3600}h"

# ── Main entry point ──────────────────────────────────────────────────────────
def main():
    # ── CLI argument parsing ──────────────────────────────────────────────────
    # --delete  : switches from safe dry-run mode to live deletion mode
    # --region  : optional override; defaults to whatever boto3 resolves from
    #             ~/.aws/config or the AWS_DEFAULT_REGION environment variable
    parser = argparse.ArgumentParser()
    parser.add_argument("--delete", action="store_true", help="Delete unattached volumes (default is dry-run)")
    parser.add_argument("--region", default=None, help="AWS region (default: uses boto3 default)")
    args = parser.parse_args()

    # ── AWS client setup ──────────────────────────────────────────────────────
    # Creates a regional EC2 client; region_name=None lets boto3 use its default resolution chain
    ec2 = boto3.client("ec2", region_name=args.region)

    # ── Volume discovery ──────────────────────────────────────────────────────
    # Calls the helper above; returns an empty list if no unattached volumes exist
    volumes = get_unattached_volumes(ec2)

    # Early exit if there is nothing to report or delete
    if not volumes:
        print("No unattached EBS volumes found.")
        return

    # ── Summary header ────────────────────────────────────────────────────────
    # Totals up GB across all found volumes so the operator sees the cost impact at a glance
    total_gb = sum(v["Size"] for v in volumes)
    print(f"\nFound {len(volumes)} unattached volume(s) — {total_gb} GB total\n")

    # ── Tabular output ────────────────────────────────────────────────────────
    # Prints a fixed-width table: VolumeId | Size | Type | Age | Name tag
    print(f"{'VolumeId':<25} {'Size':>6} {'Type':<10} {'Age':<12} {'Name'}")
    print("-" * 75)

    for v in volumes:
        # Extract the 'Name' tag value; fall back to "-" if the tag is absent
        name = next((t["Value"] for t in v.get("Tags", []) if t["Key"] == "Name"), "-")
        print(f"{v['VolumeId']:<25} {v['Size']:>5}GB {v['VolumeType']:<10} {format_age(v['CreateTime']):<12} {name}")

    # ── Dry-run guard ─────────────────────────────────────────────────────────
    # If --delete was NOT passed, stop here — never touch real resources by default
    if not args.delete:
        print("\n[DRY-RUN] No volumes deleted. Re-run with --delete to remove them.")
        return

    # ── Deletion loop ─────────────────────────────────────────────────────────
    # Iterates the same list and attempts to delete each volume.
    # Failures (e.g. volume became attached between discovery and deletion) are caught
    # individually so one failure does not abort the rest of the cleanup.
    print("\nDeleting volumes...")
    deleted, failed = 0, 0
    for v in volumes:
        try:
            ec2.delete_volume(VolumeId=v["VolumeId"])
            print(f"  ✓ Deleted {v['VolumeId']}")
            deleted += 1
        except Exception as e:
            print(f"  ✗ Failed {v['VolumeId']}: {e}")
            failed += 1

    # ── Final summary ─────────────────────────────────────────────────────────
    # Reports how many volumes were removed and how much storage was freed
    print(f"\nDone. Deleted: {deleted} | Failed: {failed} | Freed: ~{total_gb} GB")

# ── Script entry guard ────────────────────────────────────────────────────────
# Ensures main() only runs when the file is executed directly, not when imported
if __name__ == "__main__":
    main()
