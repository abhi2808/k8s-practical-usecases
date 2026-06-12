# EKS NLB Restriction via Validating Admission Policy

## Overview

This document describes the design, investigation, and implementation of a solution to prevent application developer teams from creating Network Load Balancers (NLBs) directly through Kubernetes, while allowing platform/infrastructure teams to retain full access.

---

## Problem Statement

In a multi-tenant EKS cluster, multiple application teams share a single cluster, isolated via namespaces. Each team has RBAC scoped to their own namespace. The requirement is:

> **Prevent developer/application-owner users from creating `Service` resources of type `LoadBalancer` (which trigger NLB provisioning), while allowing platform engineers to continue creating them as needed — including inside application namespaces.**

---

## Why This Is Not an IAM Problem

When a user creates a `Service` of type `LoadBalancer` in Kubernetes:

```
User creates Service (type: LoadBalancer)
        ↓
AWS Load Balancer Controller (running in-cluster)
        ↓
Calls AWS API using its own IAM role
        ↓
NLB is provisioned
```

The **user never directly calls AWS APIs**. The controller does. Therefore:

- Removing AWS permissions from the user has **no effect**
- The restriction must happen at the **Kubernetes API layer**, not AWS IAM

---

## Why RBAC Alone Is Not Sufficient

Kubernetes RBAC can control:

```yaml
resources: ["services"]
verbs: ["create"]
```

But RBAC **cannot inspect object contents**. It cannot distinguish:

```yaml
spec:
  type: ClusterIP   # RBAC sees: service/create
```

from:

```yaml
spec:
  type: LoadBalancer  # RBAC sees: service/create  ← same thing
```

Since application teams legitimately need to create `ClusterIP` and `NodePort` services, denying all `Service` creation is not viable. An **Admission Controller** is required.

---

## Architecture

```
EKS Cluster
│
├── Namespace: app-team-1       ← app-team-1-developers (scoped here via RBAC)
├── Namespace: app-team-2       ← app-team-2-developers (scoped here via RBAC)
├── Namespace: app-team-N       ← app-team-N-developers (scoped here via RBAC)
│
├── Namespace: platform-infra   ← platform team owned (LoadBalancers live here)
├── Namespace: kube-system
│
├── RBAC
│    ├── Role + RoleBinding per namespace per team
│    └── ClusterRoleBinding for platform/admin groups
│
├── AWS Load Balancer Controller
│
└── Validating Admission Policy  ← THIS SOLUTION
```

### Authentication Flow (aws-auth / Access Entries)

```
IAM Role
    ↓
aws-auth ConfigMap  (or EKS Access Entries)
    ↓
Kubernetes Group string injected into user token
    ↓
e.g. "app-team-1-developers", "platform-engineers"
    ↓
RBAC RoleBinding subjects match on Group name
```

> **Important:** Kubernetes Groups are not stored objects. They are string claims attached to authenticated users. There is no `kind: Group` resource.

---

## Solution: Validating Admission Policy (VAP)

### Why VAP

| Option | Pros | Cons |
|---|---|---|
| Kyverno | Easy syntax, rich reporting | Extra controller, webhook, maintenance |
| OPA Gatekeeper | Very powerful | Rego learning curve, complexity |
| **VAP (Native)** | **Zero install, built into k8s 1.26+** | CEL expressions (simple to learn) |

VAP is the recommended approach for this use case — no additional controllers, no webhooks to maintain, audit-friendly.

**Requires Kubernetes 1.26+ (beta) or 1.28+ (stable/GA).**

---

## Design Decision: Group-Based vs Namespace-Based

### Option A — Namespace-Based Gate
```
DENY LoadBalancer in app namespaces for EVERYONE
```
❌ Blocks platform engineers from creating LBs inside app namespaces when needed.

