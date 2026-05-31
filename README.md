# Cost Detective — AWS FinOps Audit

A practical, end-to-end guide to identifying waste, implementing governance, and optimizing costs in an AWS account.

---

## Project Structure

```
finOps_costOpromizarion/
├── scripts/
│   ├── simulate_waste.sh               # Creates zombie resources in a sandbox
│   ├── cleanup_waste.sh                # Tears down all resources from simulate_waste.sh
│   ├── garbage_collect_ebs.py          # Finds & deletes unattached EBS volumes
│   ├── garbage_collect_eips.py         # Finds & releases unassociated Elastic IPs
│   ├── create_budget.py                # Creates AWS Budget + SNS email alert
│   ├── iam/
│   │   ├── cost_detective_policy.json  # Least-privilege IAM policy for the audit
│   │   └── setup_iam_user.sh           # Creates the CostDetective IAM user + CLI profile
│   └── tagging_policy/
│       ├── scp_require_costcenter.json # SCP: blocks EC2 launch without CostCenter tag
│       ├── config_rule_required_tags.json  # AWS Config rule definition (reference)
│       └── deploy_config_rule.py       # Deploys the Config rule via Boto3
└── infrastructure/
    └── asg_mixed_instances.yaml        # CloudFormation: ASG with Mixed Instances Policy
```

---

## Prerequisites

```bash
pip install boto3
aws configure   # or use an IAM role / environment variables
```

Your IAM principal needs:
- `ec2:Describe*`, `ec2:DeleteVolume` — for garbage collection
- `budgets:CreateBudget`, `sns:CreateTopic`, `sns:Subscribe` — for budgets
- `config:PutConfigRule` — for Config rule deployment
- `cloudformation:*`, `autoscaling:*`, `ec2:*`, `iam:*` — for the ASG stack

---

## Part 1 — Analysis & Cleanup: Zombie Asset Detection

### What are Zombie Assets?

| Asset | Zombie Condition | Typical Monthly Cost |
|---|---|---|
| EBS Volume | `status = available` (not attached) | $0.08–$0.10/GB |
| Elastic IP | Not associated with a running instance | $3.65/IP |
| EC2 Instance | Running but 0–5% CPU for 14+ days | Varies |
| Load Balancer | No healthy targets registered | ~$16/month |
| NAT Gateway | Near-zero data processed | ~$32/month |
| RDS Instance | 0 connections for 7+ days | Varies |

### Step 1a — Simulate Waste (Sandbox Only)

```bash
# Create an unattached EBS volume
aws ec2 create-volume --size 20 --volume-type gp3 --availability-zone us-east-1a

# Allocate an Elastic IP without associating it
aws ec2 allocate-address --domain vpc

# Launch an oversized idle instance
aws ec2 run-instances \
  --image-id resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --instance-type m5.xlarge \
  --count 1 \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=idle-waste}]'
```

### Step 1b — Detect with AWS Trusted Advisor

Navigate to: **AWS Console → Trusted Advisor → Cost Optimization**

Key checks to review:
- *Low Utilization Amazon EC2 Instances* — flags instances with <10% CPU over 14 days
- *Unassociated Elastic IP Addresses* — lists all unattached EIPs
- *Underutilized Amazon EBS Volumes* — flags volumes with <1 IOPS/day
- *Idle Load Balancers* — ALBs/NLBs with no traffic

> **Note:** Full Trusted Advisor checks require Business or Enterprise Support. The free tier shows a subset. AWS Cost Explorer (no support plan required) can also surface idle resources under **Rightsizing Recommendations**.

### Step 1c — Detect with AWS Cost Explorer

1. Go to **Cost Explorer → Rightsizing Recommendations**
2. Filter by service: EC2
3. Look for instances flagged as "Terminate" or "Downsize"
4. Export the CSV for your audit report

### Step 1d — Run the EBS Garbage Collector

