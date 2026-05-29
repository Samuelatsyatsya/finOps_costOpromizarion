"""
Creates an AWS Budget with an email alert when forecasted spend exceeds a threshold.
Usage:
    python create_budget.py --account-id 123456789012 --email alerts@example.com
    python create_budget.py --account-id 123456789012 --email alerts@example.com --limit 100
"""

# ── Standard library imports ──────────────────────────────────────────────────
import boto3    # AWS SDK — used to call SNS and Budgets APIs
import argparse # Parses CLI flags: --account-id, --email, --limit, --region
import json     # Not used directly here but kept for potential future parameter serialisation

# ── SNS topic creation and email subscription ─────────────────────────────────
# Creates a new SNS topic (or returns the existing one — SNS create_topic is idempotent)
# then subscribes the provided email address to it.
# The subscriber must click the confirmation link AWS sends before any alert is delivered.
def create_sns_topic(sns, topic_name, email):
    # create_topic is idempotent: calling it twice with the same name returns the same ARN
    topic = sns.create_topic(Name=topic_name)
    topic_arn = topic["TopicArn"]

    # Subscribe the email address using the "email" protocol
    # AWS sends a confirmation email; the subscription stays "PendingConfirmation" until confirmed
    sns.subscribe(TopicArn=topic_arn, Protocol="email", Endpoint=email)

    print(f"SNS topic created: {topic_arn}")
    print(f"  → Confirmation email sent to {email} — confirm the subscription before alerts fire.")
    return topic_arn

# ── Budget definition and notification setup ──────────────────────────────────
# Builds the budget object and attaches two notification thresholds, then calls
# the Budgets API to persist everything in a single request.
def create_budget(budgets, account_id, limit_usd, topic_arn, budget_name):

    # ── Budget object ─────────────────────────────────────────────────────────
    # Defines a monthly cost budget in USD.
    # UseBlended=False means unblended (actual) rates are used for cost tracking,
    # which is the standard for most cost allocation use cases.
    budget = {
        "BudgetName": budget_name,
        "BudgetLimit": {"Amount": str(limit_usd), "Unit": "USD"},
        "TimeUnit": "MONTHLY",
        "BudgetType": "COST",
        "CostTypes": {
            "IncludeTax": True,           # Include AWS taxes in the tracked cost
            "IncludeSubscription": True,  # Include AWS Marketplace subscription charges
            "UseBlended": False,          # Use unblended rates (actual per-resource pricing)
        },
    }

    # ── Notification rules ────────────────────────────────────────────────────
    # Two alerts are attached to the budget:
    #   Alert 1 — FORECASTED: fires when AWS predicts end-of-month spend will exceed 100% of limit.
    #             This is an early warning before the limit is actually breached.
    #   Alert 2 — ACTUAL: fires when real spend has already crossed 80% of the limit.
    #             This gives the team time to react before the hard limit is hit.
    notifications = [
        {
            "Notification": {
                "NotificationType": "FORECASTED",       # Based on AWS spend projection
                "ComparisonOperator": "GREATER_THAN",
                "Threshold": 100.0,                     # 100% of the budget limit
                "ThresholdType": "PERCENTAGE",
            },
            "Subscribers": [
                # Deliver the alert to the SNS topic created above
                {"SubscriptionType": "SNS", "Address": topic_arn}
            ],
        },
        {
            "Notification": {
                "NotificationType": "ACTUAL",           # Based on real incurred charges
                "ComparisonOperator": "GREATER_THAN",
                "Threshold": 80.0,                      # 80% of the budget limit
                "ThresholdType": "PERCENTAGE",
            },
            "Subscribers": [
                {"SubscriptionType": "SNS", "Address": topic_arn}
            ],
        },
    ]

    # ── API call ──────────────────────────────────────────────────────────────
    # Submits the budget and both notifications to AWS Budgets in one call
    budgets.create_budget(
        AccountId=account_id,
        Budget=budget,
        NotificationsWithSubscribers=notifications,
    )

    # ── Confirmation output ───────────────────────────────────────────────────
    # Prints a human-readable summary of what was created
    print(f"\nBudget '{budget_name}' created:")
    print(f"  Limit      : ${limit_usd}/month")
    print(f"  Alert 1    : Forecasted spend > 100% of limit (>${limit_usd})")
    print(f"  Alert 2    : Actual spend > 80% of limit (>${limit_usd * 0.8:.0f})")
    print(f"  Notify via : {topic_arn}")

# ── Main entry point ──────────────────────────────────────────────────────────
def main():
    # ── CLI argument parsing ──────────────────────────────────────────────────
    # --account-id  : required; the 12-digit AWS account ID that owns the budget
    # --email       : required; the address that receives SNS alert emails
    # --limit       : optional; monthly spend cap in USD (default $50)
    # --budget-name : optional; logical name shown in the AWS Budgets console
    # --region      : optional; region for the SNS topic (Budgets API is always us-east-1)
    parser = argparse.ArgumentParser()
    parser.add_argument("--account-id", required=True, help="AWS Account ID (12 digits)")
    parser.add_argument("--email", required=True, help="Email address for alerts")
    parser.add_argument("--limit", type=float, default=50.0, help="Monthly budget limit in USD (default: 50)")
    parser.add_argument("--budget-name", default="CostDetective-Monthly-Budget")
    parser.add_argument("--region", default="eu-central-1", help="Region for SNS topic (Budgets is global)")
    args = parser.parse_args()

    # ── AWS client setup ──────────────────────────────────────────────────────
    # SNS is regional — the topic is created in the specified region
    # Budgets is a global service but its API endpoint is always us-east-1
    sns = boto3.client("sns", region_name=args.region)
    budgets = boto3.client("budgets", region_name="us-east-1")

    # ── Orchestration ─────────────────────────────────────────────────────────
    # Step 1: create the SNS topic and subscribe the email address
    # Step 2: create the budget and wire both alert thresholds to that topic
    topic_arn = create_sns_topic(sns, "CostDetective-Budget-Alerts", args.email)
    create_budget(budgets, args.account_id, args.limit, topic_arn, args.budget_name)

# ── Script entry guard ────────────────────────────────────────────────────────
if __name__ == "__main__":
    main()
