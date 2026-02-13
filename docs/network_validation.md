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

**Start a Session Manager session:**
```bash
aws ssm start-session --target <INSTANCE_ID>
```
Expected:
- Session starts successfully
- No SSH required

## 2. Validate Interface Endpoint DNS Resolution (Private DNS)

**From inside the SSM session:**
```bash
getent hosts sts.us-east-1.amazonaws.com
getent hosts ssm.us-east-1.amazonaws.com
getent hosts secretsmanager.us-east-1.amazonaws.com
getent hosts logs.us-east-1.amazonaws.com
getent hosts kms.us-east-1.amazonaws.com
```
Expected:
- Commands return private RFC1918 IPs (i.e. 10.x.x.x) for each service

## 3. Validate 443 Connectivity to AWS Services via Endpoints

**From inside the SSM session:**
```bash
for h in sts ssm secretsmanager logs kms; do
  host="${h}.us-east-1.amazonaws.com"
  timeout 3 bash -c "cat < /dev/null > /dev/tcp/${host}/443" \
    && echo "OK  ${host}:443" || echo "FAIL ${host}:443"
done
```
Expected:
- All should return 'OK'

## 4. Validate No General Internet Egress

**From inside the SSM session:**
```bash
timeout 3 bash -c "cat < /dev/null > /dev/tcp/example.com/443" \
  && echo "UNEXPECTED: internet works" || echo "GOOD: no internet egress"
```
Expected:
- 'GOOD: no internet egress'
