# Karpenter v0.37.0 Setup on EKS — Complete Working Guide

Tested on EKS v1.35, ap-south-1, single-node cluster (t2.small), Git Bash (MINGW64)

---

## Prerequisites

- EKS cluster running and accessible via kubectl
- AWS CLI installed and configured
- eksctl installed
- helm installed

---

## Step 1 — Configure AWS CLI & kubeconfig

```bash
aws configure
```

```bash
aws eks update-kubeconfig --region ap-south-1 --name <your-cluster-name>
```

---

## Step 2 — Export Environment Variables

```bash
export CLUSTER_NAME="karpenter"
export AWS_REGION="$(aws configure get region)"
export AWS_PARTITION="aws"
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query 'Account' --output text)"
export CLUSTER_ENDPOINT="$(aws eks describe-cluster --name $CLUSTER_NAME \
  --query "cluster.endpoint" --output text)"
export OIDC_ENDPOINT="$(aws eks describe-cluster --name $CLUSTER_NAME \
  --query "cluster.identity.oidc.issuer" --output text)"
export KARPENTER_VERSION="0.37.0"
export KARPENTER_NAMESPACE="kube-system"
```

---

## Step 3 — Create IAM OIDC Provider

```bash
eksctl utils associate-iam-oidc-provider \
  --cluster $CLUSTER_NAME \
  --approve
```

---

## Step 4 — Create KarpenterNodeRole

```bash
cat > node-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF
```

```bash
aws iam create-role \
  --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
  --assume-role-policy-document file://node-trust-policy.json
```

---

## Step 5 — Attach Required Node Policies

```bash
for policy in AmazonEKSWorkerNodePolicy AmazonEKS_CNI_Policy \
              AmazonEC2ContainerRegistryReadOnly AmazonSSMManagedInstanceCore; do
  aws iam attach-role-policy \
    --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
    --policy-arn "arn:${AWS_PARTITION}:iam::aws:policy/${policy}"
done
```

---

## Step 6 — Add Required Node Extra Permissions (Critical Fix)

```bash
cat > node-extra-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeRouteTables",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSubnets",
        "ec2:DescribeVolumes",
        "ec2:DescribeVolumesModifications",
        "ec2:DescribeVpcs",
        "eks:DescribeCluster",
        "eks-auth:AssumeRoleForPodIdentity"
      ],
      "Resource": "*"
    }
  ]
}
EOF
```

```bash
aws iam put-role-policy \
  --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
  --policy-name "KarpenterNodeExtraPolicy" \
  --policy-document file://node-extra-policy.json
```

---

## Step 7 — Create Instance Profile

```bash
aws iam create-instance-profile \
  --instance-profile-name "KarpenterNodeInstanceProfile-${CLUSTER_NAME}"
```

```bash
aws iam add-role-to-instance-profile \
  --instance-profile-name "KarpenterNodeInstanceProfile-${CLUSTER_NAME}" \
  --role-name "KarpenterNodeRole-${CLUSTER_NAME}"
```

---

## Step 8 — Create KarpenterControllerRole

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
```

```bash
aws iam create-role \
  --role-name "KarpenterControllerRole-${CLUSTER_NAME}" \
  --assume-role-policy-document file://controller-trust-policy.json
```

---

## Step 9 — Attach Controller Policy

```bash
envsubst < controller-policy.json > controller-policy-final.json
```

```bash
aws iam put-role-policy \
  --role-name "KarpenterControllerRole-${CLUSTER_NAME}" \
  --policy-name "KarpenterControllerPolicy-${CLUSTER_NAME}" \
  --policy-document file://controller-policy-final.json
```

---

## Step 10 — Tag Subnets & Security Group

```bash
for NG in $(aws eks list-nodegroups --cluster-name $CLUSTER_NAME \
  --query 'nodegroups' --output text); do
  aws ec2 create-tags \
    --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" \
    --resources $(aws eks describe-nodegroup \
      --cluster-name $CLUSTER_NAME \
      --nodegroup-name $NG \
      --query 'nodegroup.subnets' --output text)
done
```

```bash
SG=$(aws eks describe-cluster --name $CLUSTER_NAME \
  --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)
```

```bash
aws ec2 create-tags \
  --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" \
  --resources $SG
```

---

## Step 11 — Map Node Role

```bash
eksctl create iamidentitymapping \
  --username system:node:{{EC2PrivateDNSName}} \
  --cluster $CLUSTER_NAME \
  --arn "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}" \
  --group system:bootstrappers \
  --group system:nodes
```

---

## Step 12 — Install Karpenter

```bash
helm upgrade --install karpenter-crd \
  oci://public.ecr.aws/karpenter/karpenter-crd \
  --version "${KARPENTER_VERSION}" \
  --namespace "${KARPENTER_NAMESPACE}" \
  --create-namespace
```

```bash
helm upgrade --install karpenter \
  oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace "${KARPENTER_NAMESPACE}" \
  --create-namespace \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.clusterEndpoint=${CLUSTER_ENDPOINT}" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterControllerRole-${CLUSTER_NAME}" \
  --set controller.resources.requests.cpu=100m \
  --set controller.resources.requests.memory=256Mi \
  --set controller.resources.limits.cpu=200m \
  --set controller.resources.limits.memory=256Mi \
  --set replicas=1
```

---

## Step 13 — Create EC2NodeClass

```bash
cat > ec2nodeclass.yaml << 'EOF'
apiVersion: karpenter.k8s.aws/v1beta1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2023
  instanceProfile: "KarpenterNodeInstanceProfile-karpenter"
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "karpenter"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "karpenter"
  tags:
    managed-by: karpenter
    cluster: "karpenter"
EOF
```

```bash
kubectl apply -f ec2nodeclass.yaml
```

---

## Step 14 — Create NodePool

```bash
cat > nodepool.yaml << 'EOF'
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      nodeClassRef:
        apiVersion: karpenter.k8s.aws/v1beta1
        kind: EC2NodeClass
        name: default
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
  disruption:
    consolidationPolicy: WhenUnderutilized
EOF
```

```bash
kubectl apply -f nodepool.yaml
```

---

## Step 15 — Test Autoscaling

```bash
cat > inflate.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inflate
spec:
  replicas: 1
  selector:
    matchLabels:
      app: inflate
  template:
    metadata:
      labels:
        app: inflate
    spec:
      containers:
        - name: inflate
          image: public.ecr.aws/eks-distro/kubernetes/pause:3.7
          resources:
            requests:
              cpu: "1"
EOF
```

```bash
kubectl apply -f inflate.yaml
```

```bash
kubectl scale deployment inflate --replicas 5
```

```bash
kubectl get nodes -w
```

---

## Expected Result

- Karpenter launches EC2 instances
- Nodes join the cluster successfully
- Pods transition from Pending to Running