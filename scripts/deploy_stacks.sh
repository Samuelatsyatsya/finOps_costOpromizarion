#!/bin/bash
# =============================================================================
# deploy_stacks.sh
# Deploys the two CloudFormation stacks that make up Part 3 of the audit:
#   1. infrastructure/vpc.yaml       — VPC, subnets, IGW, route tables
#   2. infrastructure/asg_mixed_instances.yaml — Mixed Instances ASG
#
# Idempotency:
#   aws cloudformation deploy is idempotent by design:
#     - Stack does not exist → creates it
#     - Stack exists, template changed → updates it
#     - Stack exists, nothing changed → skips silently (--no-fail-on-empty-changeset)
#   Re-running this script at any point is always safe.
#
# Usage: bash scripts/deploy_stacks.sh
# =============================================================================

set -euo pipefail

REGION="eu-central-1"
PROFILE="${AWS_PROFILE:-cost-detective}"
TEMPLATE_DIR="$(dirname "$0")/../infrastructure"

# Stack names — changing these lets you run multiple isolated environments
VPC_STACK="cost-detective-vpc"
ASG_STACK="cost-detective-asg"

# EnvironmentName drives the CloudFormation Export names that link the two stacks.
# It must be the same value passed to both vpc.yaml and asg_mixed_instances.yaml.
ENV_NAME="cost-detective"

echo "============================================="
echo " Cost Detective — CloudFormation Deploy"
echo " Region  : $REGION"
echo " Profile : $PROFILE"
echo " Env     : $ENV_NAME"
echo "============================================="
echo ""

# ── Helper: print a stack's Outputs as a tidy table ──────────────────────────
print_outputs() {
  local stack_name="$1"
  aws cloudformation describe-stacks \
    --stack-name "$stack_name" \
    --region "$REGION" \
    --profile "$PROFILE" \
    --query "Stacks[0].Outputs[*].[OutputKey,OutputValue]" \
    --output table 2>/dev/null || true
}

# ── Step 1: VPC stack ─────────────────────────────────────────────────────────
# Must be deployed before the ASG stack because it exports VpcId and SubnetIds.
# The ASG template reads those exports via Fn::ImportValue — if the exports do
# not exist yet, the ASG deploy will fail with "Export not found".
echo "[1/2] Deploying VPC stack ($VPC_STACK)..."
aws cloudformation deploy \
  --template-file "$TEMPLATE_DIR/vpc.yaml" \
  --stack-name "$VPC_STACK" \
  --region "$REGION" \
  --profile "$PROFILE" \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    EnvironmentName="$ENV_NAME"

echo ""
echo "  VPC stack outputs:"
print_outputs "$VPC_STACK"
echo ""

# ── Step 2: ASG stack ─────────────────────────────────────────────────────────
# Reads VpcId and SubnetIds from the VPC stack exports automatically via
# Fn::ImportValue — no need to pass them as parameters here.
# CAPABILITY_IAM is required because the template creates an IAM Role and
# Instance Profile for the EC2 instances (SSM access).
echo "[2/2] Deploying ASG stack ($ASG_STACK)..."
aws cloudformation deploy \
  --template-file "$TEMPLATE_DIR/asg_mixed_instances.yaml" \
  --stack-name "$ASG_STACK" \
  --region "$REGION" \
  --profile "$PROFILE" \
  --capabilities CAPABILITY_IAM \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    EnvironmentName="$ENV_NAME"

echo ""
echo "  ASG stack outputs:"
print_outputs "$ASG_STACK"
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo "============================================="
echo " Deployment complete!"
echo ""
echo " Verify On-Demand vs Spot mix:"
echo "   aws autoscaling describe-auto-scaling-instances \\"
echo "     --profile $PROFILE --region $REGION \\"
echo "     --query \"AutoScalingInstances[?AutoScalingGroupName=='cost-detective-asg']"
echo "              .[InstanceId,InstanceType,LifecycleState]\" \\"
echo "     --output table"
echo ""
echo " Teardown:"
echo "   bash scripts/teardown_stacks.sh"
echo "============================================="
