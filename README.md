# AWS Landing Zone

A production-grade AWS Landing Zone implemented with CloudFormation, following AWS Security Best Practices and the CIS AWS Foundations Benchmark. Designed for multi-account AWS Organizations with centralized networking, identity management, and security monitoring.

---

## Architecture Overview

```
                          ┌─────────────────────────────────────────────────┐
                          │              Management Account                  │
                          │  ┌──────────────┐   ┌──────────────────────┐   │
                          │  │ IAM Identity │   │   AWS Organizations  │   │
                          │  │   Center     │   │    (SCPs / OUs)      │   │
                          │  └──────┬───────┘   └──────────────────────┘   │
                          └─────────│───────────────────────────────────────┘
                                    │ SSO
                    ┌───────────────┼─────────────────────┐
                    │               │                     │
           ┌────────▼──────┐ ┌──────▼────────┐  ┌────────▼──────────┐
           │ Log Archive   │ │  Security     │  │   Networking      │
           │   Account     │ │  Tooling      │  │     Account       │
           │               │ │   Account     │  │                   │
           │  S3 (Config,  │ │ GuardDuty     │  │  Hub VPC          │
           │  CloudTrail)  │ │ SecurityHub   │  │  Transit Gateway  │
           └───────────────┘ └───────────────┘  └────────┬──────────┘
                                                          │ TGW Attachments
                                                ┌─────────┴──────────┐
                                                │                    │
                                         ┌──────▼──────┐   ┌────────▼──────┐
                                         │  Workload   │   │   Workload    │
                                         │  Account A  │   │   Account B   │
                                         │  (Dev/Test) │   │  (Production) │
                                         └─────────────┘   └───────────────┘
```

---

## Stack Summary

| Stack | Template | Description |
|-------|----------|-------------|
| `vpc-networking` | `templates/vpc-networking.yaml` | Hub VPC, public/private subnets, NAT Gateways, Transit Gateway, VPC Flow Logs |
| `iam-sso` | `templates/iam-sso.yaml` | IAM Identity Center permission sets, account assignments, break-glass role |
| `security-baseline` | `templates/security-baseline.yaml` | GuardDuty, Security Hub (CIS + AFSBP), AWS Config with 12 CIS-aligned rules, CloudWatch alarms, KMS encryption, SNS alerting |

---

## Features

### 🌐 VPC & Networking (`vpc-networking.yaml`)
- **Hub-and-spoke topology** via AWS Transit Gateway
- **Multi-AZ** public and private subnets across 2 Availability Zones
- **NAT Gateways** per AZ for high-availability egress
- **VPC Flow Logs** to CloudWatch Logs (90-day retention)
- TGW route for RFC-1918 `10.0.0.0/8` summary towards spoke accounts
- Stack **exports** for cross-stack VPC and TGW ID references
- `AutoAcceptSharedAttachments: disable` for explicit spoke approval

### 🔐 IAM & SSO (`iam-sso.yaml`)
- **5 purpose-built permission sets**: AdministratorAccess, ReadOnlyAccess, SecurityAudit, NetworkAdministrator, BillingReadOnly
- Scoped **inline policies** for SecurityAudit and NetworkAdmin sets
- Short session durations (4h for admin, 8h for read-only) to minimize blast radius
- **SSM Parameter Store** integration for dynamic Group ID resolution
- **Break-glass IAM role** with MFA condition for emergency access

### 🔒 Security Baseline (`security-baseline.yaml`)
- **Amazon GuardDuty** with S3, EKS audit log, and malware protection enabled
- **AWS Security Hub** with CIS AWS Foundations Benchmark v1.4 and AWS Foundational Security Best Practices
- **AWS Config** with full resource recording and 12 CIS-aligned managed rules
- **KMS encryption** with automatic key rotation for all security service data
- **SNS alerting** for HIGH/CRITICAL GuardDuty findings and Security Hub findings
- **CloudWatch alarms** for CIS 3.1–3.3 (unauthorized API calls, console login without MFA, root usage)

#### Config Rules Enforced
| Rule | CIS Control | Description |
|------|-------------|-------------|
| `root-mfa-enabled` | 1.1 | Root account MFA |
| `access-key-rotation` | 1.4 | Keys rotated ≤ 90 days |
| `restricted-ssh` | 4.1 | No unrestricted port 22 |
| `restricted-rdp` | 4.2 | No unrestricted port 3389 |
| `cloudtrail-enabled` | 2.1 | Multi-region CloudTrail |
| `ebs-encryption-enabled` | – | EBS encrypted by default |
| `s3-bucket-encryption` | – | S3 SSE enabled |
| `s3-block-public-access` | – | S3 public access blocked |
| `vpc-flow-logs-enabled` | 2.9 | Flow logs on all VPCs |
| `imdsv2-required` | – | IMDSv2 enforced on EC2 |
| `rds-no-public-access` | – | RDS not publicly accessible |
| `iam-password-policy` | 1.8–1.11 | Strong password policy |

