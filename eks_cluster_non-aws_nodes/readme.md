# EKS Ubuntu Cluster Setup — Complete Guide
> Cluster: `abhinav-istio-mesh` | Region: `ap-south-1` | VPC: `vpc-03a2794d55e651007`

---

## Overview

This guide sets up an EKS cluster with Ubuntu nodes in private subnets, using:
- 2 AZs (`ap-south-1a`, `ap-south-1b`), 1 public + 1 private subnet each
- Managed node group with custom Ubuntu AMI via launch template
- NAT Gateway for outbound internet (required for pulling `public.ecr.aws` images)
- S3 Gateway VPC Endpoint (free — keeps ECR image layer traffic off NAT)

---

## Step 1: Check Existing Subnet CIDRs

Before creating subnets, check what's already taken to avoid CIDR conflicts:

```bash
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=<VPC_ID>" \
  --query "Subnets[*].{Name:Tags[?Key=='Name']|[0].Value,CIDR:CidrBlock,AZ:AvailabilityZone}" \
  --output table --region ap-south-1 --no-cli-pager
```

---

## Step 2: Create 4 Subnets (2 public, 2 private)

```bash
# Public - ap-south-1a
aws ec2 create-subnet \
  --vpc-id vpc-03a2794d55e651007 \
  --cidr-block 172.31.96.0/20 \
  --availability-zone ap-south-1a \
  --region ap-south-1 \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=eks-public-1a}]'

# Public - ap-south-1b
aws ec2 create-subnet \
  --vpc-id vpc-03a2794d55e651007 \
  --cidr-block 172.31.112.0/20 \
  --availability-zone ap-south-1b \
  --region ap-south-1 \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=eks-public-1b}]'

# Private - ap-south-1a
aws ec2 create-subnet \
  --vpc-id vpc-03a2794d55e651007 \
  --cidr-block 172.31.128.0/20 \
  --availability-zone ap-south-1a \
  --region ap-south-1 \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=eks-private-1a}]'

# Private - ap-south-1b
aws ec2 create-subnet \
  --vpc-id vpc-03a2794d55e651007 \
  --cidr-block 172.31.144.0/20 \
  --availability-zone ap-south-1b \
  --region ap-south-1 \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=eks-private-1b}]'
```

**Subnet IDs created:**
| Name | ID | AZ |
|------|----|----|
| eks-public-1a | `subnet-0de464b9374299f4f` | ap-south-1a |
| eks-public-1b | `subnet-0d19c48e203f9d89f` | ap-south-1b |
| eks-private-1a | `subnet-0a84ff1d27a0ec841` | ap-south-1a |
| eks-private-1b | `subnet-0d3c0e54898968775` | ap-south-1b |

---

## Step 3: Find the Public Route Table

> ⚠️ **Nuance:** The route table named `public-rt` did NOT have an IGW route. The actual public route table was an unnamed one. Always verify by checking which RT has an `igw-` gateway.

```bash
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=vpc-03a2794d55e651007" \
  --query "RouteTables[*].{ID:RouteTableId,Name:Tags[?Key=='Name']|[0].Value,Routes:Routes[*].GatewayId}" \
  --output table --region ap-south-1 --no-cli-pager
```

Look for the route table with a `GatewayId` starting with `igw-` — that is the real public RT.

**Route tables in this setup:**
| ID | Name | Purpose |
|----|------|---------|
| `rtb-025f5cc4ea36b94a1` | (unnamed) | Public — has IGW route |
| `rtb-00a8caae970f7a5a4` | private-node-rt | Private — used for node subnets |

---

## Step 4: Associate Subnets with Route Tables

```bash
# Associate public subnets with the IGW-backed route table
aws ec2 associate-route-table \
  --subnet-id subnet-0de464b9374299f4f \
  --route-table-id rtb-025f5cc4ea36b94a1 \
  --region ap-south-1 --no-cli-pager

aws ec2 associate-route-table \
  --subnet-id subnet-0d19c48e203f9d89f \
  --route-table-id rtb-025f5cc4ea36b94a1 \
  --region ap-south-1 --no-cli-pager

# Associate private subnets with private-node-rt
aws ec2 associate-route-table \
  --subnet-id subnet-0a84ff1d27a0ec841 \
  --route-table-id rtb-00a8caae970f7a5a4 \
  --region ap-south-1 --no-cli-pager

aws ec2 associate-route-table \
  --subnet-id subnet-0d3c0e54898968775 \
  --route-table-id rtb-00a8caae970f7a5a4 \
  --region ap-south-1 --no-cli-pager
```

---

## Step 5: Enable Auto-Assign Public IP on Public Subnets

