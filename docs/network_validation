# VALIDATION CHECKLIST (POST-DEPLOY)

This checklist verifies the baseline's core security properties after running 'terraform apply', with a focus on the following:
- Private AWS access via VPC Endpoints (no NAT/IGW dependency)
- No general internet egress from workloads
- Workload-to-database connectivity
- SOAR/isolation readiness

> Assumptions:
> - You can reach EC2 via SSM Session Manager.
> - Instances are in private subnets.
> - Interface VPC Endpoints are enabled with Private DNS.
> - Worklaod security groups are egress-restricted to endpoint SG + DB SG.

## 0. Identity Targets

From your workstation, capture:
- Compute instance ID(s)
- RDS endpoint + port (if deployed)

**List SSM-managed instances**
```bash
aws ssm describe-instance-information \
  --query "InstanceInformationList[].[InstanceId,PingStatus,PlatformName,AgentVersion]" \
  --output table
```

## 1. Validate SSM connectivity (no SSH required)

**Start a Session Manager session**
```bash
aws ssm start-session --target <INSTANCE_ID>
```
Expected:
- Session starts successfully
- No SSH required