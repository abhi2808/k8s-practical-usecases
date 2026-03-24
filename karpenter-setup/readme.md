# Karpenter v1.10.0 on EKS — Private Cluster (No IGW) Guide

**Tested API version:** `karpenter.sh/v1` · `karpenter.k8s.aws/v1`  
**Target:** EKS clusters with **only private subnets** — no Internet Gateway, no NAT Gateway in route table  
**Key difference from public-subnet installs:** You must pre-create VPC endpoints and use `instanceProfile` in EC2NodeClass instead of `role`

---

## What Changed from v0.37 → v1.10

| Area | v0.37 (v1beta1) | v1.10 (v1) |
|---|---|---|
| API version | `karpenter.sh/v1beta1` | `karpenter.sh/v1` |
| EC2NodeClass API | `karpenter.k8s.aws/v1beta1` | `karpenter.k8s.aws/v1` |
| NodePool `nodeClassRef` | just `name:` | requires `group:` + `kind:` + `name:` |
| Consolidation policy | `WhenUnderutilized` only | `WhenEmptyOrUnderutilized` (new combined value) |
| `consolidateAfter` | not available | available and recommended |
| `expireAfter` | not available | available on NodePool |
| Separate CRD Helm release | recommended | **no longer needed** — CRDs bundled in main chart |
| `settings.clusterEndpoint` helm flag | required | still required |
| `settings.isolatedVPC` helm flag | existed | **still required for private clusters** |

---

## Prerequisites