```bash
aws ec2 modify-subnet-attribute \
  --subnet-id subnet-0de464b9374299f4f \
  --map-public-ip-on-launch --region ap-south-1

aws ec2 modify-subnet-attribute \
  --subnet-id subnet-0d19c48e203f9d89f \
  --map-public-ip-on-launch --region ap-south-1
```

---

## Step 6: Tag Subnets for EKS

```bash
# Public subnets — for external load balancers
aws ec2 create-tags \
  --resources subnet-0de464b9374299f4f subnet-0d19c48e203f9d89f \
  --tags Key=kubernetes.io/role/elb,Value=1 \
         Key=kubernetes.io/cluster/abhinav-istio-mesh,Value=shared \
  --region ap-south-1

# Private subnets — for nodes + internal load balancers
aws ec2 create-tags \
  --resources subnet-0a84ff1d27a0ec841 subnet-0d3c0e54898968775 \
  --tags Key=kubernetes.io/role/internal-elb,Value=1 \
         Key=kubernetes.io/cluster/abhinav-istio-mesh,Value=shared \
  --region ap-south-1
```

---

## Step 7: Find Ubuntu EKS AMI

> ⚠️ **Nuance:** SSM parameter paths for Ubuntu EKS AMIs are not browsable and the exact path varies. Use `describe-images` with Canonical's account ID instead.

```bash
aws ec2 describe-images \
  --owners 099720109477 \
  --filters \
    "Name=name,Values=ubuntu-eks/k8s_1.29/images/*" \
    "Name=architecture,Values=x86_64" \
    "Name=state,Values=available" \
  --query "sort_by(Images, &CreationDate)[-1].{ID:ImageId,Name:Name,Date:CreationDate}" \
  --output table --region ap-south-1 --no-cli-pager
```

**AMI used:** `ami-0e7ed84d60938cb36` (Ubuntu 22.04 EKS k8s 1.29, Nov 2025)

---

## Step 8: Create Launch Template

> ⚠️ **Nuance:** AWS CLI expects PascalCase keys (`ImageId`, not `imageId`) in `--launch-template-data` JSON. camelCase will fail with `Unknown parameter` errors.

> ⚠️ **Nuance:** Set `HttpPutResponseHopLimit: 2` in MetadataOptions — required for IMDSv2 to work inside containers on the node.

```bash
USERDATA=$(printf '#!/bin/bash\nset -ex\n/etc/eks/bootstrap.sh abhinav-istio-mesh' | base64 -w 0)

aws ec2 create-launch-template \
  --region ap-south-1 --no-cli-pager \
  --launch-template-name eks-ubuntu-lt \
  --launch-template-data "{
    \"ImageId\": \"ami-0e7ed84d60938cb36\",
    \"InstanceType\": \"t3.medium\",
    \"UserData\": \"$USERDATA\",
    \"BlockDeviceMappings\": [{
      \"DeviceName\": \"/dev/sda1\",
      \"Ebs\": {
        \"VolumeSize\": 20,
        \"VolumeType\": \"gp3\",
        \"DeleteOnTermination\": true
      }
    }],
    \"MetadataOptions\": {
      \"HttpTokens\": \"required\",
      \"HttpPutResponseHopLimit\": 2,
      \"HttpEndpoint\": \"enabled\"
    }
  }"
```

### Update Launch Template to t2.small (Version 2)

```bash
USERDATA=$(printf '#!/bin/bash\nset -ex\n/etc/eks/bootstrap.sh abhinav-istio-mesh' | base64 -w 0)

aws ec2 create-launch-template-version \
  --region ap-south-1 --no-cli-pager \
  --launch-template-id lt-09696041f02b6470e \
  --version-description "t2.small Ubuntu EKS nodes" \
  --source-version 1 \
  --launch-template-data "{\"InstanceType\": \"t2.small\", \"UserData\": \"$USERDATA\"}"
```

### Fix FIPS Error on Ubuntu 22.04 (Version 3)

> ⚠️ **Nuance:** Ubuntu 22.04 doesn't have the `crypto/fips_enabled` kernel module that the EKS bootstrap script checks for. This causes the bootstrap to exit with an error. Workaround: pre-create the file before calling bootstrap.

```bash
USERDATA=$(cat <<'EOF' | base64 -w 0
#!/bin/bash
set -ex
echo 0 > /proc/sys/crypto/fips_enabled 2>/dev/null || true
/etc/eks/bootstrap.sh abhinav-istio-mesh \
  --use-max-pods false \
  --kubelet-extra-args '--node-labels=eks.amazonaws.com/nodegroup=ubuntu-nodes'
EOF
)

aws ec2 create-launch-template-version \
  --region ap-south-1 --no-cli-pager \
  --launch-template-id lt-09696041f02b6470e \
  --version-description "Ubuntu fix FIPS" \
  --source-version 2 \
  --launch-template-data "{\"UserData\": \"$USERDATA\"}"
```

