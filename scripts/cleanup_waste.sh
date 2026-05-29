#!/bin/bash
# =============================================================================
# cleanup_waste.sh
# Tears down all zombie resources created by simulate_waste.sh.
#
# Pass the resource IDs printed by simulate_waste.sh as environment variables:
#   ALLOC_ID          — AllocationId of the Elastic IP to release
#   IDLE_INSTANCE_ID  — InstanceId of the m5.xlarge idle instance
#   EBS_INSTANCE_ID   — InstanceId of the t2.micro donor instance (stopped)
#   VOLUME_ID         — VolumeId of the detached zombie EBS volume
#
# Usage:
#   export ALLOC_ID=eipalloc-xxxx IDLE_INSTANCE_ID=i-xxxx \
#          EBS_INSTANCE_ID=i-xxxx VOLUME_ID=vol-xxxx
#   bash scripts/cleanup_waste.sh
#
# Or pass inline:
#   ALLOC_ID=... IDLE_INSTANCE_ID=... EBS_INSTANCE_ID=... VOLUME_ID=... \
#     bash scripts/cleanup_waste.sh
# =============================================================================

set -euo pipefail

REGION="${REGION:-eu-central-1}"
export AWS_PROFILE="${AWS_PROFILE:-cost-detective}"

# ── Validate required inputs ───────────────────────────────────────────────────
: "${ALLOC_ID:?Set ALLOC_ID to the Elastic IP AllocationId (eipalloc-xxxx)}"
: "${IDLE_INSTANCE_ID:?Set IDLE_INSTANCE_ID to the m5.xlarge instance ID (i-xxxx)}"
: "${EBS_INSTANCE_ID:?Set EBS_INSTANCE_ID to the t2.micro donor instance ID (i-xxxx)}"
: "${VOLUME_ID:?Set VOLUME_ID to the zombie EBS volume ID (vol-xxxx)}"

echo "============================================="
echo " Cost Detective — Waste Cleanup"
echo " Region : $REGION"
echo " Profile: $AWS_PROFILE"
echo "============================================="
echo ""
echo "Resources to destroy:"
echo "   Elastic IP    : $ALLOC_ID"
echo "   Idle Instance : $IDLE_INSTANCE_ID (m5.xlarge)"
echo "   Donor Instance: $EBS_INSTANCE_ID (t2.micro)"
echo "   Zombie Volume : $VOLUME_ID"
echo ""

# ── 1. Release unassociated Elastic IP ───────────────────────────────────────
echo "[1/4] Releasing Elastic IP ($ALLOC_ID)..."
aws ec2 release-address \
  --allocation-id "$ALLOC_ID" \
  --region "$REGION"
echo "    ✓ Elastic IP released"
echo ""

# ── 2. Delete zombie EBS volume ───────────────────────────────────────────────
# The volume was detached by simulate_waste.sh so it is already in 'available'
# state and can be deleted directly without stopping anything first.
echo "[2/4] Deleting zombie EBS volume ($VOLUME_ID)..."
aws ec2 delete-volume \
  --volume-id "$VOLUME_ID" \
  --region "$REGION"
echo "    ✓ EBS volume deleted"
echo ""

# ── 3 & 4. Terminate both EC2 instances ──────────────────────────────────────
# Terminate both in a single call; AWS handles them in parallel.
# The donor instance is already stopped, which is fine — terminate works on
# stopped instances without needing to start them first.
echo "[3/4] Terminating EC2 instances ($IDLE_INSTANCE_ID, $EBS_INSTANCE_ID)..."
aws ec2 terminate-instances \
  --instance-ids "$IDLE_INSTANCE_ID" "$EBS_INSTANCE_ID" \
  --region "$REGION" \
  --query "TerminatingInstances[*].[InstanceId,CurrentState.Name]" \
  --output table

echo "    Waiting for both instances to reach 'terminated' state..."
aws ec2 wait instance-terminated \
  --instance-ids "$IDLE_INSTANCE_ID" "$EBS_INSTANCE_ID" \
  --region "$REGION"
echo "    ✓ Both instances terminated"
echo ""

echo "[4/4] All zombie resources removed."
echo ""
echo "============================================="
echo " Cleanup complete — no billable waste remains"
echo "============================================="
echo ""
echo "Verify with:"
echo "  python scripts/garbage_collect_ebs.py"
echo "  python scripts/garbage_collect_eips.py"
