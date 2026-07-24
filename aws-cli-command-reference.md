# AWS CLI Command Reference — GitOps Microservices Project

**Project:** Production-Grade GitOps-Driven Microservices on EKS
**Cluster:** `boutique-app-eks` · **Region:** `us-east-1` · **Account:** `514005485562`
**Domain:** `shalin.online`

> **How to use this doc:** every command here is runnable as-is — no placeholders to fill in
> except where explicitly marked `<...>`. Keep appending as the project grows.
> Sections are ordered by the phase you'll need them in.

**Last updated:** Phase 1 rebuild — backend recreated, cluster pending

---

## Table of Contents

1. [Identity & Sanity Checks](#1-identity--sanity-checks)
2. [Terraform Backend (S3 + Locking)](#2-terraform-backend-s3--locking)
3. [EKS Cluster](#3-eks-cluster)
4. [EKS Add-ons](#4-eks-add-ons)
5. [VPC & Subnets](#5-vpc--subnets)
6. [IAM — Policies, Roles, OIDC](#6-iam--policies-roles-oidc)
7. [EKS Pod Identity](#7-eks-pod-identity)
8. [Load Balancers](#8-load-balancers)
9. [Route 53 & ACM](#9-route-53--acm)
10. [Cost & Orphan Audit](#10-cost--orphan-audit)
11. [Teardown Order](#11-teardown-order)
12. [Output Formatting Cheatsheet](#12-output-formatting-cheatsheet)

---

## 1. Identity & Sanity Checks

**Always run this first.** Confirms which IAM identity your CLI is using. The #1 cause of
mystery `AccessDenied` errors is being authenticated as the wrong user or profile.

```bash
aws sts get-caller-identity
```

Returns your Account ID, User ID, and ARN.

---

Show the region and credentials your CLI defaults to.

```bash
aws configure list
```

---

List every configured named profile.

```bash
aws configure list-profiles
```

> **Tip:** append `--profile <name>` to any command, or export `AWS_PROFILE=<name>` for the
> whole session. In GitHub Actions there is no profile — credentials come from OIDC or
> repository secrets.

---

## 2. Terraform Backend (S3 + Locking)

### Check availability

Test whether a bucket name is free. `404` = available, `403` = taken by another account,
`200` = you already own it. Bucket names are **globally unique** and released on delete.

```bash
aws s3api head-bucket --bucket otel-eks-bucket 2>&1
```

---

### Create

```bash
aws s3api create-bucket --bucket otel-eks-bucket --region us-east-1
```

> **Trap:** `us-east-1` is the **only** region that does not need
> `--create-bucket-configuration LocationConstraint=<region>`. Every other region requires it,
> or you get `IllegalLocationConstraintException`.

---

### Harden — all four are required

**Versioning** — your undo button. Every `terraform apply` writes a new object version, so a
corrupted state can be rolled back to a previous one.

```bash
aws s3api put-bucket-versioning --bucket otel-eks-bucket \
  --versioning-configuration Status=Enabled
```

**Encryption at rest** — Terraform state stores subnet IDs, role ARNs, and sometimes secrets
in plaintext.

```bash
aws s3api put-bucket-encryption --bucket otel-eks-bucket \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
```

**Block public access** — non-negotiable for a state bucket.

```bash
aws s3api put-public-access-block --bucket otel-eks-bucket \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

**Lifecycle** — versioning without expiry grows forever. Expire noncurrent versions after 90 days.

```bash
aws s3api put-bucket-lifecycle-configuration --bucket otel-eks-bucket \
  --lifecycle-configuration file://lifecycle.json
```

---

### Verify

```bash
aws s3api get-bucket-versioning     --bucket otel-eks-bucket
aws s3api get-bucket-encryption     --bucket otel-eks-bucket
aws s3api get-public-access-block   --bucket otel-eks-bucket
aws s3api get-bucket-location       --bucket otel-eks-bucket
```

`get-bucket-location` returns `null` for `us-east-1` — that is correct, not a bug. It is the
legacy default region and AWS represents it as an empty location constraint.

---

### Inspect state objects

List what's actually in the backend.

```bash
aws s3 ls s3://otel-eks-bucket --recursive --human-readable
```

Show every version of the state file — this is what saves you after a bad apply.

```bash
aws s3api list-object-versions --bucket otel-eks-bucket --prefix s3-backend \
  --query "Versions[].{Key:Key,VersionId:VersionId,Modified:LastModified,Size:Size}" \
  --output table
```

Download a specific historical version to inspect before restoring.

```bash
aws s3api get-object --bucket otel-eks-bucket --key s3-backend \
  --version-id <version-id> recovered.tfstate
```

---

### DynamoDB locking (legacy path)

List tables — confirms whether a lock table exists.

```bash
aws dynamodb list-tables --region us-east-1
```

Create a lock table. Partition key **must** be named `LockID`, type String.

```bash
aws dynamodb create-table \
  --table-name terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

See who currently holds the lock (useful when a pipeline dies mid-apply).

```bash
aws dynamodb scan --table-name terraform-locks --region us-east-1
```

> **Modern alternative:** Terraform 1.10+ supports `use_lockfile = true` in the `backend "s3"`
> block, using an S3 `.tflock` object instead. No DynamoDB table, no extra cost.

---

## 3. EKS Cluster

List all clusters in the region. Empty array = clean slate.

```bash
aws eks list-clusters --region us-east-1
```

---

Full cluster description — version, endpoint, VPC config, status.

```bash
aws eks describe-cluster --name boutique-app-eks --region us-east-1
```

---

### Targeted queries (use these, not the full dump)

**OIDC issuer URL** — needed for every IRSA trust policy. Changes on every cluster rebuild.

```bash
aws eks describe-cluster --name boutique-app-eks --region us-east-1 \
  --query "cluster.identity.oidc.issuer" --output text
```

**VPC ID** — required by the AWS Load Balancer Controller Helm install.

```bash
aws eks describe-cluster --name boutique-app-eks --region us-east-1 \
  --query "cluster.resourcesVpcConfig.vpcId" --output text
```

**Subnet IDs the cluster knows about.**

```bash
aws eks describe-cluster --name boutique-app-eks --region us-east-1 \
  --query "cluster.resourcesVpcConfig.subnetIds" --output text
```

**Kubernetes version and status.**

```bash
aws eks describe-cluster --name boutique-app-eks --region us-east-1 \
  --query "cluster.{Version:version,Status:status,Endpoint:endpoint}" --output table
```

---

### Kubeconfig

Write cluster credentials into `~/.kube/config` so `kubectl` can talk to the cluster.

```bash
aws eks update-kubeconfig --region us-east-1 --name boutique-app-eks
```

---

### Node groups

```bash
aws eks list-nodegroups --cluster-name boutique-app-eks --region us-east-1
```

Describe one — shows instance types, scaling config, AMI type, and node role ARN.

```bash
aws eks describe-nodegroup --cluster-name boutique-app-eks \
  --nodegroup-name <nodegroup-name> --region us-east-1
```

---

### Version support

List every Kubernetes version EKS currently offers, with support status. Run this before
choosing a cluster version in Terraform.

```bash
aws eks describe-cluster-versions --region us-east-1 --output table
```

---

## 4. EKS Add-ons

Which add-ons are installed on the cluster.

```bash
aws eks list-addons --cluster-name boutique-app-eks --region us-east-1
```

---

Which add-ons AWS offers at all.

```bash
aws eks describe-addon-versions --region us-east-1 \
  --query "addons[].addonName" --output text
```

---

**Compatibility check — run this after any cluster version bump.** Shows which add-on versions
work with a given Kubernetes version, and which is the default.

```bash
aws eks describe-addon-versions \
  --addon-name aws-ebs-csi-driver \
  --kubernetes-version 1.34 \
  --region us-east-1 \
  --query "addons[].addonVersions[].{Version:addonVersion,Default:compatibilities[0].defaultVersion}" \
  --output table
```

Swap `--addon-name` for: `vpc-cni`, `coredns`, `kube-proxy`, `eks-pod-identity-agent`,
`aws-ebs-csi-driver`.

---

Check the health of an installed add-on — surfaces degraded states Terraform won't show you.

```bash
aws eks describe-addon --cluster-name boutique-app-eks \
  --addon-name eks-pod-identity-agent --region us-east-1
```

---

## 5. VPC & Subnets

List non-default VPCs. Useful for spotting orphans after a failed destroy.

```bash
aws ec2 describe-vpcs --region us-east-1 \
  --query "Vpcs[?IsDefault==\`false\`].{ID:VpcId,CIDR:CidrBlock,Name:Tags[?Key=='Name']|[0].Value}" \
  --output table
```

---

### Subnet tags — the silent killer

The AWS Load Balancer Controller **discovers subnets by tag**. Wrong tags = no ALB, no error
that tells you why.

| Tag | Value | Applies to |
|---|---|---|
| `kubernetes.io/cluster/boutique-app-eks` | `owned` or `shared` | all cluster subnets |
| `kubernetes.io/role/elb` | `1` | **public** subnets (internet-facing ALB) |
| `kubernetes.io/role/internal-elb` | `1` | **private** subnets (internal ALB) |

Verify what's actually tagged:

```bash
aws ec2 describe-subnets --region us-east-1 \
  --filters "Name=tag:kubernetes.io/cluster/boutique-app-eks,Values=owned,shared" \
  --query "Subnets[].{ID:SubnetId,AZ:AvailabilityZone,Public:MapPublicIpOnLaunch,Tags:Tags[?starts_with(Key,'kubernetes.io')]}" \
  --output json
```

Find subnets carrying the public ELB role tag:

```bash
aws ec2 describe-subnets --region us-east-1 \
  --filters "Name=tag:kubernetes.io/role/elb,Values=1" \
  --query "Subnets[].{ID:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock}" --output table
```

> These tags belong in **Terraform**, not in a manual `aws ec2 create-tags`. A manual tag is
> lost on the next rebuild.

---

### NAT Gateways — the expensive one

~$32/month each plus data processing. Always the first thing to check when auditing cost.

```bash
aws ec2 describe-nat-gateways --region us-east-1 \
  --filter "Name=state,Values=available" \
  --query "NatGateways[].{ID:NatGatewayId,VPC:VpcId,Subnet:SubnetId}" --output table
```

---

### Elastic IPs

Unattached EIPs bill ~$3.60/month for doing nothing. This query shows only the orphans.

```bash
aws ec2 describe-addresses --region us-east-1 \
  --query "Addresses[?AssociationId==null].{IP:PublicIp,AllocationId:AllocationId}" \
  --output table
```

---

### Security groups

Find groups left behind by a deleted load balancer.

```bash
aws ec2 describe-security-groups --region us-east-1 \
  --filters "Name=tag:elbv2.k8s.aws/cluster,Values=boutique-app-eks" \
  --query "SecurityGroups[].{ID:GroupId,Name:GroupName}" --output table
```

---

## 6. IAM — Policies, Roles, OIDC

### Policies

Check whether a customer-managed policy already exists before creating it. Re-running
`create-policy` throws `EntityAlreadyExists`.

```bash
aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='AWSLoadBalancerControllerIAMPolicy'].Arn" --output text
```

Create from a downloaded document:

```bash
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json
```

Read the actual permissions in a policy (must fetch the specific version):

```bash
aws iam get-policy-version \
  --policy-arn arn:aws:iam::514005485562:policy/AWSLoadBalancerControllerIAMPolicy \
  --version-id v1
```

---

### Roles

Inspect a role's **trust policy** — this is where rebuild breakage hides.

```bash
aws iam get-role --role-name AmazonEKSLoadBalancerControllerRole \
  --query "Role.AssumeRolePolicyDocument"
```

See which policies are attached:

```bash
aws iam list-attached-role-policies --role-name AmazonEKSLoadBalancerControllerRole
```

Find all project-related roles:

```bash
aws iam list-roles \
  --query "Roles[?contains(RoleName,'EKS') || contains(RoleName,'ExternalDNS')].{Name:RoleName,ARN:Arn}" \
  --output table
```

---

### OIDC providers

List them. **After a cluster rebuild the old provider is dead** — any IRSA role still pointing
at it will fail with `AccessDenied` or `WebIdentityErr`.

```bash
aws iam list-open-id-connect-providers
```

Inspect one:

```bash
aws iam get-open-id-connect-provider --open-id-connect-provider-arn <provider-arn>
```

**Rebuild check** — compare this output against the cluster's current issuer URL from
Section 3. If they don't match, the role needs its trust policy rewritten.

---

## 7. EKS Pod Identity

**Why it exists:** IRSA ties an IAM role's trust policy to a specific cluster's OIDC provider.
Rebuild the cluster and every role breaks. Pod Identity moves the mapping out of IAM and into
an EKS API object, so roles survive cluster churn.

```
IRSA:          IAM Role  ──trusts──►  OIDC Provider (cluster-specific) ──►  breaks on rebuild
Pod Identity:  IAM Role  ──trusts──►  pods.eks.amazonaws.com (static)  ──►  survives rebuild
               Association (EKS API) maps role → namespace + serviceaccount
```

---

Install the agent (usually done in Terraform as an add-on):

```bash
aws eks create-addon --cluster-name boutique-app-eks \
  --addon-name eks-pod-identity-agent --region us-east-1
```

---

Create an association — binds an IAM role to a namespace + service account.

```bash
aws eks create-pod-identity-association \
  --cluster-name boutique-app-eks \
  --namespace kube-system \
  --service-account aws-load-balancer-controller \
  --role-arn arn:aws:iam::514005485562:role/AmazonEKSLoadBalancerControllerRole \
  --region us-east-1
```

List all associations on the cluster:

```bash
aws eks list-pod-identity-associations --cluster-name boutique-app-eks --region us-east-1
```

Delete one:

```bash
aws eks delete-pod-identity-association \
  --cluster-name boutique-app-eks \
  --association-id <association-id> --region us-east-1
```

> **Trust policy requirement:** the role must allow **both** `sts:AssumeRole` **and**
> `sts:TagSession` for principal `pods.eks.amazonaws.com`. Omitting `sts:TagSession` produces
> no error — credentials just never arrive. Most common Pod Identity failure.

---

## 8. Load Balancers

List all ALBs/NLBs. The controller creates these with generated `k8s-*` names.

```bash
aws elbv2 describe-load-balancers --region us-east-1 \
  --query "LoadBalancers[].{Name:LoadBalancerName,DNS:DNSName,Type:Type,Scheme:Scheme,State:State.Code}" \
  --output table
```

---

Listeners on a load balancer — confirms HTTP:80 and HTTPS:443 exist and which cert is bound.

```bash
aws elbv2 describe-listeners --load-balancer-arn <lb-arn> --region us-east-1 \
  --query "Listeners[].{Port:Port,Protocol:Protocol,Cert:Certificates[0].CertificateArn}" \
  --output table
```

---

Target groups and their target type. **`ip` vs `instance` is the thing
`TargetGroupConfiguration` controls.**

```bash
aws elbv2 describe-target-groups --region us-east-1 \
  --query "TargetGroups[].{Name:TargetGroupName,Port:Port,Type:TargetType,Protocol:Protocol}" \
  --output table
```

---

**Health check debugging** — when the site returns 502/503, this tells you why.

```bash
aws elbv2 describe-target-health --target-group-arn <tg-arn> --region us-east-1 \
  --query "TargetHealthDescriptions[].{Target:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason}" \
  --output table
```

---

## 9. Route 53 & ACM

Get the hosted zone ID for the domain (strips the `/hostedzone/` prefix):

```bash
aws route53 list-hosted-zones-by-name --dns-name shalin.online \
  --query "HostedZones[0].Id" --output text | cut -d/ -f3
```

---

List all records in the zone. **ExternalDNS creates a pair**: the A/ALIAS record plus a TXT
ownership record. A stale TXT record with a mismatched owner ID will make a fresh ExternalDNS
refuse to manage the domain.

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id $(aws route53 list-hosted-zones-by-name --dns-name shalin.online \
    --query "HostedZones[0].Id" --output text | cut -d/ -f3) \
  --query "ResourceRecordSets[].{Name:Name,Type:Type,Alias:AliasTarget.DNSName,Value:ResourceRecords[0].Value}" \
  --output table
```

---

### ACM

List certificates and status.

```bash
aws acm list-certificates --region us-east-1 \
  --query "CertificateSummaryList[].{Domain:DomainName,ARN:CertificateArn,Status:Status}" \
  --output table
```

Describe the project cert — confirm it's `ISSUED` and covers the right SANs.

```bash
aws acm describe-certificate \
  --certificate-arn arn:aws:acm:us-east-1:514005485562:certificate/6bd73c4d-4a11-4b26-8dae-2e3f3c59552e \
  --region us-east-1 \
  --query "Certificate.{Domain:DomainName,SANs:SubjectAlternativeNames,Status:Status,InUse:InUseBy}"
```

> **Region rule:** an ALB can only use a certificate from **its own region**. A cert in
> `us-east-1` will not attach to an ALB in `ap-south-1`. (CloudFront is the exception — it
> always wants `us-east-1`.)

---

## 10. Cost & Orphan Audit

Run this block after every teardown. Anything that returns rows is costing money.

```bash
# 1. EKS control planes — ~$73/mo each
aws eks list-clusters --region us-east-1

# 2. NAT gateways — ~$32/mo each
aws ec2 describe-nat-gateways --region us-east-1 \
  --filter "Name=state,Values=available" \
  --query "NatGateways[].NatGatewayId" --output text

# 3. Load balancers — ~$16/mo each
aws elbv2 describe-load-balancers --region us-east-1 \
  --query "LoadBalancers[].LoadBalancerName" --output text

# 4. Unattached Elastic IPs — ~$3.60/mo each
aws ec2 describe-addresses --region us-east-1 \
  --query "Addresses[?AssociationId==null].PublicIp" --output text

# 5. Running EC2 instances
aws ec2 describe-instances --region us-east-1 \
  --filters "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].{ID:InstanceId,Type:InstanceType}" --output table

# 6. EBS volumes not attached to anything
aws ec2 describe-volumes --region us-east-1 \
  --filters "Name=status,Values=available" \
  --query "Volumes[].{ID:VolumeId,Size:Size}" --output table
```

---

**Check other regions too.** Orphans hide in regions you forgot you used.

```bash
for r in us-east-1 us-west-2 ap-south-1 me-central-1 eu-west-1; do
  echo "== $r =="
  aws eks list-clusters --region $r --query "clusters" --output text
done
```

---

Month-to-date spend by service (needs Cost Explorer enabled; adjust the dates):

```bash
aws ce get-cost-and-usage \
  --time-period Start=2026-07-01,End=2026-07-31 \
  --granularity MONTHLY --metrics "UnblendedCost" \
  --group-by Type=DIMENSION,Key=SERVICE \
  --query "ResultsByTime[0].Groups[?Total.UnblendedCost.Amount>\`0.5\`].{Service:Keys[0],Cost:Total.UnblendedCost.Amount}" \
  --output table
```

---

## 11. Teardown Order

**Order matters.** AWS enforces dependencies, and Kubernetes finalizers can block
`terraform destroy` indefinitely.

```
1. Delete Gateway / Ingress objects in K8s   ← lets the controller remove the ALB
2. Confirm the ALB is actually gone          ← aws elbv2 describe-load-balancers
3. Delete leftover ALB security groups
4. terraform destroy
5. Run the Section 10 orphan audit
```

**Why step 1 comes first:** the ALB is created by the controller, not by Terraform. Terraform
has no idea it exists. Destroy the VPC first and it fails with a dependency error, because the
orphaned ALB and its ENIs are still attached to the subnets.

Force-remove a stuck finalizer only as a last resort — it leaks AWS resources:

```bash
kubectl patch gateway <name> -n <namespace> \
  -p '{"metadata":{"finalizers":null}}' --type=merge
```

---

## 12. Output Formatting Cheatsheet

| Flag | Effect |
|---|---|
| `--output table` | Human-readable — best for eyeballing |
| `--output text` | Tab-separated — best for shell substitution `$(...)` |
| `--output json` | Default — best for `jq` |
| `--output yaml` | Readable nested structures |
| `--no-cli-pager` | Stop output opening in `less` |

**JMESPath patterns worth memorising** (`--query`):

```bash
--query "Vpcs[0].VpcId"                          # first item, one field
--query "Subnets[].SubnetId"                     # one field from every item
--query "Subnets[?AvailabilityZone=='us-east-1a']" # filter
--query "Tags[?Key=='Name']|[0].Value"           # pull a tag value
--query "LB[].{Name:LBName,DNS:DNSName}"         # rename into a table
--query "Vpcs[?IsDefault==\`false\`]"             # boolean — needs backticks
```

Backticks around `true`/`false`/numbers. Single quotes around strings. In Git Bash on Windows,
escape the backticks with `\`.

Suppress the pager permanently:

```bash
aws configure set cli_pager ""
```

---

## Appendix — Mistakes Log

| # | What happened | Whose | Fix / lesson |
|---|---|---|---|
| 14 | Deleted the `otel-eks-bucket` Terraform state backend during a cost-panic cleanup | Shalin | State ≠ infrastructure. The bucket cost ~$0.01/mo; NAT gateways were the real cost. Separate bootstrap config + `prevent_destroy` lifecycle rule. |

> Entries 1–13 live in `phase1-networking-guide.md`. Keep numbering continuous across both docs.