**Launch Template ID:** `lt-09696041f02b6470e` | **Final version used:** `3`

---

## Step 9: Create EKS Cluster (Control Plane Only)

> ⚠️ **Nuance:** `eksctl create cluster` does not support `--vpc-id` as a standalone flag. You must use a config file for existing VPC setups.

> ⚠️ **Nuance:** CloudWatch logging is off by default — no need to explicitly disable it.

```bash
cat <<EOF > cluster-config.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: abhinav-istio-mesh
  region: ap-south-1
  version: "1.33"

vpc:
  id: vpc-03a2794d55e651007
  subnets:
    public:
      ap-south-1a:
        id: subnet-0de464b9374299f4f
      ap-south-1b:
        id: subnet-0d19c48e203f9d89f
    private:
      ap-south-1a:
        id: subnet-0a84ff1d27a0ec841
      ap-south-1b:
        id: subnet-0d3c0e54898968775

iam:
  withOIDC: true
EOF

eksctl create cluster -f cluster-config.yaml
```

---

## Step 10: Create IAM Node Role

> ⚠️ **Nuance:** When using `aws eks create-nodegroup` directly (instead of eksctl), you must pre-create the IAM node role manually. eksctl would have done this automatically.

```bash
# Create the role
aws iam create-role \
  --role-name eksNodeRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "ec2.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }' --no-cli-pager

# Attach required policies
aws iam attach-role-policy --role-name eksNodeRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
aws iam attach-role-policy --role-name eksNodeRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
aws iam attach-role-policy --role-name eksNodeRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam attach-role-policy --role-name eksNodeRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
```

---

## Step 11: Create Managed Node Group via AWS CLI

> ⚠️ **Nuance:** Do NOT use `eksctl create nodegroup` with Ubuntu — eksctl ignores the launch template AMI and defaults to AL2023. Using `aws eks create-nodegroup` directly respects the launch template fully.

> ⚠️ **Nuance:** `amiFamily: Ubuntu2204` in eksctl config does NOT work for k8s 1.33 — SSM path doesn't exist and eksctl throws `ParameterNotFound`.

```bash
aws eks create-nodegroup \
  --cluster-name abhinav-istio-mesh \
  --nodegroup-name ubuntu-nodes \
  --scaling-config minSize=1,maxSize=3,desiredSize=2 \
  --subnets subnet-0a84ff1d27a0ec841 subnet-0d3c0e54898968775 \
  --launch-template id=lt-09696041f02b6470e,version=3 \
  --node-role arn:aws:iam::183295435445:role/eksNodeRole \
  --region ap-south-1 --no-cli-pager
```

---

## Step 12: Set Up NAT Gateway

> ⚠️ **Nuance:** Nodes in private subnets need outbound internet to pull images from `public.ecr.aws` (pause container, etc.). VPC endpoints alone are NOT enough — `public.ecr.aws` is a public endpoint and requires NAT or IGW.

> ⚠️ **Nuance:** If nodes boot before NAT is ready, they will fail to join. You must delete and recreate the nodegroup after fixing NAT — existing failed instances won't retry.

> ⚠️ **Nuance:** If a `0.0.0.0/0` route already exists (blackhole), use `replace-route` not `create-route`.

```bash
# Allocate Elastic IP
aws ec2 allocate-address \
  --domain vpc --region ap-south-1 --no-cli-pager

# Create NAT Gateway in public subnet (1a)
aws ec2 create-nat-gateway \
  --subnet-id subnet-0de464b9374299f4f \
  --allocation-id <ALLOCATION_ID> \
  --region ap-south-1 --no-cli-pager

# Wait ~2 mins for NAT to become available, then add/replace route
aws ec2 replace-route \
  --route-table-id rtb-00a8caae970f7a5a4 \
  --destination-cidr-block 0.0.0.0/0 \
  --nat-gateway-id <NAT_GATEWAY_ID> \
  --region ap-south-1 --no-cli-pager
```

---

## Step 13: Set Up VPC Endpoints

> ⚠️ **Nuance:** Even with NAT, VPC endpoints for ECR and STS reduce data transfer costs and keep traffic within AWS network.

> ⚠️ **Nuance:** You also need the `eks` endpoint so nodes can register with the control plane — without it nodes cannot join the cluster even if NAT is working.