```bash
# Dry-run first — lists all unattached volumes, deletes nothing
python3 scripts/garbage_collect_ebs.py

# Sample output:
# Found 3 unattached volume(s) — 60 GB total
# VolumeId                  Size   Type       Age          Name
# ---------------------------------------------------------------------------
# vol-0abc123def456789a     20GB   gp3        5d 2h        -
# vol-0def456abc789012b     20GB   gp2        12d 0h       old-backup
# vol-0ghi789def012345c     20GB   gp3        1d 8h        -

# Delete after confirming the list
python3 scripts/garbage_collect_ebs.py --delete
```

### Step 1e — Clean Up Unassociated Elastic IPs

```bash
# Dry-run first — lists all unassociated EIPs, releases nothing
python3 scripts/garbage_collect_eips.py

# Sample output:
# Found 1 unassociated Elastic IP(s) — ~$3.65/month wasted
# AllocationId              PublicIp           Name
# -----------------------------------------------------------------
# eipalloc-0abc123def456    54.123.45.67       -

# Release after confirming the list
python3 scripts/garbage_collect_eips.py --release
```

### Step 1f — Cleanup After the Demo

After screenshots and verification are complete, tear everything down with one script:

```bash
export ALLOC_ID=eipalloc-xxxx
export IDLE_INSTANCE_ID=i-xxxx
export EBS_INSTANCE_ID=i-xxxx
export VOLUME_ID=vol-xxxx
bash scripts/cleanup_waste.sh
```

The script releases the EIP, deletes the zombie volume, and terminates both instances, then waits for full termination before exiting.

---

## Part 2 — Governance

### Step 2a — Create a Budget with Alerts

```bash
python3 scripts/create_budget.py \
  --account-id 123456789012 \
  --email your-team@example.com \
  --limit 50
```

This creates:
- A **$50/month** cost budget
- Alert 1: Forecasted spend will exceed **$50** (100% of limit)
- Alert 2: Actual spend has exceeded **$40** (80% of limit)
- Notifications via SNS → email

> After running, check your inbox and **confirm the SNS subscription** or alerts will not be delivered.

You can also create budgets manually:
**Console → AWS Budgets → Create Budget → Cost Budget**

### Step 2b — Tagging Policy

A tagging policy ensures every resource is attributable to a team/project, which is the foundation of cost allocation.

**Recommended mandatory tags:**

| Tag Key | Example Value | Purpose |
|---|---|---|
| `CostCenter` | `eng-platform` | Cost allocation by team |
| `Environment` | `prod` / `staging` / `dev` | Separate prod vs non-prod costs |
| `Project` | `checkout-service` | Per-project cost tracking |
| `Owner` | `jane.doe@example.com` | Accountability |

#### Option A — Service Control Policy (Preventive)

Attach `scripts/tagging_policy/scp_require_costcenter.json` to your AWS Organization OU.

This **blocks** `ec2:RunInstances` and `ec2:CreateVolume` if the `CostCenter` tag is missing.

```bash
# Create the SCP
aws organizations create-policy \
  --name "RequireCostCenterTag" \
  --type SERVICE_CONTROL_POLICY \
  --description "Blocks EC2 launches without CostCenter tag" \
  --content file://scripts/tagging_policy/scp_require_costcenter.json

# Attach to an OU (replace ou-xxxx-xxxxxxxx with your OU ID)
aws organizations attach-policy \
  --policy-id <policy-id-from-above> \
  --target-id ou-xxxx-xxxxxxxx
```

> SCPs require AWS Organizations. The management account is exempt from SCPs — test in a member account.

#### Option B — AWS Config Rule (Detective)

Flags existing non-compliant resources without blocking them. Good for brownfield environments.

```bash
python3 scripts/tagging_policy/deploy_config_rule.py
```

After ~10 minutes, check: **Console → AWS Config → Rules → require-costcenter-tag-on-ec2**

Non-compliant resources appear in the **Resources in scope** tab. Use this list to remediate existing untagged resources.

#### Using Both Together (Recommended)

- SCP = preventive control (new resources must comply)
- Config rule = detective control (audit existing resources)

---

## Part 3 — Optimization Architecture: Cost-Aware ASG

### Concept: Mixed Instances Policy

Instead of paying full On-Demand price for every instance, the ASG:

1. Keeps a **fixed base** of On-Demand instances (guaranteed capacity)
2. Scales out using **75% Spot + 25% On-Demand** for additional capacity
3. Uses **5 instance type overrides** across families for Spot availability

**Typical savings: 60–80% on the Spot portion vs pure On-Demand.**

### Deploy the Stack

```bash
aws cloudformation deploy \
  --template-file infrastructure/asg_mixed_instances.yaml \
  --stack-name cost-detective-asg \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    VpcId=vpc-xxxxxxxxxxxxxxxxx \
    SubnetIds="subnet-aaa,subnet-bbb,subnet-ccc" \
    OnDemandBaseCapacity=1 \
    MinSize=1 \
    MaxSize=6 \
    DesiredCapacity=2
```

### Verify the Mix

```bash
# Check lifecycle of running instances (On-Demand vs Spot)
aws autoscaling describe-auto-scaling-instances \
  --query "AutoScalingInstances[?AutoScalingGroupName=='cost-detective-asg'].[InstanceId,LifecycleState,InstanceType]" \
  --output table

# The UserData script also writes lifecycle to the web page:
# curl http://<instance-public-ip>
# → "Hello from i-0abc123 (spot)"
```

### Spot Interruption Handling

Spot Instances can be reclaimed with a 2-minute warning. For stateless workloads:

- The ASG automatically replaces interrupted instances
- Use the **price-capacity-optimized** strategy (default in the template) — AWS picks the pool least likely to be interrupted
- For stateful workloads, keep those on the On-Demand base capacity

### Teardown

```bash
aws cloudformation delete-stack --stack-name cost-detective-asg
```

---

## Cost Optimization Checklist

Use this as a recurring monthly checklist:

### Compute
- [ ] Run `garbage_collect_ebs.py` — delete unattached volumes
- [ ] Release unassociated Elastic IPs
- [ ] Review Trusted Advisor: Low Utilization EC2 Instances
- [ ] Review Cost Explorer Rightsizing Recommendations
- [ ] Confirm ASG Spot percentage is healthy (check CloudWatch metrics)
- [ ] Consider Savings Plans or Reserved Instances for stable baseline workloads

### Storage
- [ ] Move infrequently accessed S3 objects to S3-IA or Glacier (use S3 Lifecycle rules)
- [ ] Delete old EBS snapshots (>90 days, no associated AMI)
- [ ] Enable S3 Intelligent-Tiering for unpredictable access patterns

### Networking
- [ ] Audit NAT Gateways — are all AZs actually needed?
- [ ] Check for idle Load Balancers (no healthy targets)
- [ ] Review data transfer costs in Cost Explorer (filter by Usage Type: DataTransfer)

### Governance
- [ ] Verify Config rule compliance — remediate untagged resources
- [ ] Check Budget alerts fired this month — investigate spikes
- [ ] Review IAM permissions — remove unused roles/users (reduces blast radius)

---

## Key AWS Services Reference

| Service | Purpose | Console Path |
|---|---|---|
| AWS Cost Explorer | Visualize spend, rightsizing | Billing → Cost Explorer |
| AWS Budgets | Alerts on spend thresholds | Billing → Budgets |
| AWS Trusted Advisor | Best practice checks | Support → Trusted Advisor |
| AWS Config | Resource compliance rules | Config → Rules |
| AWS Organizations / SCPs | Preventive governance | Organizations → Policies |
| EC2 Auto Scaling | Mixed Instances / Spot | EC2 → Auto Scaling Groups |
| AWS Compute Optimizer | ML-based rightsizing | Compute Optimizer |

---

## Estimated Savings from This Audit

| Action | Typical Monthly Saving |
|---|---|
| Delete 3 × 20 GB unattached EBS volumes | ~$5 |
| Release 2 unassociated Elastic IPs | ~$7 |
| Downsize 1 idle m5.xlarge → t3.small | ~$100+ |
| 75% Spot on scale-out capacity (4 instances) | ~$60–80 |
| **Total (example scenario)** | **~$170–200/month** |

Actual savings depend on your workload profile and region.