---

## Prerequisites

- **AWS CLI v2** — [Install guide](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
- **jq** — `brew install jq` (macOS) / `apt install jq` (Linux)
- **IAM Identity Center** enabled in the management account
- **AWS Config** service-linked role (auto-created on first deploy)
- Credentials configured for the target account (`aws configure` or environment variables)

---

## Deployment

### 1. Clone & Configure

```bash
git clone https://github.com/YOUR_USERNAME/aws-landing-zone.git
cd aws-landing-zone
```

Edit the parameter files in `parameters/` to match your environment. At minimum, replace all `REPLACE_ME` placeholders:

```bash
# Find all values that need to be replaced
grep -r "REPLACE" parameters/
```

### 2. Set Environment Variables

```bash
export AWS_REGION=us-east-1        # Your target region
export AWS_PROFILE=my-mgmt-account # Your AWS CLI profile
export ENV_NAME=landing-zone       # Stack name prefix
```

### 3. Deploy All Stacks

```bash
chmod +x scripts/deploy.sh
./scripts/deploy.sh deploy
```

Stacks are deployed in dependency order automatically.

### 4. Post-Deployment Steps

**Share the Transit Gateway** with spoke accounts via AWS Resource Access Manager (RAM):
```bash
aws ram create-resource-share \
  --name landing-zone-tgw-share \
  --resource-arns <TransitGatewayArn> \
  --principals <SpokeAccountId>
```

**Update SSO Group IDs** — retrieve your group IDs and update SSM:
```bash
# List groups in your Identity Store
aws identitystore list-groups \
  --identity-store-id d-XXXXXXXXXX

# Update SSM parameter with actual group ID
aws ssm put-parameter \
  --name /landing-zone/sso/group-id/platform-admins \
  --value <GroupId> \
  --overwrite
```

**Subscribe to security alerts**:
```bash
aws sns subscribe \
  --topic-arn <SecurityAlertsTopicArn> \
  --protocol email \
  --notification-endpoint your-security-team@company.com
```

### 5. Destroy (if needed)

```bash
./scripts/deploy.sh destroy
```

---

## Project Structure

```
aws-landing-zone/
├── templates/
│   ├── vpc-networking.yaml      # Hub VPC + Transit Gateway
│   ├── iam-sso.yaml             # IAM Identity Center + permission sets
│   └── security-baseline.yaml  # GuardDuty + SecurityHub + Config
├── parameters/
│   ├── vpc-networking.json      # Parameter overrides for VPC stack
│   ├── iam-sso.json             # Parameter overrides for SSO stack
│   └── security-baseline.json  # Parameter overrides for security stack
├── scripts/
│   └── deploy.sh                # Orchestration deploy/destroy script
├── docs/
└── README.md
```

---

## Security Considerations

- **Least privilege**: All IAM roles and permission sets follow least-privilege principles with scoped actions.
- **Encryption at rest**: KMS CMK with automatic rotation encrypts all security service data.
- **Short-lived credentials**: SSO session durations are capped at 4h for admin roles.
- **MFA enforcement**: Break-glass role requires MFA via IAM condition key.
- **No public access**: `AutoAcceptSharedAttachments` is disabled on the TGW; `MapPublicIpOnLaunch` is false on all subnets.
- **Audit trail**: VPC Flow Logs with 90-day retention; Config recording all resource changes.

---

## Extending the Landing Zone

| Extension | How |
|-----------|-----|
| Add a spoke VPC | Create a new VPC stack, reference `TransitGatewayId` export, create a `AWS::EC2::TransitGatewayAttachment` |
| Add a new permission set | Add `AWS::SSO::PermissionSet` and `AWS::SSO::Assignment` to `iam-sso.yaml` |
| Add a Config rule | Add `AWS::Config::ConfigRule` to `security-baseline.yaml` |
| Enable AWS Macie | Add `AWS::Macie::Session` to `security-baseline.yaml` |
| Deploy to multiple regions | Run the deploy script with different `AWS_REGION` values |

---

## References

- [AWS Landing Zone Solution](https://aws.amazon.com/solutions/implementations/aws-landing-zone/)
- [AWS Control Tower](https://docs.aws.amazon.com/controltower/latest/userguide/what-is-control-tower.html)
- [CIS AWS Foundations Benchmark](https://www.cisecurity.org/benchmark/amazon_web_services)
- [AWS Security Hub Standards](https://docs.aws.amazon.com/securityhub/latest/userguide/standards-reference.html)
- [Transit Gateway Best Practices](https://docs.aws.amazon.com/vpc/latest/tgw/tgw-best-design-practices.html)

---

## License

MIT License — feel free to use, fork, and adapt for your own projects.