### Option B — Group-Based Gate
```
DENY LoadBalancer for anyone whose group ends with "-developers"
```
✅ Platform engineers pass through regardless of namespace.
✅ Any future group ending in `-developers` is automatically covered.
✅ No policy update needed when new app teams are onboarded (just follow naming convention).

**Group-based is the correct approach** because the requirement is about **WHO**, not **WHERE**.

---

## Pre-Implementation Investigation

Before applying any policy, run the following discovery commands on the target cluster:

```bash
# 1. Check your current identity
kubectl auth whoami

# 2. Check AWS identity
aws sts get-caller-identity

# 3. All Groups in ClusterRoleBindings
kubectl get clusterrolebindings -o json | \
jq -r '
.items[] |
select(.subjects!=null) |
.metadata.name as $binding |
.roleRef.name as $role |
.subjects[] |
select(.kind=="Group") |
"\(.name) -> \($role) [binding: \($binding)]"
' | sort -u

# 4. All Groups in namespace RoleBindings
kubectl get rolebindings -A -o json | \
jq -r '
.items[] |
select(.subjects!=null) |
.metadata.namespace as $ns |
.metadata.name as $binding |
.roleRef.name as $role |
.subjects[] |
select(.kind=="Group") |
"\($ns) | \(.name) -> \($role) [binding: \($binding)]"
' | sort -u

# 5. aws-auth ConfigMap
kubectl get configmap aws-auth -n kube-system -o yaml

# 6. All namespaces
kubectl get namespaces

# 7. Existing LoadBalancer services (critical — check before applying policy)
kubectl get svc -A | grep LoadBalancer

# 8. Check if Kyverno is installed
kubectl get pods -n kyverno

# 9. Check if VAP is supported
kubectl get validatingadmissionpolicies 2>/dev/null && echo "VAP Supported" || echo "VAP Not Supported"

# 10. Check existing admission webhooks
kubectl get validatingwebhookconfigurations
kubectl get mutatingwebhookconfigurations

# 11. Check EKS Access Entries (modern EKS auth)
aws eks list-access-entries --cluster-name <CLUSTER-NAME> --output table
```

> **Always check command 7 (existing LoadBalancer services) before applying the policy.** VAP `Enforce` mode blocks new creations but does not affect existing resources. However, knowing what exists helps assess risk and inform application teams.

---

## Implementation

### Step 1 — Verify VAP Support

```bash
kubectl get validatingadmissionpolicies 2>/dev/null && echo "VAP Supported" || echo "VAP Not Supported"
kubectl version
```

### Step 2 — Apply the Policy

Save as `deny-lb-developers.yaml`:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: deny-loadbalancer-developers
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["services"]
  validations:
    - expression: >
        !(object.spec.type == "LoadBalancer" &&
        request.userInfo.groups.exists(g, g.endsWith("-developers")))
      message: >
        ERROR: Developer groups are not permitted to create LoadBalancer
        Services. Please contact your platform team to provision NLBs centrally.
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: deny-loadbalancer-developers-binding
spec:
  policyName: deny-loadbalancer-developers
  validationActions: [Deny]
  matchResources: {}
```

```bash
kubectl apply -f deny-lb-developers.yaml
```

### Step 3 — Verify

```bash
kubectl get validatingadmissionpolicies
kubectl get validatingadmissionpolicybindings
kubectl describe validatingadmissionpolicy deny-loadbalancer-developers
```

---

## How The Policy Works

```
Any user attempts: kubectl apply Service (type: LoadBalancer)
                                    ↓
                          Kubernetes API Server
                                    ↓
                    ValidatingAdmissionPolicy evaluates:
                                    ↓
        Does request.userInfo.groups contain any string ending in "-developers"?
                        ↓                          ↓
                       YES                         NO
                        ↓                          ↓
                   DENY request               ALLOW request
         (error message shown to user)    (Service created normally)
