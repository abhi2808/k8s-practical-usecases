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


# implementation

AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ aws eks list-nodegroups \
  --cluster-name abhinav-istio-mesh \
  --region ap-south-1
{
    "nodegroups": [
        "ubuntu-nodes"
    ]
}


AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ aws eks describe-nodegroup \
  --cluster-name abhinav-istio-mesh \
  --nodegroup-name ubuntu-nodes \
  --region ap-south-1 \
  --query 'nodegroup.{amiType:amiType, releaseVersion:releaseVersion, version:version}'
{
    "amiType": "CUSTOM",
    "releaseVersion": "ami-0e7ed84d60938cb36",
    "version": "1.29"
}

AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ # Search for Ubuntu EKS AMIs for 1.30 in ap-south-1
aws ec2 describe-images \
  --region ap-south-1 \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu-eks/k8s_1.30/images/*" \
  --query 'sort_by(Images, &CreationDate)[-1].{ID:ImageId, Name:Name, Created:CreationDate}' \
  --output table
--------------------------------------------------------------------------------------------
|                                      DescribeImages                                      |
+---------+--------------------------------------------------------------------------------+
|  Created|  2025-11-24T19:14:58.000Z                                                      |
|  ID     |  ami-030f678d59f2c44ad                                                         |
|  Name   |  ubuntu-eks/k8s_1.30/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-20251124   |
+---------+--------------------------------------------------------------------------------+


AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ aws eks describe-nodegroup \
  --cluster-name abhinav-istio-mesh \
  --nodegroup-name ubuntu-nodes \
  --region ap-south-1 \
  --query 'nodegroup.launchTemplate'
{
    "name": "eks-ubuntu-lt",
    "version": "3",
    "id": "lt-09696041f02b6470e"
}


AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ aws ec2 describe-images \
  --region ap-south-1 \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu-eks/k8s_1.30/images/*amd64*" \
  --query 'sort_by(Images, &CreationDate)[-1].{ID:ImageId, Name:Name, Created:CreationDate}' \
  --output table
--------------------------------------------------------------------------------------------
|                                      DescribeImages                                      |
+---------+--------------------------------------------------------------------------------+
|  Created|  2025-11-24T19:14:05.000Z                                                      |
|  ID     |  ami-0ccfe3471866ac85f                                                         |
|  Name   |  ubuntu-eks/k8s_1.30/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-20251124   |
+---------+--------------------------------------------------------------------------------+


AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ aws ec2 create-launch-template-version \
  --launch-template-id lt-09696041f02b6470e \
  --source-version 3 \
  --launch-template-data '{"ImageId":"ami-0ccfe3471866ac85f"}'
{
    "LaunchTemplateVersion": {
        "LaunchTemplateId": "lt-09696041f02b6470e",
        "LaunchTemplateName": "eks-ubuntu-lt",
        "VersionNumber": 4,
        "CreateTime": "2026-02-24T13:59:56+00:00",
        "CreatedBy": "arn:aws:iam::183295435445:user/priyesh.rai@minfytech.com",
        "DefaultVersion": false,
        "LaunchTemplateData": {
            "BlockDeviceMappings": [
                {
                    "DeviceName": "/dev/sda1",
                    "Ebs": {
                        "DeleteOnTermination": true,
                        "VolumeSize": 20,
                        "VolumeType": "gp3"
                    }
                }
            ],
            "ImageId": "ami-0ccfe3471866ac85f",
            "InstanceType": "t2.small",
            "UserData": "IyEvYmluL2Jhc2gKc2V0IC1leAojIEZpeCBmb3IgRklQUyBjaGVjayBpc3N1ZSBvbiBVYnVudHUgMjIuMDQKZWNobyAwID4gL3Byb2Mvc3lzL2NyeXB0by9maXBzX2VuYWJsZWQgMj4vZGV2L251bGwgfHwgdHJ1ZQovZXRjL2Vrcy9ib290c3RyYXAuc2ggYWJoaW5hdi1pc3Rpby1tZXNoIFwKICAtLXVzZS1tYXgtcG9kcyBmYWxzZSBcCiAgLS1rdWJlbGV0LWV4dHJhLWFyZ3MgJy0tbm9kZS1sYWJlbHM9ZWtzLmFtYXpvbmF3cy5jb20vbm9kZWdyb3VwPXVidW50dS1ub2RlcycK",
            "MetadataOptions": {
                "HttpTokens": "required",
                "HttpPutResponseHopLimit": 2,
                "HttpEndpoint": "enabled"
            }
        },
        "Operator": {
            "Managed": false
        }
    }
}


AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ aws eks update-nodegroup-version \
  --cluster-name abhinav-istio-mesh \
  --nodegroup-name ubuntu-nodes \
  --region ap-south-1 \
  --launch-template version=4,id=lt-09696041f02b6470e
{
    "update": {
        "id": "7d40b91f-539c-3116-956b-03ac126b628f",
        "status": "InProgress",
        "type": "VersionUpdate",
        "params": [
            {
                "type": "LaunchTemplateName",
                "value": "eks-ubuntu-lt"
            },
            {
                "type": "LaunchTemplateVersion",
                "value": "4"
            }
        ],
        "createdAt": "2026-02-24T19:32:16.730000+05:30",
        "errors": []
    }
}


AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ # Watch node status
kubectl get nodes -w
NAME                                           STATUS   ROLES    AGE   VERSION
ip-172-31-142-47.ap-south-1.compute.internal   Ready    <none>   25h   v1.29.15
ip-172-31-150-90.ap-south-1.compute.internal   Ready    <none>   25h   v1.29.15
ip-172-31-142-47.ap-south-1.compute.internal   Ready    <none>   25h   v1.29.15
ip-172-31-143-0.ap-south-1.compute.internal    NotReady   <none>   0s    v1.30.14
ip-172-31-143-0.ap-south-1.compute.internal    NotReady   <none>   0s    v1.30.14
ip-172-31-143-0.ap-south-1.compute.internal    NotReady   <none>   0s    v1.30.14
ip-172-31-143-0.ap-south-1.compute.internal    NotReady   <none>   0s    v1.30.14
ip-172-31-143-0.ap-south-1.compute.internal    NotReady   <none>   0s    v1.30.14
ip-172-31-143-0.ap-south-1.compute.internal    NotReady   <none>   1s    v1.30.14
ip-172-31-143-0.ap-south-1.compute.internal    NotReady   <none>   1s    v1.30.14
ip-172-31-143-0.ap-south-1.compute.internal    NotReady   <none>   5s    v1.30.14
ip-172-31-157-108.ap-south-1.compute.internal   NotReady   <none>   0s    v1.30.14
ip-172-31-157-108.ap-south-1.compute.internal   NotReady   <none>   0s    v1.30.14
ip-172-31-157-108.ap-south-1.compute.internal   NotReady   <none>   0s    v1.30.14
ip-172-31-157-108.ap-south-1.compute.internal   NotReady   <none>   0s    v1.30.14
ip-172-31-157-108.ap-south-1.compute.internal   NotReady   <none>   0s    v1.30.14
ip-172-31-157-108.ap-south-1.compute.internal   NotReady   <none>   0s    v1.30.14
ip-172-31-143-0.ap-south-1.compute.internal     NotReady   <none>   10s   v1.30.14
ip-172-31-143-0.ap-south-1.compute.internal     NotReady   <none>   10s   v1.30.14
ip-172-31-157-108.ap-south-1.compute.internal   NotReady   <none>   1s    v1.30.14
ip-172-31-157-108.ap-south-1.compute.internal   NotReady   <none>   1s    v1.30.14
ip-172-31-157-108.ap-south-1.compute.internal   NotReady   <none>   1s    v1.30.14
ip-172-31-143-0.ap-south-1.compute.internal     NotReady   <none>   11s   v1.30.14
ip-172-31-143-0.ap-south-1.compute.internal     Ready      <none>   18s   v1.30.14
ip-172-31-143-0.ap-south-1.compute.internal     Ready      <none>   18s   v1.30.14
ip-172-31-157-108.ap-south-1.compute.internal   NotReady   <none>   10s   v1.30.14
ip-172-31-143-0.ap-south-1.compute.internal     Ready      <none>   20s   v1.30.14
ip-172-31-157-108.ap-south-1.compute.internal   Ready      <none>   20s   v1.30.14
ip-172-31-157-108.ap-south-1.compute.internal   Ready      <none>   20s   v1.30.14
ip-172-31-157-108.ap-south-1.compute.internal   Ready      <none>   21s   v1.30.14
ip-172-31-143-0.ap-south-1.compute.internal     Ready      <none>   31s   v1.30.14
ip-172-31-157-108.ap-south-1.compute.internal   Ready      <none>   31s   v1.30.14
ip-172-31-150-90.ap-south-1.compute.internal    Ready,SchedulingDisabled   <none>   25h   v1.29.15
ip-172-31-150-90.ap-south-1.compute.internal    Ready,SchedulingDisabled   <none>   25h   v1.29.15
ip-172-31-142-47.ap-south-1.compute.internal    Ready,SchedulingDisabled   <none>   25h   v1.29.15
ip-172-31-142-47.ap-south-1.compute.internal    Ready,SchedulingDisabled   <none>   25h   v1.29.15
ip-172-31-150-90.ap-south-1.compute.internal    Ready,SchedulingDisabled   <none>   25h   v1.29.15
ip-172-31-150-90.ap-south-1.compute.internal    Ready,SchedulingDisabled   <none>   25h   v1.29.15
ip-172-31-143-0.ap-south-1.compute.internal     Ready                      <none>   2m33s   v1.30.14
ip-172-31-157-108.ap-south-1.compute.internal   Ready                      <none>   2m33s   v1.30.14


AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl get nodes
NAME                                            STATUS                     ROLES    AGE     VERSION
ip-172-31-142-47.ap-south-1.compute.internal    Ready,SchedulingDisabled   <none>   25h     v1.29.15
ip-172-31-143-0.ap-south-1.compute.internal     Ready                      <none>   3m19s   v1.30.14
ip-172-31-150-90.ap-south-1.compute.internal    Ready,SchedulingDisabled   <none>   25h     v1.29.15
ip-172-31-157-108.ap-south-1.compute.internal   Ready                      <none>   3m10s   v1.30.14

AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl get nodes
NAME                                            STATUS                     ROLES    AGE     VERSION
ip-172-31-142-47.ap-south-1.compute.internal    Ready,SchedulingDisabled   <none>   25h     v1.29.15
ip-172-31-143-0.ap-south-1.compute.internal     Ready                      <none>   7m      v1.30.14
ip-172-31-157-108.ap-south-1.compute.internal   Ready                      <none>   6m51s   v1.30.14

AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl get nodes
NAME                                            STATUS                     ROLES    AGE   VERSION
ip-172-31-142-47.ap-south-1.compute.internal    Ready,SchedulingDisabled   <none>   25h   v1.29.15
ip-172-31-143-0.ap-south-1.compute.internal     Ready                      <none>   10m   v1.30.14
ip-172-31-157-108.ap-south-1.compute.internal   Ready                      <none>   10m   v1.30.14

AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl get nodes
NAME                                            STATUS                     ROLES    AGE   VERSION
ip-172-31-142-47.ap-south-1.compute.internal    Ready,SchedulingDisabled   <none>   25h   v1.29.15
ip-172-31-143-0.ap-south-1.compute.internal     Ready                      <none>   16m   v1.30.14
ip-172-31-157-108.ap-south-1.compute.internal   Ready                      <none>   16m   v1.30.14

AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl get nodes
NAME                                            STATUS                     ROLES    AGE   VERSION
ip-172-31-142-47.ap-south-1.compute.internal    Ready,SchedulingDisabled   <none>   25h   v1.29.15
ip-172-31-143-0.ap-south-1.compute.internal     Ready                      <none>   21m   v1.30.14
ip-172-31-157-108.ap-south-1.compute.internal   Ready                      <none>   21m   v1.30.14

AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl get nodes
NAME                                            STATUS                     ROLES    AGE   VERSION
ip-172-31-142-47.ap-south-1.compute.internal    Ready,SchedulingDisabled   <none>   25h   v1.29.15
ip-172-31-143-0.ap-south-1.compute.internal     Ready                      <none>   25m   v1.30.14
ip-172-31-157-108.ap-south-1.compute.internal   Ready                      <none>   25m   v1.30.14

AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl get pods --all-namespaces -o wide | grep ip-172-31-142-47
istio-system   istio-egressgateway-5868fcbc58-5xjfq    1/1     Running   0             25h   172.31.143.231   ip-172-31-142-47.ap-south-1.compute.internal    <none>           <none>
istio-system   istio-ingressgateway-5896f57fbb-sdskg   1/1     Running   0             25h   172.31.137.161   ip-172-31-142-47.ap-south-1.compute.internal    <none>           <none>
istio-system   istiod-6fb9db6b6-5sgwv                  1/1     Running   0             25h   172.31.130.106   ip-172-31-142-47.ap-south-1.compute.internal    <none>           <none>
kube-system    aws-node-t4t4v                          2/2     Running   0             25h   172.31.142.47    ip-172-31-142-47.ap-south-1.compute.internal    <none>           <none>
kube-system    kube-proxy-28z95                        1/1     Running   0             25h   172.31.142.47    ip-172-31-142-47.ap-south-1.compute.internal    <none>           <none>

AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl get nodes
NAME                                            STATUS   ROLES    AGE   VERSION
ip-172-31-142-47.ap-south-1.compute.internal    Ready    <none>   25h   v1.29.15
ip-172-31-157-108.ap-south-1.compute.internal   Ready    <none>   33m   v1.30.14

AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ aws eks describe-update \
  --cluster-name abhinav-istio-mesh \
  --nodegroup-name ubuntu-nodes \
  --update-id 7d40b91f-539c-3116-956b-03ac126b628f \
  --region ap-south-1 \
  --query 'update.{status:status,errors:errors}'

aws.exe: [ERROR]: the following arguments are required: --name

usage: aws [options] <command> <subcommand> [<subcommand> ...] [parameters]
To see help text, you can run:

  aws help
  aws <command> help
  aws <command> <subcommand> help

AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ aws eks describe-update \
  --name abhinav-istio-mesh \
  --nodegroup-name ubuntu-nodes \
  --update-id 7d40b91f-539c-3116-956b-03ac126b628f \
  --region ap-south-1 \
  --query 'update.{status:status,errors:errors}'
{
    "status": "Failed",
    "errors": [
        {
            "errorCode": "PodEvictionFailure",
            "errorMessage": "Reached max retries while trying to evict pods from nodes in node group ubuntu-nodes",
            "resourceIds": [
                "ip-172-31-142-47.ap-south-1.compute.internal"
            ]
        }
    ]
}


AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl delete pod istio-egressgateway-5868fcbc58-5xjfq -n istio-system
kubectl delete pod istio-ingressgateway-5896f57fbb-sdskg -n istio-system
kubectl delete pod istiod-6fb9db6b6-5sgwv -n istio-system
pod "istio-egressgateway-5868fcbc58-5xjfq" deleted from istio-system namespace
pod "istio-ingressgateway-5896f57fbb-sdskg" deleted from istio-system namespace
pod "istiod-6fb9db6b6-5sgwv" deleted from istio-system namespace

AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl get pods -n istio-system -o wide
# Should show them on ip-172-31-157-108 now
NAME                                    READY   STATUS    RESTARTS   AGE   IP               NODE                                            NOMINATED NODE   READINESS GATES
istio-egressgateway-5868fcbc58-pn6p5    1/1     Running   0          26s   172.31.146.146   ip-172-31-157-108.ap-south-1.compute.internal   <none>           <none>
istio-ingressgateway-5896f57fbb-qzjqh   1/1     Running   0          18s   172.31.155.101   ip-172-31-157-108.ap-south-1.compute.internal   <none>           <none>
istiod-6fb9db6b6-2qj9l                  1/1     Running   0          10s   172.31.156.116   ip-172-31-157-108.ap-south-1.compute.internal   <none>           <none>

AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ aws eks update-nodegroup-version \
  --cluster-name abhinav-istio-mesh \
  --nodegroup-name ubuntu-nodes \
  --region ap-south-1 \
  --launch-template version=4,id=lt-09696041f02b6470e
{
    "update": {
        "id": "a478e3d3-8f7d-35b4-bcfd-4a2d34a17b5b",
        "status": "InProgress",
        "type": "VersionUpdate",
        "params": [
            {
                "type": "LaunchTemplateName",
                "value": "eks-ubuntu-lt"
            },
            {
                "type": "LaunchTemplateVersion",
                "value": "4"
            }
        ],
        "createdAt": "2026-02-24T20:13:12.286000+05:30",
        "errors": []
    }
}


AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl get nodes
NAME                                            STATUS   ROLES    AGE   VERSION
ip-172-31-142-47.ap-south-1.compute.internal    Ready    <none>   25h   v1.29.15
ip-172-31-157-108.ap-south-1.compute.internal   Ready    <none>   38m   v1.30.14

AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl get nodes
NAME                                            STATUS   ROLES    AGE   VERSION
ip-172-31-142-47.ap-south-1.compute.internal    Ready    <none>   25h   v1.29.15
ip-172-31-157-108.ap-south-1.compute.internal   Ready    <none>   39m   v1.30.14

AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl get nodes -w
NAME                                            STATUS   ROLES    AGE   VERSION
ip-172-31-142-47.ap-south-1.compute.internal    Ready    <none>   25h   v1.29.15
ip-172-31-157-108.ap-south-1.compute.internal   Ready    <none>   39m   v1.30.14
ip-172-31-154-206.ap-south-1.compute.internal   NotReady   <none>   0s    v1.30.14
ip-172-31-154-206.ap-south-1.compute.internal   NotReady   <none>   0s    v1.30.14
ip-172-31-154-206.ap-south-1.compute.internal   NotReady   <none>   0s    v1.30.14
ip-172-31-141-188.ap-south-1.compute.internal   NotReady   <none>   0s    v1.30.14
ip-172-31-141-188.ap-south-1.compute.internal   NotReady   <none>   0s    v1.30.14
ip-172-31-141-188.ap-south-1.compute.internal   NotReady   <none>   0s    v1.30.14
ip-172-31-154-206.ap-south-1.compute.internal   NotReady   <none>   0s    v1.30.14
ip-172-31-141-188.ap-south-1.compute.internal   NotReady   <none>   0s    v1.30.14
ip-172-31-141-188.ap-south-1.compute.internal   NotReady   <none>   0s    v1.30.14
ip-172-31-154-206.ap-south-1.compute.internal   NotReady   <none>   0s    v1.30.14
ip-172-31-154-206.ap-south-1.compute.internal   NotReady   <none>   1s    v1.30.14
ip-172-31-141-188.ap-south-1.compute.internal   NotReady   <none>   1s    v1.30.14
ip-172-31-154-206.ap-south-1.compute.internal   NotReady   <none>   5s    v1.30.14
ip-172-31-141-188.ap-south-1.compute.internal   NotReady   <none>   5s    v1.30.14
ip-172-31-141-188.ap-south-1.compute.internal   NotReady   <none>   10s   v1.30.14
ip-172-31-154-206.ap-south-1.compute.internal   NotReady   <none>   10s   v1.30.14
ip-172-31-154-206.ap-south-1.compute.internal   Ready      <none>   20s   v1.30.14
ip-172-31-154-206.ap-south-1.compute.internal   Ready      <none>   20s   v1.30.14
ip-172-31-141-188.ap-south-1.compute.internal   Ready      <none>   24s   v1.30.14
ip-172-31-141-188.ap-south-1.compute.internal   Ready      <none>   24s   v1.30.14
ip-172-31-141-188.ap-south-1.compute.internal   Ready      <none>   25s   v1.30.14
ip-172-31-154-206.ap-south-1.compute.internal   Ready      <none>   25s   v1.30.14
ip-172-31-141-188.ap-south-1.compute.internal   Ready      <none>   26s   v1.30.14
ip-172-31-141-188.ap-south-1.compute.internal   Ready      <none>   26s   v1.30.14
ip-172-31-154-206.ap-south-1.compute.internal   Ready      <none>   29s   v1.30.14
ip-172-31-154-206.ap-south-1.compute.internal   Ready      <none>   29s   v1.30.14
ip-172-31-141-188.ap-south-1.compute.internal   Ready      <none>   30s   v1.30.14
ip-172-31-154-206.ap-south-1.compute.internal   Ready      <none>   31s   v1.30.14


AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl get nodes
NAME                                            STATUS   ROLES    AGE   VERSION
ip-172-31-141-188.ap-south-1.compute.internal   Ready    <none>   36s   v1.30.14
ip-172-31-142-47.ap-south-1.compute.internal    Ready    <none>   25h   v1.29.15
ip-172-31-154-206.ap-south-1.compute.internal   Ready    <none>   36s   v1.30.14
ip-172-31-157-108.ap-south-1.compute.internal   Ready    <none>   41m   v1.30.14

AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl get nodes
NAME                                            STATUS                     ROLES    AGE     VERSION
ip-172-31-141-188.ap-south-1.compute.internal   Ready                      <none>   3m36s   v1.30.14
ip-172-31-142-47.ap-south-1.compute.internal    Ready,SchedulingDisabled   <none>   25h     v1.29.15
ip-172-31-154-206.ap-south-1.compute.internal   Ready                      <none>   3m36s   v1.30.14
ip-172-31-157-108.ap-south-1.compute.internal   Ready                      <none>   44m     v1.30.14

AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl scale deployment istiod -n istio-system --replicas=2
kubectl scale deployment istio-ingressgateway -n istio-system --replicas=2
kubectl scale deployment istio-egressgateway -n istio-system --replicas=2

# Verify 2 replicas each spread across both nodes
kubectl get pods -n istio-system -o wide
deployment.apps/istiod scaled
deployment.apps/istio-ingressgateway scaled
deployment.apps/istio-egressgateway scaled
NAME                                    READY   STATUS              RESTARTS   AGE     IP               NODE                                            NOMINATED NODE   READINESS GATES
istio-egressgateway-5868fcbc58-nm5c6    1/1     Running             0          3s      172.31.149.139   ip-172-31-154-206.ap-south-1.compute.internal   <none>           <none>
istio-egressgateway-5868fcbc58-pn6p5    1/1     Running             0          8m59s   172.31.146.146   ip-172-31-157-108.ap-south-1.compute.internal   <none>           <none>
istio-ingressgateway-5896f57fbb-qzjqh   1/1     Running             0          8m51s   172.31.155.101   ip-172-31-157-108.ap-south-1.compute.internal   <none>           <none>
istio-ingressgateway-5896f57fbb-v7h2l   1/1     Running             0          5s      172.31.147.217   ip-172-31-154-206.ap-south-1.compute.internal   <none>           <none>
istiod-6fb9db6b6-2qj9l                  1/1     Running             0          8m43s   172.31.156.116   ip-172-31-157-108.ap-south-1.compute.internal   <none>           <none>
istiod-6fb9db6b6-clffg                  0/1     ContainerCreating   0          7s      <none>           ip-172-31-154-206.ap-south-1.compute.internal   <none>           <none>

AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl get nodes
NAME                                            STATUS   ROLES    AGE   VERSION
ip-172-31-141-188.ap-south-1.compute.internal   Ready    <none>   11m   v1.30.14
ip-172-31-157-108.ap-south-1.compute.internal   Ready    <none>   52m   v1.30.14

AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ # Get Ubuntu EKS 1.31 AMI
aws ec2 describe-images \
  --region ap-south-1 \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu-eks/k8s_1.31/images/*amd64*" \
  --query 'sort_by(Images, &CreationDate)[-1].{ID:ImageId, Name:Name}' \
  --output table
-----------------------------------------------------------------------------------------
|                                    DescribeImages                                     |
+------+--------------------------------------------------------------------------------+
|  ID  |  ami-01fb438a6ac2db8ce                                                         |
|  Name|  ubuntu-eks/k8s_1.31/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-20251125   |
+------+--------------------------------------------------------------------------------+


AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ # Create new launch template version with 1.31 AMI
aws ec2 create-launch-template-version \
  --launch-template-id lt-09696041f02b6470e \
  --source-version 4 \
  --launch-template-data '{"ImageId":"ami-01fb438a6ac2db8ce"}'
{
    "LaunchTemplateVersion": {
        "LaunchTemplateId": "lt-09696041f02b6470e",
        "LaunchTemplateName": "eks-ubuntu-lt",
        "VersionNumber": 5,
        "CreateTime": "2026-02-24T15:02:04+00:00",
        "CreatedBy": "arn:aws:iam::183295435445:user/priyesh.rai@minfytech.com",
        "DefaultVersion": false,
        "LaunchTemplateData": {
            "BlockDeviceMappings": [
                {
                    "DeviceName": "/dev/sda1",
                    "Ebs": {
                        "DeleteOnTermination": true,
                        "VolumeSize": 20,
                        "VolumeType": "gp3"
                    }
                }
            ],
            "ImageId": "ami-01fb438a6ac2db8ce",
            "InstanceType": "t2.small",
            "UserData": "IyEvYmluL2Jhc2gKc2V0IC1leAojIEZpeCBmb3IgRklQUyBjaGVjayBpc3N1ZSBvbiBVYnVudHUgMjIuMDQKZWNobyAwID4gL3Byb2Mvc3lzL2NyeXB0by9maXBzX2VuYWJsZWQgMj4vZGV2L251bGwgfHwgdHJ1ZQovZXRjL2Vrcy9ib290c3RyYXAuc2ggYWJoaW5hdi1pc3Rpby1tZXNoIFwKICAtLXVzZS1tYXgtcG9kcyBmYWxzZSBcCiAgLS1rdWJlbGV0LWV4dHJhLWFyZ3MgJy0tbm9kZS1sYWJlbHM9ZWtzLmFtYXpvbmF3cy5jb20vbm9kZWdyb3VwPXVidW50dS1ub2RlcycK",
            "MetadataOptions": {
                "HttpTokens": "required",
                "HttpPutResponseHopLimit": 2,
                "HttpEndpoint": "enabled"
            }
        },
        "Operator": {
            "Managed": false
        }
    }
}


AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ aws eks update-nodegroup-version \
  --cluster-name abhinav-istio-mesh \
  --nodegroup-name ubuntu-nodes \
  --region ap-south-1 \
  --launch-template version=5,id=lt-09696041f02b6470e
{
    "update": {
        "id": "53a5f0e1-3668-3c66-b765-c69ff65b9275",
        "status": "InProgress",
        "type": "VersionUpdate",
        "params": [
            {
                "type": "LaunchTemplateName",
                "value": "eks-ubuntu-lt"
            },
            {
                "type": "LaunchTemplateVersion",
                "value": "5"
            }
        ],
        "createdAt": "2026-02-24T20:32:45.473000+05:30",
        "errors": []
    }
}


AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl get nodes -w
NAME                                            STATUS   ROLES    AGE   VERSION
ip-172-31-141-188.ap-south-1.compute.internal   Ready    <none>   16m   v1.30.14
ip-172-31-157-108.ap-south-1.compute.internal   Ready    <none>   57m   v1.30.14
ip-172-31-157-108.ap-south-1.compute.internal   Ready    <none>   58m   v1.30.14
ip-172-31-141-188.ap-south-1.compute.internal   Ready    <none>   17m   v1.30.14
ip-172-31-137-250.ap-south-1.compute.internal   NotReady   <none>   0s    v1.31.10
ip-172-31-137-250.ap-south-1.compute.internal   NotReady   <none>   0s    v1.31.10
ip-172-31-137-250.ap-south-1.compute.internal   NotReady   <none>   0s    v1.31.10
ip-172-31-137-250.ap-south-1.compute.internal   NotReady   <none>   1s    v1.31.10
ip-172-31-137-250.ap-south-1.compute.internal   NotReady   <none>   1s    v1.31.10
ip-172-31-137-250.ap-south-1.compute.internal   NotReady   <none>   1s    v1.31.10
ip-172-31-144-94.ap-south-1.compute.internal    NotReady   <none>   0s    v1.31.10
ip-172-31-144-94.ap-south-1.compute.internal    NotReady   <none>   0s    v1.31.10
ip-172-31-144-94.ap-south-1.compute.internal    NotReady   <none>   0s    v1.31.10
ip-172-31-144-94.ap-south-1.compute.internal    NotReady   <none>   0s    v1.31.10
ip-172-31-144-94.ap-south-1.compute.internal    NotReady   <none>   0s    v1.31.10
ip-172-31-144-94.ap-south-1.compute.internal    NotReady   <none>   0s    v1.31.10
ip-172-31-144-94.ap-south-1.compute.internal    NotReady   <none>   0s    v1.31.10
ip-172-31-137-250.ap-south-1.compute.internal   NotReady   <none>   5s    v1.31.10
ip-172-31-137-250.ap-south-1.compute.internal   NotReady   <none>   11s   v1.31.10
ip-172-31-137-250.ap-south-1.compute.internal   NotReady   <none>   13s   v1.31.10
ip-172-31-137-250.ap-south-1.compute.internal   NotReady   <none>   13s   v1.31.10
ip-172-31-144-94.ap-south-1.compute.internal    NotReady   <none>   10s   v1.31.10
ip-172-31-137-250.ap-south-1.compute.internal   Ready      <none>   22s   v1.31.10
ip-172-31-137-250.ap-south-1.compute.internal   Ready      <none>   22s   v1.31.10
ip-172-31-144-94.ap-south-1.compute.internal    Ready      <none>   19s   v1.31.10
ip-172-31-144-94.ap-south-1.compute.internal    Ready      <none>   19s   v1.31.10
ip-172-31-144-94.ap-south-1.compute.internal    Ready      <none>   20s   v1.31.10
ip-172-31-137-250.ap-south-1.compute.internal   Ready      <none>   25s   v1.31.10
ip-172-31-144-94.ap-south-1.compute.internal    Ready      <none>   26s   v1.31.10
ip-172-31-137-250.ap-south-1.compute.internal   Ready      <none>   31s   v1.31.10
ip-172-31-144-94.ap-south-1.compute.internal    Ready      <none>   26s   v1.31.10
ip-172-31-144-94.ap-south-1.compute.internal    Ready      <none>   31s   v1.31.10


AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl get nodes
NAME                                            STATUS   ROLES    AGE     VERSION
ip-172-31-137-250.ap-south-1.compute.internal   Ready    <none>   9m42s   v1.31.10
ip-172-31-144-94.ap-south-1.compute.internal    Ready    <none>   9m37s   v1.31.10

AbhinavBisht MINGW64 ~/OneDrive/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$