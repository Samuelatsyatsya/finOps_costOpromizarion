#!/bin/bash
# =============================================================================
# simulate_waste.sh
# Creates "zombie" resources in the DCE sandbox to simulate a reckless account.
#
# DCE accounts block ec2:CreateVolume via SCP, so EBS waste is simulated by:
#   1. Launching an instance (which creates a root EBS volume automatically)
#   2. Stopping the instance
#   3. Detaching the root volume — leaving it in 'available' (unattached) state
#
# Resources created:
#   - 1 x unassociated Elastic IP
#   - 1 x oversized idle EC2 instance (m5.xlarge)
#   - 1 x detached EBS volume (root volume of a stopped t2.micro)
#
# Usage: bash scripts/simulate_waste.sh
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
REGION="us-east-1"
AZ="us-east-1a"
export AWS_PROFILE="${AWS_PROFILE:-cost-detective}"

echo "============================================="
echo " Cost Detective — Waste Simulation"
echo " Region : $REGION"
echo " Profile: $AWS_PROFILE"
echo "============================================="
echo ""

# ── 1. Unassociated Elastic IP ────────────────────────────────────────────────
# Allocates an EIP but does NOT associate it with any instance.
# AWS charges ~$0.005/hr (~$3.65/month) for every unassociated EIP.
echo "[1/4] Allocating unassociated Elastic IP..."
ALLOC_ID=$(aws ec2 allocate-address \
  --domain vpc \
  --region "$REGION" \
  --query "AllocationId" \
  --output text)
PUBLIC_IP=$(aws ec2 describe-addresses \
  --allocation-ids "$ALLOC_ID" \
  --region "$REGION" \
  --query "Addresses[0].PublicIp" \
  --output text)
echo "    ✓ Allocated EIP: $PUBLIC_IP (AllocationId: $ALLOC_ID)"
echo ""

# ── 2. Oversized Idle EC2 Instance ───────────────────────────────────────────
# Launches an m5.xlarge that will sit idle at ~0% CPU — the classic zombie instance.
echo "[2/4] Launching oversized idle EC2 instance (m5.xlarge)..."
IDLE_INSTANCE_ID=$(aws ec2 run-instances \
  --image-id resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --instance-type m5.xlarge \
  --count 1 \
  --region "$REGION" \
  --tag-specifications \
    'ResourceType=instance,Tags=[{Key=Name,Value=idle-waste},{Key=Purpose,Value=cost-detective-demo}]' \
  --query "Instances[0].InstanceId" \
  --output text)
echo "    ✓ Launched instance: $IDLE_INSTANCE_ID (m5.xlarge — idle, no workload)"
echo ""

# ── 3. Launch a small instance to generate a detachable EBS volume ────────────
# DCE SCPs block ec2:CreateVolume directly, so we launch a t2.micro,
# stop it, then detach its root volume to leave it in 'available' state.
echo "[3/4] Launching t2.micro to generate a detachable EBS root volume..."
EBS_INSTANCE_ID=$(aws ec2 run-instances \
  --image-id resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --instance-type t2.micro \
  --count 1 \
  --region "$REGION" \
  --tag-specifications \
    'ResourceType=instance,Tags=[{Key=Name,Value=ebs-donor},{Key=Purpose,Value=cost-detective-demo}]' \
  --query "Instances[0].InstanceId" \
  --output text)
echo "    ✓ Launched donor instance: $EBS_INSTANCE_ID"

# Wait for the instance to reach 'running' state before stopping it
echo "    Waiting for instance to reach 'running' state..."
aws ec2 wait instance-running \
  --instance-ids "$EBS_INSTANCE_ID" \
  --region "$REGION"
echo "    ✓ Instance is running"

# Stop the instance so the root volume can be detached
echo "    Stopping instance..."
aws ec2 stop-instances \
  --instance-ids "$EBS_INSTANCE_ID" \
  --region "$REGION" > /dev/null
aws ec2 wait instance-stopped \
  --instance-ids "$EBS_INSTANCE_ID" \
  --region "$REGION"
echo "    ✓ Instance stopped"

# Get the root volume ID attached to this instance
VOLUME_ID=$(aws ec2 describe-instances \
  --instance-ids "$EBS_INSTANCE_ID" \
  --region "$REGION" \
  --query "Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId" \
  --output text)

# Detach the root volume — it will enter 'available' state (unattached zombie)
echo "    Detaching root volume $VOLUME_ID..."
aws ec2 detach-volume \
  --volume-id "$VOLUME_ID" \
  --region "$REGION" > /dev/null
aws ec2 wait volume-available \
  --volume-ids "$VOLUME_ID" \
  --region "$REGION"
echo "    ✓ Volume detached: $VOLUME_ID (status: available — zombie EBS)"
echo ""

# ── 4. Summary ────────────────────────────────────────────────────────────────
echo "[4/4] All waste resources created."
echo ""
echo "============================================="
echo " Zombie resources ready for the audit:"
echo "   Elastic IP    : $PUBLIC_IP ($ALLOC_ID)"
echo "   Idle Instance : $IDLE_INSTANCE_ID (m5.xlarge)"
echo "   Zombie Volume : $VOLUME_ID (detached, available)"
echo "   Donor Instance: $EBS_INSTANCE_ID (stopped — can terminate)"
echo "============================================="
echo ""
echo "Next steps:"
echo "  1. Screenshot EC2 > Volumes, EC2 > Elastic IPs, EC2 > Instances in the console"
echo "  2. python scripts/garbage_collect_ebs.py                  (dry-run)"
echo "  3. python scripts/garbage_collect_ebs.py --delete         (delete zombie volume)"
echo "  4. aws ec2 release-address --allocation-id $ALLOC_ID --region $REGION"
echo "  5. aws ec2 terminate-instances --instance-ids $IDLE_INSTANCE_ID $EBS_INSTANCE_ID --region $REGION"