```bash
# S3 Gateway Endpoint (free)
aws ec2 create-vpc-endpoint \
  --vpc-id vpc-03a2794d55e651007 \
  --service-name com.amazonaws.ap-south-1.s3 \
  --route-table-ids rtb-00a8caae970f7a5a4 \
  --vpc-endpoint-type Gateway \
  --region ap-south-1 --no-cli-pager

# ECR API Interface Endpoint
aws ec2 create-vpc-endpoint \
  --vpc-id vpc-03a2794d55e651007 \
  --service-name com.amazonaws.ap-south-1.ecr.api \
  --vpc-endpoint-type Interface \
  --subnet-ids subnet-0a84ff1d27a0ec841 subnet-0d3c0e54898968775 \
  --security-group-ids sg-00d505cb4c1237db5 \
  --private-dns-enabled \
  --region ap-south-1 --no-cli-pager

# ECR DKR Interface Endpoint
aws ec2 create-vpc-endpoint \
  --vpc-id vpc-03a2794d55e651007 \
  --service-name com.amazonaws.ap-south-1.ecr.dkr \
  --vpc-endpoint-type Interface \
  --subnet-ids subnet-0a84ff1d27a0ec841 subnet-0d3c0e54898968775 \
  --security-group-ids sg-00d505cb4c1237db5 \
  --private-dns-enabled \
  --region ap-south-1 --no-cli-pager

# STS Interface Endpoint (for IAM role token exchange)
aws ec2 create-vpc-endpoint \
  --vpc-id vpc-03a2794d55e651007 \
  --service-name com.amazonaws.ap-south-1.sts \
  --vpc-endpoint-type Interface \
  --subnet-ids subnet-0a84ff1d27a0ec841 subnet-0d3c0e54898968775 \
  --security-group-ids sg-00d505cb4c1237db5 \
  --private-dns-enabled \
  --region ap-south-1 --no-cli-pager

# EKS Interface Endpoint (for node registration with control plane)
aws ec2 create-vpc-endpoint \
  --vpc-id vpc-03a2794d55e651007 \
  --service-name com.amazonaws.ap-south-1.eks \
  --vpc-endpoint-type Interface \
  --subnet-ids subnet-0a84ff1d27a0ec841 subnet-0d3c0e54898968775 \
  --security-group-ids sg-00d505cb4c1237db5 \
  --private-dns-enabled \
  --region ap-south-1 --no-cli-pager
```

---

## Step 14: Verify Nodes Joined

```bash
aws eks update-kubeconfig --name abhinav-istio-mesh --region ap-south-1
kubectl get nodes -w
```

---

## Debugging Commands

```bash
# Check nodegroup health
aws eks describe-nodegroup \
  --cluster-name abhinav-istio-mesh \
  --nodegroup-name ubuntu-nodes \
  --region ap-south-1 \
  --query "nodegroup.health" \
  --output json --no-cli-pager

# Check EC2 instance boot logs (most useful for debugging join failures)
aws ec2 get-console-output \
  --instance-id <INSTANCE_ID> \
  --region ap-south-1 \
  --query Output \
  --output text --no-cli-pager | tail -80

# Check running node instances
aws ec2 describe-instances \
  --filters "Name=tag:eks:cluster-name,Values=abhinav-istio-mesh" \
  --query "Reservations[*].Instances[*].{ID:InstanceId,State:State.Name,AZ:Placement.AvailabilityZone}" \
  --output table --region ap-south-1 --no-cli-pager

# Verify route table
aws ec2 describe-route-tables \
  --route-table-ids rtb-00a8caae970f7a5a4 \
  --query "RouteTables[0].Routes" \
  --output table --region ap-south-1 --no-cli-pager

# Poll nodegroup deletion (Git Bash compatible)
while true; do
  aws eks describe-nodegroup \
    --cluster-name abhinav-istio-mesh \
    --nodegroup-name ubuntu-nodes \
    --region ap-south-1 \
    --query 'nodegroup.status' \
    --output text --no-cli-pager 2>&1
  sleep 15
done
```

---

## Key Nuances Summary

| # | Nuance |
|---|--------|
| 1 | `eksctl` doesn't support `--vpc-id` flag — must use config file |
| 2 | Route table named `public-rt` had no IGW — always verify via routes, not name |
| 3 | AWS CLI requires PascalCase keys in `--launch-template-data` JSON |
| 4 | `eksctl create nodegroup` ignores launch template AMI and defaults to AL2023 — use `aws eks create-nodegroup` instead |
| 5 | `amiFamily: Ubuntu2204` doesn't work with k8s 1.33 in eksctl |
| 6 | Ubuntu 22.04 EKS bootstrap fails on missing `crypto/fips_enabled` — workaround in userdata |
| 7 | `public.ecr.aws` (pause image) requires internet access — VPC endpoints alone are not enough, NAT is required |
| 8 | Nodes that boot before NAT is ready will permanently fail — must delete and recreate nodegroup |
| 9 | Use `replace-route` if `0.0.0.0/0` route already exists (blackhole) |
| 10 | `eks` VPC endpoint is required for nodes to register with the control plane |
| 11 | CoreDNS shows degraded with no nodes — normal, resolves automatically once nodes join |
| 12 | `watch` command not available on Git Bash — use `while true; do ... sleep N; done` instead |