```

---

## Coverage Matrix

| User Group | Service Type | Namespace | Result |
|---|---|---|---|
| `app-team-developers` | LoadBalancer | app namespace | ✅ DENIED |
| `app-team-developers` | LoadBalancer | any namespace | ✅ DENIED |
| `app-team-developers` | ClusterIP | app namespace | ✅ ALLOWED |
| `app-team-developers` | NodePort | app namespace | ✅ ALLOWED |
| `platform-engineers` | LoadBalancer | app namespace | ✅ ALLOWED |
| `platform-engineers` | LoadBalancer | platform namespace | ✅ ALLOWED |
| any future `*-developers` group | LoadBalancer | anywhere | ✅ DENIED (auto) |

---

## Group Naming Convention (Required)

This solution relies on a consistent group naming convention:

```
Application developer groups  →  must end with "-developers"
                                  e.g. app-team-1-developers
                                       payments-developers
                                       frontend-developers

Platform / admin groups       →  must NOT end with "-developers"
                                  e.g. platform-engineers
                                       infra-admins
                                       sre-team
```

> **This convention must be enforced when onboarding new teams** via aws-auth or EKS Access Entries. If a platform engineer is accidentally assigned to a `*-developers` group, they will be blocked.

---

## POC / Testing Guide

Use this to validate the policy before applying to production.

### Setup

```bash
# 1. Create test namespaces
kubectl create namespace poc-appteam

# 2. Create RBAC
cat > poc-rbac.yaml << 'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: poc-developer-role
  namespace: poc-appteam
rules:
  - apiGroups: ["", "apps"]
    resources: ["pods", "services", "deployments"]
    verbs: ["get", "list", "create", "update", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: poc-developer-rb
  namespace: poc-appteam
subjects:
  - kind: Group
    name: poc-developers
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: poc-developer-role
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: poc-platform-role
  namespace: poc-appteam
rules:
  - apiGroups: ["", "apps"]
    resources: ["pods", "services", "deployments"]
    verbs: ["get", "list", "create", "update", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: poc-platform-rb
  namespace: poc-appteam
subjects:
  - kind: Group
    name: poc-platform
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: poc-platform-role
  apiGroup: rbac.authorization.k8s.io
EOF
kubectl apply -f poc-rbac.yaml

# 3. Create two IAM roles (one per test persona)
aws iam create-role \
  --role-name poc-developer-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{"Effect": "Allow","Principal": {"AWS": "arn:aws:iam::<ACCOUNT-ID>:root"},"Action": "sts:AssumeRole"}]
  }'

aws iam create-role \
  --role-name poc-platform-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{"Effect": "Allow","Principal": {"AWS": "arn:aws:iam::<ACCOUNT-ID>:root"},"Action": "sts:AssumeRole"}]
  }'

# 4. Map IAM roles to Kubernetes groups in aws-auth
# Add the following under mapRoles in:
# kubectl edit configmap aws-auth -n kube-system
#
#    - groups:
#      - poc-developers
#      rolearn: arn:aws:iam::<ACCOUNT-ID>:role/poc-developer-role
#      username: poc-developer
#    - groups:
#      - poc-platform
#      rolearn: arn:aws:iam::<ACCOUNT-ID>:role/poc-platform-role
#      username: poc-platform

# 5. Deploy a test workload
kubectl create deployment poc-test-app \
  --image=nginx:latest \
  --namespace=poc-appteam

# 6. Apply the VAP policy
kubectl apply -f deny-lb-developers.yaml
```

### Test As Developer (Expect DENY)

```bash
aws eks update-kubeconfig \
  --region <REGION> \
  --name <CLUSTER-NAME> \
  --role-arn arn:aws:iam::<ACCOUNT-ID>:role/poc-developer-role

kubectl auth whoami
# Groups should show: [poc-developers system:authenticated]

# This should FAIL
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: test-lb
  namespace: poc-appteam
spec:
  selector:
    app: poc-test-app
  ports:
    - port: 80
  type: LoadBalancer
EOF

