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
#   If deletion fails due to a resource permission error, the script retries
#   with --retain-resources for the blocked resource, then cleans it up manually.
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

# ── Helper: get current stack status ─────────────────────────────────────────
stack_status() {
  aws cloudformation describe-stacks \
    --stack-name "$1" \
    --region "$REGION" \
    --profile "$PROFILE" \
    --query "Stacks[0].StackStatus" \
    --output text 2>/dev/null || echo "DOES_NOT_EXIST"
}

# ── Helper: delete a stack, with automatic retry on DELETE_FAILED ─────────────
# On DELETE_FAILED, CloudFormation leaves the stack in a stuck state.
# We recover by:
#   1. Finding which logical resource IDs failed to delete
#   2. Retrying delete with --retain-resources for those IDs (skips them)
#   3. Manually cleaning up the retained orphan resources afterwards
delete_stack() {
  local stack_name="$1"
  local status
  status=$(stack_status "$stack_name")

  if [[ "$status" == "DOES_NOT_EXIST" ]]; then
    echo "  ✓ $stack_name does not exist — nothing to delete"
    return
  fi

  echo "  Deleting $stack_name (current status: $status)..."
  aws cloudformation delete-stack \
    --stack-name "$stack_name" \
    --region "$REGION" \
    --profile "$PROFILE"

  # Wait, but don't exit on failure — we handle DELETE_FAILED below
  aws cloudformation wait stack-delete-complete \
    --stack-name "$stack_name" \
    --region "$REGION" \
    --profile "$PROFILE" 2>/dev/null || true

  status=$(stack_status "$stack_name")

  # ── Retry on DELETE_FAILED ────────────────────────────────────────────────
  if [[ "$status" == "DELETE_FAILED" ]]; then
    echo "  ⚠ DELETE_FAILED — finding blocked resources..."

    # Collect the logical IDs of every resource that failed to delete
    FAILED_RESOURCES=$(aws cloudformation describe-stack-events \
      --stack-name "$stack_name" \
      --region "$REGION" \
      --profile "$PROFILE" \
      --query "StackEvents[?ResourceStatus=='DELETE_FAILED'].LogicalResourceId" \
      --output text | tr '\t' ' ')

    echo "  Blocked resources: $FAILED_RESOURCES"
    echo "  Retrying with --retain-resources for these resources..."

    # Build the --retain-resources argument (space-separated list of logical IDs)
    # shellcheck disable=SC2086
    aws cloudformation delete-stack \
      --stack-name "$stack_name" \
      --retain-resources $FAILED_RESOURCES \
      --region "$REGION" \
      --profile "$PROFILE"

    aws cloudformation wait stack-delete-complete \
      --stack-name "$stack_name" \
      --region "$REGION" \
      --profile "$PROFILE"

    echo "  ✓ $stack_name deleted (retained: $FAILED_RESOURCES)"

    # ── Clean up retained (orphaned) resources ────────────────────────────
    # The resources listed in FAILED_RESOURCES are no longer tracked by any
    # stack and must be cleaned up manually.
    echo "  Cleaning up retained resources..."
    cleanup_retained "$stack_name" "$FAILED_RESOURCES"
  else
    echo "  ✓ $stack_name deleted"
  fi
}

# ── Helper: clean up resources orphaned by --retain-resources ─────────────────
# Inspects the physical resource IDs of the retained logical resources and
# deletes them using the appropriate AWS CLI command.
cleanup_retained() {
  local stack_name="$1"
  local logical_ids="$2"

  for logical_id in $logical_ids; do
    # Fetch the physical resource ID and type for this logical resource
    read -r physical_id resource_type < <(
      aws cloudformation describe-stack-resource \
        --stack-name "$stack_name" \
        --logical-resource-id "$logical_id" \
        --region "$REGION" \
        --profile "$PROFILE" \
        --query "StackResourceDetail.[PhysicalResourceId,ResourceType]" \
        --output text 2>/dev/null || echo "UNKNOWN UNKNOWN"
    )

    echo "    Cleaning up $logical_id ($resource_type: $physical_id)..."

    case "$resource_type" in
      AWS::EC2::LaunchTemplate)
        aws ec2 delete-launch-template \
          --launch-template-id "$physical_id" \
          --region "$REGION" \
          --profile "$PROFILE" && echo "    ✓ Launch template deleted"
        ;;
      AWS::EC2::SecurityGroup)
        aws ec2 delete-security-group \
          --group-id "$physical_id" \
          --region "$REGION" \
          --profile "$PROFILE" && echo "    ✓ Security group deleted"
        ;;
      AWS::IAM::Role)
        aws iam delete-role \
          --role-name "$physical_id" && echo "    ✓ IAM role deleted"
        ;;
      AWS::IAM::InstanceProfile)
        aws iam delete-instance-profile \
          --instance-profile-name "$physical_id" && echo "    ✓ Instance profile deleted"
        ;;
      *)
        echo "    ⚠ Unknown resource type $resource_type — delete manually: $physical_id"
        ;;
    esac
  done
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
