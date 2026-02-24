# cluster-node-upgradation

## cluster upgradation

EKS cluster upgrades follow a strict rule — the control plane must always be upgraded before node groups, and you can only upgrade one minor version at a time. Skipping versions is not supported. The upgrade is triggered via the AWS CLI using `aws eks update-cluster-version` and you monitor it until the cluster status returns to `ACTIVE` before touching the nodes.

---

## node upgradation

### managed node upgradation

If your node group is a managed node group, AWS handles cordon, drain, and replacement automatically in a rolling fashion — one node at a time with no downtime as long as your pods have multiple replicas.

However if you used a custom AMI (amiType = `CUSTOM`), you must manually update the Launch Template with the new AMI before triggering the update. Only the `ImageId` changes in the launch template — instance type, UserData bootstrap script, and all other config is copied from the previous version using `--source-version`. Once the new launch template version is created, you trigger the node group update pointing to that new version and AWS handles the rest.

#### PodDisruptionBudget failure — Istio

Istio system pods (`istiod`, `istio-ingressgateway`, `istio-egressgateway`) have PodDisruptionBudgets with `minAvailable=1`. If they only have 1 replica, the drain gets blocked because evicting the only replica would violate the PDB. After the 15 minute default drain timeout the update fails with:

```
"errorCode": "PodEvictionFailure"
"errorMessage": "Reached max retries while trying to evict pods from nodes in node group"
```

When this happens the update status goes to `Failed` and the old node stays alive but stuck in `SchedulingDisabled`. The fix is to manually delete the blocking Istio pods so they reschedule onto the already-upgraded node, then re-trigger the node group update.

To avoid this entirely, always scale Istio components to 2 replicas before triggering any node upgrade. With 2 replicas spread across both nodes, one pod evicts gracefully while the other keeps serving — the PDB is satisfied and the drain completes cleanly:

```bash
kubectl scale deployment istiod -n istio-system --replicas=2
kubectl scale deployment istio-ingressgateway -n istio-system --replicas=2
kubectl scale deployment istio-egressgateway -n istio-system --replicas=2
```

### unmanaged node upgradation

For self-managed node groups the process is fully manual. You launch a new node group with the upgraded AMI, cordon and drain the old nodes so pods reschedule onto the new ones, verify everything is running, then delete the old node group.

---

## node-cluster version mismatch (my scenario)

In this setup the control plane was already at 1.33 but the node group was on 1.29 — a 4 minor version gap. Kubernetes enforces a strict skew policy where nodes cannot be more than 2 minor versions behind the control plane, and you cannot skip versions when upgrading.

Since the control plane was already ahead, it did not need to be touched at all. The only task was upgrading the nodes one minor version at a time until they caught up:

```
1.29 → 1.30 → 1.31 → 1.32 → 1.33
```

For each hop the same pattern repeats — find the Ubuntu EKS AMI for the target version using Canonical's official AWS account, create a new launch template version swapping only the ImageId, then trigger the node group update pointing to that new launch template version.

It is also worth noting that the version number (e.g. `v1.30.14`) has three parts — major, minor, and patch. The skew policy only checks the minor version. Nodes on `1.30.10` and `1.30.14` are treated identically.