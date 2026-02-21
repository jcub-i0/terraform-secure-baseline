# VALIDATION CHECKLIST (POST-DEPLOY)

## Purpose

This checklist verifies that terraform-secure-baseline has successfully deployed a private-by-default environment after running `terraform apply`.

It focuses on validating:

- Private AWS access via VPC Endpoints (no NAT/IGW dependency)
- Absence of general internet egress from workloads
- Workload-to-database connectivity
- Operational readiness for automated containment workflows (SOAR)

> Assumptions:
> - You can reach EC2 via SSM Session Manager.
> - Instances are in private subnets.
> - Interface VPC Endpoints are enabled with Private DNS.
> - Worklaod security groups are egress-restricted to endpoint SG + DB SG.

## 0. Identity Targets
From your workstation, capture:
- Compute instance ID(s) (<INSTANCE_ID>)
- RDS endpoint + port (if deployed) (<RDS_ENDPOINT_DNS_NAME> and <DB_PORT>)

**List SSM-managed instances:**
```bash
aws ssm describe-instance-information \
  --query "InstanceInformationList[].[InstanceId,PingStatus,PlatformName,AgentVersion]" \
  --output table
```

**List RDS endpoint + port:**
```bash
aws rds describe-db-instances \
  --query "DBInstances[].[DBInstanceIdentifier,Endpoint.Address,Endpoint.Port]" \
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

## 5. Validate Database Connectivity (Compute -> RDS)
**From inside the SSM session:**
```bash
RDS_HOST="<RDS_ENDPOINT_DNS_NAME>"
DB_PORT="<DB_PORT>"
timeout 3 bash -c "cat < /dev/null > /dev/tcp/${RDS_HOST}/${DB_PORT}" \
  && echo "OK  DB reachable" || echo "FAIL DB unreachable"
```
Expected:
- 'OK DB reachable'

## 6. Validate EC2 API Reachability (Recommended for SOAR)
**From inside the SSM session:**
```bash
getent hosts ec2.us-east-1.amazonaws.com
timeout 3 bash -c "cat < /dev/null > /dev/tcp/ec2.us-east-1.amazonaws.com/443" \
  && echo "OK EC2 API reachable" || echo "FAIL EC2 API unreachable"
```
Expected:
- 'OK EC2 API reachable'

## 7. Validate SOAR (EC2 Isolation and EC2 Rollback) -- High-Level
### 7a. Verify EC2 Instance Isolation Lambda executes properly
Refer to the lambda_tests/ec2_isolation.md file and trigger the EC2 Isolation Lambda function.
**Verify the instance SG(s) changed:**
```bash
aws ec2 describe-instances \
  --instance-ids <INSTANCE_ID> \
  --query "Reservations[0].Instances[0].SecurityGroups" \
  --output table
```
Expected:
- EC2 instance belongs to the 'Quarantine' SG
### 7b. Verify EC2 Rollback Lambda executes properly
Refer to the lambda_tests/ec2_rollback.md file and trigger the EC2 Rollback Lambda function via manual event push.
Expected:
- EC2 instance belongs to its original SG (NOT 'Quarantine')

## 8. Quick Failure Triage Guide
### SSM session fails:
- Check interface endpoints exist: ssm, ssmmessages, ec2messages
- Check compute egress to endpoint SG (443)
- Check endpoint SG ingress from compute SG (443)
- Check instance IAM role includes AmazonSSMManagedInstanceCore
### AWS service 443 checks fail:
- Check endpoint Private DNS enabled
- Check endpoint is deployed in the correct subnets / AZs
- Check endpoint SG ingress allows the workload SG
### DB connectivity fails:
- Confirm compute SG egress allows DB port to RDS SG
- Confirm RDS SG ingress allows DB port from compute SG
- Confirm RDS is in the correct subnets and available
### EC2 API check fails:
- Add interface endpoint 'ec2' (common requirement for VPC-only automation)