- EKS cluster running with at least one managed node group (for Karpenter's own pod to run on)
- AWS CLI configured with sufficient IAM permissions
- `kubectl`, `eksctl` (>= v0.202.0), `helm`, `envsubst` installed
- **Your cluster must have private subnets tagged appropriately** (Step 8 covers this)

---

## Step 1 — Configure AWS CLI & kubeconfig

```bash
aws configure
aws eks update-kubeconfig --region <your-region> --name <your-cluster-name>
```

---

## Step 2 — Export Environment Variables

Pin the version explicitly. Never use `latest`.

```bash
export CLUSTER_NAME="<your-cluster-name>"
export AWS_REGION="$(aws configure get region)"
export AWS_PARTITION="aws"
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query 'Account' --output text)"
export CLUSTER_ENDPOINT="$(aws eks describe-cluster --name $CLUSTER_NAME \
  --query 'cluster.endpoint' --output text)"
export OIDC_ENDPOINT="$(aws eks describe-cluster --name $CLUSTER_NAME \
  --query 'cluster.identity.oidc.issuer' --output text)"
export KARPENTER_VERSION="1.10.0"
export KARPENTER_NAMESPACE="kube-system"
```

Verify everything resolved:

```bash
echo "Cluster:   $CLUSTER_NAME"
echo "Region:    $AWS_REGION"
echo "Account:   $AWS_ACCOUNT_ID"
echo "Endpoint:  $CLUSTER_ENDPOINT"
echo "OIDC:      $OIDC_ENDPOINT"
echo "Version:   $KARPENTER_VERSION"
```

**Stop if any value is blank.** IAM trust policies with empty ARNs will silently fail later.

---

## Step 3 — Create VPC Endpoints (Private Cluster Requirement)

> ⚠️ **This is the primary reason the v0.37 guide failed on private subnets.**  
> Without these endpoints, the Karpenter controller cannot reach AWS APIs, and launched nodes cannot pull container images or bootstrap.

Get your VPC and subnet IDs:

```bash
export VPC_ID="$(aws eks describe-cluster --name $CLUSTER_NAME \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)"

export SUBNET_IDS="$(aws eks describe-cluster --name $CLUSTER_NAME \
  --query 'cluster.resourcesVpcConfig.subnetIds' --output text | tr '\t' ' ')"

export CLUSTER_SG="$(aws eks describe-cluster --name $CLUSTER_NAME \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)"
```

Create each required VPC Interface endpoint. **All six are required** — skipping any one of them will cause a specific failure mode described below each endpoint.

```bash
# 1. EC2 — Karpenter calls RunInstances, DescribeInstances, etc.
aws ec2 create-vpc-endpoint \
  --vpc-id $VPC_ID \
  --service-name com.amazonaws.${AWS_REGION}.ec2 \
  --vpc-endpoint-type Interface \
  --subnet-ids $SUBNET_IDS \
  --security-group-ids $CLUSTER_SG \
  --private-dns-enabled

# 2. ECR API — required to resolve ECR image metadata
aws ec2 create-vpc-endpoint \
  --vpc-id $VPC_ID \
  --service-name com.amazonaws.${AWS_REGION}.ecr.api \
  --vpc-endpoint-type Interface \
  --subnet-ids $SUBNET_IDS \
  --security-group-ids $CLUSTER_SG \
  --private-dns-enabled

# 3. ECR DKR — required to pull container images (Karpenter controller image lives in public ECR,
#    which is mirrored through this endpoint when using private DNS)
aws ec2 create-vpc-endpoint \
  --vpc-id $VPC_ID \
  --service-name com.amazonaws.${AWS_REGION}.ecr.dkr \
  --vpc-endpoint-type Interface \
  --subnet-ids $SUBNET_IDS \
  --security-group-ids $CLUSTER_SG \
  --private-dns-enabled

# 4. S3 (Gateway type, not Interface) — backing store for ECR image layers
aws ec2 create-vpc-endpoint \
  --vpc-id $VPC_ID \
  --service-name com.amazonaws.${AWS_REGION}.s3 \
  --vpc-endpoint-type Gateway \
  --route-table-ids $(aws ec2 describe-route-tables \
      --filters "Name=vpc-id,Values=$VPC_ID" \
      --query 'RouteTables[].RouteTableId' --output text)

# 5. STS — required for IRSA; without this the Karpenter pod cannot assume its IAM role
aws ec2 create-vpc-endpoint \
  --vpc-id $VPC_ID \
  --service-name com.amazonaws.${AWS_REGION}.sts \
  --vpc-endpoint-type Interface \
  --subnet-ids $SUBNET_IDS \
  --security-group-ids $CLUSTER_SG \
  --private-dns-enabled

# 6. SSM — Karpenter queries SSM to resolve the recommended EKS-optimised AMI ID
aws ec2 create-vpc-endpoint \
  --vpc-id $VPC_ID \
  --service-name com.amazonaws.${AWS_REGION}.ssm \
  --vpc-endpoint-type Interface \
  --subnet-ids $SUBNET_IDS \
  --security-group-ids $CLUSTER_SG \
  --private-dns-enabled
```

> ℹ️ **Pricing API has no VPC endpoint.** Karpenter ships a static on-demand price list in its binary and falls back to it automatically — you will see a benign log error about pricing data going stale. This is expected and does not block node provisioning.

Verify endpoints are available:

```bash
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available" \
  --query 'VpcEndpoints[].{Service:ServiceName,State:State}' \
  --output table
```

You should see all six services listed as `available`.

---

## Step 4 — Create IAM OIDC Provider

Required for IRSA. Skip if it already exists.

```bash
# Check first
aws iam list-open-id-connect-providers | grep \
  $(aws eks describe-cluster --name $CLUSTER_NAME \
    --query 'cluster.identity.oidc.issuer' \
    --output text | cut -d '/' -f 5)

# Create if nothing returned above
eksctl utils associate-iam-oidc-provider \
  --cluster $CLUSTER_NAME \
  --approve
```

---

## Step 5 — Create KarpenterNodeRole

This role is assumed by EC2 **instances** that Karpenter launches (not the controller pod).

```bash
cat > node-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role \
  --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
  --assume-role-policy-document file://node-trust-policy.json
```

---

## Step 6 — Attach Required Node Policies

> ⚠️ **All four are required.** Missing `AmazonEKSWorkerNodePolicy` is the most common cause of nodes that boot but never join the cluster.

```bash
aws iam attach-role-policy \
  --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
  --policy-arn "arn:${AWS_PARTITION}:iam::aws:policy/AmazonEKSWorkerNodePolicy"

aws iam attach-role-policy \
  --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
  --policy-arn "arn:${AWS_PARTITION}:iam::aws:policy/AmazonEKS_CNI_Policy"

aws iam attach-role-policy \
  --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
  --policy-arn "arn:${AWS_PARTITION}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"

aws iam attach-role-policy \
  --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
  --policy-arn "arn:${AWS_PARTITION}:iam::aws:policy/AmazonSSMManagedInstanceCore"
```

Verify:

```bash
aws iam list-attached-role-policies \
  --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
  --query 'AttachedPolicies[].PolicyName' \
  --output table
```

---

## Step 7 — Create Instance Profile

> ⚠️ **Private cluster caveat:** In v1.10, the EC2NodeClass `spec.role` field causes Karpenter to auto-manage instance profiles — which requires calling the IAM API. There is **no VPC endpoint for IAM**, so this will fail silently in private clusters. You must use `spec.instanceProfile` and pre-create the profile manually (done here).

```bash
aws iam create-instance-profile \
  --instance-profile-name "KarpenterNodeInstanceProfile-${CLUSTER_NAME}"

aws iam add-role-to-instance-profile \
  --instance-profile-name "KarpenterNodeInstanceProfile-${CLUSTER_NAME}" \
  --role-name "KarpenterNodeRole-${CLUSTER_NAME}"
```

---

## Step 8 — Create KarpenterControllerRole

The controller role is assumed by the Karpenter **pod** via IRSA.

> ⚠️ The `${OIDC_ENDPOINT#*//}` substitution strips the `https://` prefix from the OIDC URL. Do not hardcode the URL or the ARN will be malformed.

```bash
cat > controller-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_ENDPOINT#*//}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_ENDPOINT#*//}:aud": "sts.amazonaws.com",
        "${OIDC_ENDPOINT#*//}:sub": "system:serviceaccount:${KARPENTER_NAMESPACE}:karpenter"
      }
    }
  }]
}
EOF

aws iam create-role \
  --role-name "KarpenterControllerRole-${CLUSTER_NAME}" \
  --assume-role-policy-document file://controller-trust-policy.json
```

---

## Step 9 — Create and Attach Controller Policy

The v1.10 controller policy has **more granular statements** than v0.37. Use the full policy below — trimming permissions will cause confusing failures.

```bash
cat > controller-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowScopedEC2InstanceAccessActions",
      "Effect": "Allow",
      "Resource": [
        "arn:aws:ec2:*::image/*",
        "arn:aws:ec2:*::snapshot/*",
        "arn:aws:ec2:*:*:spot-instances-request/*",
        "arn:aws:ec2:*:*:security-group/*",
        "arn:aws:ec2:*:*:subnet/*",
        "arn:aws:ec2:*:*:launch-template/*"
      ],
      "Action": [
        "ec2:RunInstances",
        "ec2:CreateFleet"
      ]
    },
    {
      "Sid": "AllowScopedEC2LaunchTemplateAccessActions",
      "Effect": "Allow",
      "Resource": "arn:aws:ec2:*:*:fleet/*",
      "Action": "ec2:CreateFleet"
    },
    {
      "Sid": "AllowScopedEC2InstanceActionsWithTags",
      "Effect": "Allow",
      "Resource": [
        "arn:aws:ec2:*:*:instance/*",
        "arn:aws:ec2:*:*:volume/*",
        "arn:aws:ec2:*:*:network-interface/*",
        "arn:aws:ec2:*:*:launch-template/*",
        "arn:aws:ec2:*:*:spot-instances-request/*"
      ],
      "Action": [
        "ec2:RunInstances",
        "ec2:CreateFleet",
        "ec2:CreateLaunchTemplate"
      ],
      "Condition": {
        "StringEquals": {
          "aws:RequestTag/kubernetes.io/cluster/${CLUSTER_NAME}": "owned"
        },
        "StringLike": {
          "aws:RequestTag/karpenter.sh/nodepool": "*"
        }
      }
    },
    {
      "Sid": "AllowScopedResourceCreationTagging",
      "Effect": "Allow",
      "Resource": [
        "arn:aws:ec2:*:*:instance/*",
        "arn:aws:ec2:*:*:volume/*",
        "arn:aws:ec2:*:*:network-interface/*",
        "arn:aws:ec2:*:*:launch-template/*",
        "arn:aws:ec2:*:*:spot-instances-request/*"
      ],
      "Action": "ec2:CreateTags",
      "Condition": {
        "StringEquals": {
          "ec2:CreateAction": ["RunInstances", "CreateFleet", "CreateLaunchTemplate"]
        }
      }
    },
    {
      "Sid": "AllowScopedResourceTagging",
      "Effect": "Allow",
      "Resource": "arn:aws:ec2:*:*:instance/*",
      "Action": "ec2:CreateTags",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/kubernetes.io/cluster/${CLUSTER_NAME}": "owned"
        },
        "StringLike": {
          "aws:ResourceTag/karpenter.sh/nodepool": "*"
        },
        "ForAllValues:StringEquals": {
          "aws:TagKeys": ["karpenter.sh/nodeclaim", "Name"]
        }
      }
    },
    {
      "Sid": "AllowScopedDeletion",
      "Effect": "Allow",
      "Resource": [
        "arn:aws:ec2:*:*:instance/*",
        "arn:aws:ec2:*:*:launch-template/*"
      ],
      "Action": [
        "ec2:TerminateInstances",
        "ec2:DeleteLaunchTemplate"
      ],
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/kubernetes.io/cluster/${CLUSTER_NAME}": "owned"
        },
        "StringLike": {
          "aws:ResourceTag/karpenter.sh/nodepool": "*"
        }
      }
    },
    {
      "Sid": "AllowRegionalReadActions",
      "Effect": "Allow",
      "Resource": "*",
      "Action": [
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeImages",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceTypeOfferings",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplates",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSpotPriceHistory",
        "ec2:DescribeSubnets"
      ]
    },
    {
      "Sid": "AllowSSMReadActions",
      "Effect": "Allow",
      "Resource": "arn:aws:ssm:*::parameter/aws/service/*",
      "Action": "ssm:GetParameter"
    },
    {
      "Sid": "AllowPricingReadActions",
      "Effect": "Allow",
      "Resource": "*",
      "Action": "pricing:GetProducts"
    },
    {
      "Sid": "AllowPassingInstanceRole",
      "Effect": "Allow",
      "Resource": "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}",
      "Action": "iam:PassRole",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "ec2.amazonaws.com"
        }
      }
    },
    {
      "Sid": "AllowInstanceProfileReadActions",
      "Effect": "Allow",
      "Resource": "*",
      "Action": "iam:GetInstanceProfile"
    },
    {
      "Sid": "AllowEKSClusterEndpointLookup",
      "Effect": "Allow",
      "Resource": "arn:${AWS_PARTITION}:eks:${AWS_REGION}:${AWS_ACCOUNT_ID}:cluster/${CLUSTER_NAME}",
      "Action": "eks:DescribeCluster"
    },
    {
      "Sid": "AllowInterruptionQueueActions",
      "Effect": "Allow",
      "Resource": "arn:${AWS_PARTITION}:sqs:${AWS_REGION}:${AWS_ACCOUNT_ID}:${CLUSTER_NAME}",
      "Action": [
        "sqs:DeleteMessage",
        "sqs:GetQueueUrl",
        "sqs:ReceiveMessage"
      ]
    },
    {
      "Sid": "AllowEC2EventBridgeActions",
      "Effect": "Allow",
      "Resource": "*",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceStatus"
      ]
    }
  ]
}
EOF
```

Substitute variables and attach:

```bash
envsubst < controller-policy.json > controller-policy-final.json

aws iam put-role-policy \
  --role-name "KarpenterControllerRole-${CLUSTER_NAME}" \
  --policy-name "KarpenterControllerPolicy-${CLUSTER_NAME}" \
  --policy-document file://controller-policy-final.json
```

Verify all Sids were attached:

```bash
aws iam get-role-policy \
  --role-name "KarpenterControllerRole-${CLUSTER_NAME}" \
  --policy-name "KarpenterControllerPolicy-${CLUSTER_NAME}" \
  --query 'PolicyDocument.Statement[].Sid' \
  --output table
```

---

## Step 10 — Tag Subnets & Security Group

> ⚠️ **Do not skip.** Karpenter uses tag-based discovery to find subnets and security groups. Without these tags the EC2NodeClass will show `NodeClassNotReady` and no nodes will launch.

```bash
# Tag subnets across all nodegroups
for NG in $(aws eks list-nodegroups --cluster-name $CLUSTER_NAME \
  --query 'nodegroups' --output text); do
  aws ec2 create-tags \
    --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" \
    --resources $(aws eks describe-nodegroup \
      --cluster-name $CLUSTER_NAME \
      --nodegroup-name $NG \
      --query 'nodegroup.subnets' --output text)
done

# Tag cluster security group
SG=$(aws eks describe-cluster --name $CLUSTER_NAME \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)

aws ec2 create-tags \
  --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" \
  --resources $SG
```

Verify tags landed:

```bash
aws ec2 describe-subnets \
  --filters "Name=tag:karpenter.sh/discovery,Values=${CLUSTER_NAME}" \
  --query 'Subnets[].{ID:SubnetId,AZ:AvailabilityZone,Public:MapPublicIpOnLaunch}' \
  --output table

aws ec2 describe-security-groups \
  --filters "Name=tag:karpenter.sh/discovery,Values=${CLUSTER_NAME}" \
  --query 'SecurityGroups[].{ID:GroupId,Name:GroupName}' \
  --output table
```

Both tables must be non-empty. The `Public` column on subnets should show `False` — that's expected for private clusters.

---

## Step 11 — Map Node Role to aws-auth

Allows Karpenter-provisioned nodes to authenticate with the Kubernetes API and join the cluster.

```bash
eksctl create iamidentitymapping \
  --username system:node:{{EC2PrivateDNSName}} \
  --cluster $CLUSTER_NAME \
  --arn "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}" \
  --group system:bootstrappers \
  --group system:nodes
```

Verify:

```bash
kubectl get configmap aws-auth -n kube-system -o yaml | grep -A 4 "KarpenterNodeRole"
```

---

## Step 12 — Install Karpenter via Helm

> **v1.10 change:** You no longer need a separate `karpenter-crd` Helm release. CRDs are bundled in the main chart. Installing a separate CRD chart alongside the main chart in v1.10 can cause conflicts.

A few flags are critical for private clusters:

- `--set settings.isolatedVPC=true` — tells Karpenter not to attempt outbound calls to services without VPC endpoints (most importantly, the Pricing API). Without this flag you will see repeated timeout errors and degraded startup time.
- `--set settings.clusterEndpoint` — required; Karpenter uses this to configure node bootstrap.
- No `--wait` flag — avoids Helm timing out and leaving a stuck release lock.

```bash
helm upgrade --install karpenter \
  oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace "${KARPENTER_NAMESPACE}" \
  --create-namespace \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.clusterEndpoint=${CLUSTER_ENDPOINT}" \
  --set "settings.isolatedVPC=true" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterControllerRole-${CLUSTER_NAME}" \
  --set controller.resources.requests.cpu=100m \
  --set controller.resources.requests.memory=256Mi \
  --set controller.resources.limits.cpu=200m \
  --set controller.resources.limits.memory=256Mi \
  --set replicas=1
```

> **Note on `replicas=1`:** If your bootstrap node group has only one node, keep `replicas=1` to avoid a pod anti-affinity deadlock where the second replica refuses to schedule on the same node as the first. With two or more nodes in the managed node group you can safely use `replicas=2` for HA.

Wait for the pod:

```bash
kubectl get pods -n ${KARPENTER_NAMESPACE} -l app.kubernetes.io/name=karpenter
```

Wait until you see `1/1 Running`. If stuck in `Pending`, check events:

```bash
kubectl describe pod -n ${KARPENTER_NAMESPACE} \
  -l app.kubernetes.io/name=karpenter | grep -A 10 "Events"
```

Check controller logs for any errors before continuing:

```bash
kubectl logs -n ${KARPENTER_NAMESPACE} \
  -l app.kubernetes.io/name=karpenter --tail=50
```

---

## Step 13 — Verify CRDs

```bash
kubectl get crds | grep karpenter
```

Expected output (three CRDs):

```
ec2nodeclasses.karpenter.k8s.aws
nodeclaims.karpenter.sh
nodepools.karpenter.sh
```

Confirm the API version is `v1` (not `v1beta1`):

```bash
kubectl get crd nodepools.karpenter.sh \
  -o jsonpath='{.spec.versions[*].name}'
```

Expected: `v1`

---

## Step 14 — Create EC2NodeClass

> ⚠️ **Use `instanceProfile`, not `role`.**  
> In v1.10, `spec.role` makes Karpenter auto-manage instance profiles by calling the IAM API. There is no VPC endpoint for IAM in private clusters, so this will fail. Use `spec.instanceProfile` pointing to the profile you created in Step 7.  
> The CRD enforces that exactly one of `role` or `instanceProfile` is set — you cannot set both.

```bash
cat > ec2nodeclass.yaml << EOF
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  # Use instanceProfile for private clusters — 'role' requires IAM API access
  # which has no VPC endpoint
  instanceProfile: "KarpenterNodeInstanceProfile-${CLUSTER_NAME}"
  amiSelectorTerms:
    - alias: "al2023@latest"   # pin to a specific version in production e.g. al2023@v20240625
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}"
  tags:
    managed-by: karpenter
    cluster: "${CLUSTER_NAME}"
EOF

kubectl apply -f ec2nodeclass.yaml
```

Verify it becomes Ready:

```bash
kubectl describe ec2nodeclass default | grep -A 5 "Conditions"
```

You should see `Status: True` and `Type: Ready`. If it shows `NodeClassNotReady`:

- Subnet error → tags from Step 10 didn't apply. Re-run tagging commands.
- SecurityGroup error → same as above.
- AMI resolution error → SSM VPC endpoint from Step 3 is missing or not yet `available`.

---

## Step 15 — Create NodePool

> ⚠️ **Always set `limits`.** Without them a misconfigured deployment or runaway HPA could scale to hundreds of nodes unnoticed.

> **v1.10 API changes from v0.37:**
> - `nodeClassRef` now requires `group:` and `kind:` in addition to `name:`
> - `consolidationPolicy: WhenEmptyOrUnderutilized` is now valid (was v1-only, not available in v1beta1)
> - `consolidateAfter` is now available and recommended
> - `expireAfter` is available at the template level

```bash
cat > nodepool.yaml << 'EOF'
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    metadata:
      labels:
        managed-by: karpenter
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["2"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
      expireAfter: 720h   # 30 days — forces node rotation to pick up AMI updates
  limits:
    cpu: "100"
    memory: 400Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
EOF

kubectl apply -f nodepool.yaml
```

Verify both resources are Ready:

```bash
kubectl get nodepool
kubectl get ec2nodeclass
```

Both should show `READY=True`.

---

## Step 16 — Test Autoscaling

Deploy a test workload using the `pause` image — it requests CPU but consumes almost no actual resources.

```bash
cat > inflate.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inflate
spec:
  replicas: 0
  selector:
    matchLabels:
      app: inflate
  template:
    metadata:
      labels:
        app: inflate
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: inflate
          image: public.ecr.aws/eks-distro/kubernetes/pause:3.7
          resources:
            requests:
              cpu: "1"
EOF

kubectl apply -f inflate.yaml
kubectl scale deployment inflate --replicas 5
```

Watch in separate terminals:

```bash
# Terminal 1 — pod scheduling
kubectl get pods -w

# Terminal 2 — new nodes appearing
kubectl get nodes -w

# Terminal 3 — Karpenter controller logs
kubectl logs -n ${KARPENTER_NAMESPACE} \
  -l app.kubernetes.io/name=karpenter -f
```

Look for these log lines:

```
launched nodeclaim   ← EC2 launch request sent
registered node      ← node joined the cluster
```

A new node should appear within 60–90 seconds. Pods go `Pending → Running` once the node reaches `Ready`.

Test scale-down:

```bash
kubectl scale deployment inflate --replicas 0
```

Karpenter should deprovision the empty node within 1–2 minutes via `WhenEmptyOrUnderutilized` consolidation.

---

## Troubleshooting Private Cluster Issues

### Karpenter pod fails to start / CrashLoopBackOff

```bash
kubectl logs -n ${KARPENTER_NAMESPACE} \
  -l app.kubernetes.io/name=karpenter --previous
```

Common causes in private clusters:

| Error in logs | Cause | Fix |
|---|---|---|
| `dial tcp ... sts.amazonaws.com ... i/o timeout` | Missing STS VPC endpoint | Add STS endpoint (Step 3) |
| `RequestError: send request failed ... ssm.amazonaws.com` | Missing SSM VPC endpoint | Add SSM endpoint (Step 3) |
| `AccessDenied` when calling `sts:AssumeRoleWithWebIdentity` | OIDC provider not created or trust policy malformed | Re-check Steps 4 & 8 |
| Image pull errors | ECR endpoints missing or Karpenter image not mirrored | Add ECR API + DKR + S3 endpoints (Step 3) |

### EC2NodeClass stuck in NotReady

```bash
kubectl describe ec2nodeclass default
```

| Condition message | Cause | Fix |
|---|---|---|
| `no subnets found` | Missing `karpenter.sh/discovery` tag on subnets | Re-run Step 10 subnet tagging |
| `no security groups found` | Missing tag on cluster SG | Re-run Step 10 SG tagging |
| `failed to resolve AMI ... ssm timeout` | SSM VPC endpoint missing or not yet available | Wait for endpoint to reach `available`, verify Step 3 |

### Nodes launch but never join the cluster

Check the node bootstrap logs via SSM Session Manager (since you have no SSH in private cluster):

```bash
aws ssm start-session --target <instance-id>
# Then inside the session:
journalctl -u kubelet -n 100
```

Common causes:

- Missing `AmazonEKSWorkerNodePolicy` on the node role (Step 6) — node calls `ec2:DescribeInstances` at bootstrap; 403 here causes a silent loop
- Node role not mapped in `aws-auth` (Step 11) — node tries to authenticate but is rejected by the API server
- `eks:DescribeCluster` not in controller policy — Karpenter cannot look up the cluster endpoint to embed in bootstrap config

### `isolatedVPC` not set — pricing timeout errors

If you see repeated errors like:

```
ERROR  controller.aws.pricing  updating on-demand pricing ... dial tcp ... api.pricing.us-east-1.amazonaws.com ... i/o timeout
```

Add `--set settings.isolatedVPC=true` to the Helm command and upgrade:

```bash
helm upgrade karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace "${KARPENTER_NAMESPACE}" \
  --reuse-values \
  --set "settings.isolatedVPC=true"
```

---

## Cleanup

```bash
kubectl delete deployment inflate
kubectl delete nodepool default
kubectl delete ec2nodeclass default
helm uninstall karpenter --namespace "${KARPENTER_NAMESPACE}"
aws iam detach-role-policy --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
  --policy-arn "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
aws iam detach-role-policy --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
  --policy-arn "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
aws iam detach-role-policy --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
  --policy-arn "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
aws iam detach-role-policy --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
  --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
aws iam remove-role-from-instance-profile \
  --instance-profile-name "KarpenterNodeInstanceProfile-${CLUSTER_NAME}" \
  --role-name "KarpenterNodeRole-${CLUSTER_NAME}"
aws iam delete-instance-profile \
  --instance-profile-name "KarpenterNodeInstanceProfile-${CLUSTER_NAME}"
aws iam delete-role-policy \
  --role-name "KarpenterControllerRole-${CLUSTER_NAME}" \
  --policy-name "KarpenterControllerPolicy-${CLUSTER_NAME}"
aws iam delete-role --role-name "KarpenterNodeRole-${CLUSTER_NAME}"
aws iam delete-role --role-name "KarpenterControllerRole-${CLUSTER_NAME}"
```