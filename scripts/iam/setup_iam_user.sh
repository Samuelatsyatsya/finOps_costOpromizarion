#!/bin/bash
# =============================================================================
# setup_iam_user.sh
# Creates a CostDetective IAM user in the DCE account, attaches a least-privilege
# policy covering all audit actions, generates access keys, and configures a
# named AWS CLI profile called "cost-detective" ready to use.
#
# Run this script using credentials that have IAM permissions in the DCE account.
# Usage: bash scripts/iam/setup_iam_user.sh
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
IAM_USER="CostDetective"
POLICY_NAME="CostDetectivePolicy"
PROFILE_NAME="cost-detective"
REGION="us-east-1"
POLICY_FILE="$(dirname "$0")/cost_detective_policy.json"

echo "============================================="
echo " Cost Detective — IAM User Setup"
echo "============================================="
echo ""

# ── Step 1: Create the IAM user ───────────────────────────────────────────────
echo "[1/5] Creating IAM user: $IAM_USER ..."
aws iam create-user --user-name "$IAM_USER" \
  --tags Key=Purpose,Value=cost-detective-audit \
  --output table
echo "    ✓ User created"
echo ""

# ── Step 2: Create the IAM policy from the JSON file ─────────────────────────
echo "[2/5] Creating IAM policy: $POLICY_NAME ..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

aws iam create-policy \
  --policy-name "$POLICY_NAME" \
  --policy-document "file://${POLICY_FILE}" \
  --description "Least-privilege policy for the Cost Detective FinOps audit" \
  --output table
echo "    ✓ Policy created: $POLICY_ARN"
echo ""

# ── Step 3: Attach the policy to the user ────────────────────────────────────
echo "[3/5] Attaching policy to user ..."
aws iam attach-user-policy \
  --user-name "$IAM_USER" \
  --policy-arn "$POLICY_ARN"
echo "    ✓ Policy attached"
echo ""

# ── Step 4: Generate access keys ─────────────────────────────────────────────
# The keys are written to a local file AND printed to the terminal.
# Store them securely — they cannot be retrieved again after this point.
echo "[4/5] Generating access keys ..."
KEYS=$(aws iam create-access-key --user-name "$IAM_USER" --output json)
ACCESS_KEY=$(echo "$KEYS" | python3 -c "import json,sys; k=json.load(sys.stdin)['AccessKey']; print(k['AccessKeyId'])")
SECRET_KEY=$(echo "$KEYS" | python3 -c "import json,sys; k=json.load(sys.stdin)['AccessKey']; print(k['SecretAccessKey'])")

# Save keys to a local file for reference (do not commit this file to git)
KEYS_FILE="$(dirname "$0")/cost_detective_keys.txt"
cat > "$KEYS_FILE" <<EOF
# CostDetective IAM user credentials
# Generated: $(date -u)
# Account:   $ACCOUNT_ID
# WARNING: Do not commit this file to version control
AWS_ACCESS_KEY_ID=$ACCESS_KEY
AWS_SECRET_ACCESS_KEY=$SECRET_KEY
EOF
chmod 600 "$KEYS_FILE"   # Restrict file to owner only
echo "    ✓ Keys saved to: $KEYS_FILE (chmod 600)"
echo ""

# ── Step 5: Configure the named AWS CLI profile ───────────────────────────────
# Creates a profile called "cost-detective" in ~/.aws/credentials and ~/.aws/config
# All project scripts can then be run with --profile cost-detective or
# by setting AWS_PROFILE=cost-detective in the shell.
echo "[5/5] Configuring AWS CLI profile: $PROFILE_NAME ..."
aws configure set aws_access_key_id "$ACCESS_KEY" --profile "$PROFILE_NAME"
aws configure set aws_secret_access_key "$SECRET_KEY" --profile "$PROFILE_NAME"
aws configure set region "$REGION" --profile "$PROFILE_NAME"
aws configure set output "json" --profile "$PROFILE_NAME"
echo "    ✓ Profile configured: ~/.aws/credentials [$PROFILE_NAME]"
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo "============================================="
echo " Setup complete!"
echo "   IAM User   : $IAM_USER"
echo "   Policy      : $POLICY_ARN"
echo "   CLI Profile : $PROFILE_NAME"
echo "   Region      : $REGION"
echo "============================================="
echo ""
echo "Verify the profile works:"
echo "  aws sts get-caller-identity --profile $PROFILE_NAME"
echo ""
echo "Use the profile for all audit scripts:"
echo "  export AWS_PROFILE=$PROFILE_NAME"
echo "  bash scripts/simulate_waste.sh"
echo ""
echo "Or pass it per-command:"
echo "  python scripts/garbage_collect_ebs.py --profile $PROFILE_NAME"
