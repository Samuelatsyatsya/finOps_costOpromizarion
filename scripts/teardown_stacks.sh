#!/bin/bash
# =============================================================================
# teardown_stacks.sh
# Deletes the two CloudFormation stacks in the correct order:
#   1. ASG stack first — it holds an Fn::ImportValue dependency on the VPC stack.
#      CloudFormation blocks deletion of a stack while another stack still imports
#      one of its Exports. The ASG stack must be gone before the VPC stack can be deleted.
#   2. VPC stack second — safe to delete once no stack imports its Exports.
#
# Idempotency:
#   If a stack does not exist, the script skips it and continues.
#   Re-running after a partial teardown will cleanly finish the job.
#
# Usage: bash scripts/teardown_stacks.sh
# =============================================================================

set -euo pipefail

REGION="eu-central-1"
PROFILE="${AWS_PROFILE:-cost-detective}"

ASG_STACK="cost-detective-asg"
VPC_STACK="cost-detective-vpc"

echo "============================================="
echo " Cost Detective — CloudFormation Teardown"
echo " Region  : $REGION"
echo " Profile : $PROFILE"
echo "============================================="
echo ""

# ── Helper: delete a stack only if it exists ─────────────────────────────────
delete_stack() {
  local stack_name="$1"

  # Check if the stack exists — describe-stacks exits non-zero if it does not
  if ! aws cloudformation describe-stacks \
       --stack-name "$stack_name" \
       --region "$REGION" \
       --profile "$PROFILE" \
       --query "Stacks[0].StackStatus" \
       --output text &>/dev/null; then
    echo "  ✓ $stack_name does not exist — nothing to delete"
    return
  fi

  echo "  Deleting $stack_name..."
  aws cloudformation delete-stack \
    --stack-name "$stack_name" \
    --region "$REGION" \
    --profile "$PROFILE"

  echo "  Waiting for $stack_name to be fully deleted..."
  aws cloudformation wait stack-delete-complete \
    --stack-name "$stack_name" \
    --region "$REGION" \
    --profile "$PROFILE"

  echo "  ✓ $stack_name deleted"
}

# ── Order matters: ASG before VPC ────────────────────────────────────────────
echo "[1/2] Removing ASG stack ($ASG_STACK)..."
delete_stack "$ASG_STACK"
echo ""

echo "[2/2] Removing VPC stack ($VPC_STACK)..."
delete_stack "$VPC_STACK"
echo ""

echo "============================================="
echo " Teardown complete — all stacks removed"
echo "============================================="