# This should PASS
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: test-clusterip
  namespace: poc-appteam
spec:
  selector:
    app: poc-test-app
  ports:
    - port: 80
  type: ClusterIP
EOF
```

### Test As Platform Engineer (Expect ALLOW)

```bash
aws eks update-kubeconfig \
  --region <REGION> \
  --name <CLUSTER-NAME> \
  --role-arn arn:aws:iam::<ACCOUNT-ID>:role/poc-platform-role

kubectl auth whoami
# Groups should show: [poc-platform system:authenticated]

# This should PASS
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: test-lb-platform
  namespace: poc-appteam
spec:
  selector:
    app: poc-test-app
  ports:
    - port: 80
  type: LoadBalancer
EOF
```

### Cleanup After POC

```bash
kubectl delete namespace poc-appteam
kubectl delete validatingadmissionpolicy deny-loadbalancer-developers
kubectl delete validatingadmissionpolicybinding deny-loadbalancer-developers-binding
aws iam delete-role --role-name poc-developer-role
aws iam delete-role --role-name poc-platform-role
```

---

## Rollback

If the policy needs to be removed quickly:

```bash
kubectl delete validatingadmissionpolicybinding deny-loadbalancer-developers-binding
kubectl delete validatingadmissionpolicy deny-loadbalancer-developers
```

> Deleting the **binding** alone is sufficient to immediately stop enforcement. The policy object can be cleaned up separately.

---

## Operational Notes

| Topic | Note |
|---|---|
| Existing LBs | Policy only affects new CREATE/UPDATE requests. Existing LoadBalancer services are unaffected. |
| New teams | As long as group name ends with `-developers`, policy applies automatically. No policy update needed. |
| Platform access | Platform engineers must be in a group that does NOT end with `-developers`. |
| Audit | `kubectl describe validatingadmissionpolicy deny-loadbalancer-developers` shows policy state. |
| Performance | VAP runs natively in the API server. No webhook latency. No external controller. |
| Kubernetes version | Requires 1.26+ (beta) or 1.28+ (stable). Verify with `kubectl get validatingadmissionpolicies`. |

---

## Alternative: Kyverno Policy

If Kyverno is preferred or already installed:

```bash
# Install Kyverno
kubectl apply -f https://github.com/kyverno/kyverno/releases/latest/download/install.yaml
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=kyverno -n kyverno --timeout=120s
```

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: deny-loadbalancer-developers
  annotations:
    policies.kyverno.io/title: Deny LoadBalancer Services for Developer Groups
    policies.kyverno.io/category: Network Security
    policies.kyverno.io/severity: high
    policies.kyverno.io/description: >
      Prevents groups ending in -developers from creating LoadBalancer
      type Services anywhere in the cluster.
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: deny-lb-for-developers
      match:
        any:
          - resources:
              kinds:
                - Service
      preconditions:
        any:
          - key: "{{ request.userInfo.groups[] | contains(@, '-developers') }}"
            operator: Equals
            value: true
      validate:
        message: >
          ERROR: Developer groups are not permitted to create LoadBalancer
          Services. Please contact your platform team.
        deny:
          conditions:
            any:
              - key: "{{ request.object.spec.type }}"
                operator: Equals
                value: LoadBalancer
```

---

## Summary

```
Problem   →  Developers creating NLBs directly via Service type=LoadBalancer

Root Cause →  RBAC cannot inspect object spec fields
              IAM restriction ineffective (controller creates NLB, not user)

Solution  →  Validating Admission Policy (native Kubernetes, zero install)
             Block LoadBalancer creation for any group ending in "-developers"

Result    →  Developers: ClusterIP ✅  NodePort ✅  LoadBalancer ❌
             Platform:   ClusterIP ✅  NodePort ✅  LoadBalancer ✅

Changes   →  Zero RBAC changes
             Zero IAM changes
             Zero namespace changes
             One YAML file applied
             Easy rollback (delete binding)
```
