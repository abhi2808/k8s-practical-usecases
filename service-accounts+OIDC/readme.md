Minfy@AbhinavBisht MINGW64 ~
$ OIDC_PROVIDER="oidc.eks.ap-south-1.amazonaws.com/id/6DC71F5E1888E9ECF73E19B179E321A5"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account ID: $AWS_ACCOUNT_ID"
Account ID: 183295435445

Minfy@AbhinavBisht MINGW64 ~
$ aws eks describe-cluster --name prac-eks-abhi --region ap-south-1 --query "cluster.identity.oidc.issuer" --output text
https://oidc.eks.ap-south-1.amazonaws.com/id/6DC71F5E1888E9ECF73E19B179E321A5


Minfy@AbhinavBisht MINGW64 ~
$ cd 'OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED'/

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED
$ ld
bash: ld: command not found

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED
$ ls
 Attachments/   Desktop/   Document.docx   Documents/  'Microsoft Copilot Chat Files'/  'Microsoft Teams Chat Files'/   Pictures/   Recordings/   desktop.ini

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED
$ cd desktop

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop
$ cd NHA-ABDM/

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM
$ ls
architectures/  use-cases/

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM
$ cd use-cases/

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM/use-cases
$ ls
cluster-version-upgrade/  obeservability/

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM/use-cases
$ cd cluster-version-upgrade/

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM/use-cases/cluster-version-upgrade
$ cat > trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:default:s3-access-sa",
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM/use-cases/cluster-version-upgrade
$ cat trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::183295435445:oidc-provider/oidc.eks.ap-south-1.amazonaws.com/id/6DC71F5E1888E9ECF73E19B179E321A5"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.ap-south-1.amazonaws.com/id/6DC71F5E1888E9ECF73E19B179E321A5:sub": "system:serviceaccount:default:s3-access-sa",
          "oidc.eks.ap-south-1.amazonaws.com/id/6DC71F5E1888E9ECF73E19B179E321A5:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM/use-cases/cluster-version-upgrade
$ aws iam create-role \
  --role-name eks-s3-access-role \
  --assume-role-policy-document file://trust-policy.json \
  --description "IAM role for EKS pods to access S3 via IRSA"
{
    "Role": {
        "Path": "/",
        "RoleName": "eks-s3-access-role",
        "RoleId": "AROASVLKCMK2S2YA5755W",
        "Arn": "arn:aws:iam::183295435445:role/eks-s3-access-role",
        "CreateDate": "2026-02-10T06:20:01+00:00",
        "AssumeRolePolicyDocument": {
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": "Allow",
                    "Principal": {
                        "Federated": "arn:aws:iam::183295435445:oidc-provider/oidc.eks.ap-south-1.amazonaws.com/id/6DC71F5E1888E9ECF73E19B179E321A5"
                    },
                    "Action": "sts:AssumeRoleWithWebIdentity",
                    "Condition": {
                        "StringEquals": {
                            "oidc.eks.ap-south-1.amazonaws.com/id/6DC71F5E1888E9ECF73E19B179E321A5:sub": "system:serviceaccount:default:s3-access-sa",
                            "oidc.eks.ap-south-1.amazonaws.com/id/6DC71F5E1888E9ECF73E19B179E321A5:aud": "sts.amazonaws.com"
                        }
                    }
                }
            ]
        }
    }
}


Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM/use-cases/cluster-version-upgrade
$ ROLE_ARN=$(aws iam get-role --role-name eks-s3-access-role --query 'Role.Arn' --output text)
echo "Role ARN: $ROLE_ARN"
Role ARN: arn:aws:iam::183295435445:role/eks-s3-access-role

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM/use-cases/cluster-version-upgrade
$ cat > s3-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket",
        "s3:PutObject"
      ],
      "Resource": [
        "arn:aws:s3:::prac-eks-abhi-irsa-demo",
        "arn:aws:s3:::prac-eks-abhi-irsa-demo/*"
      ]
    }
  ]
}
EOF

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM/use-cases/cluster-version-upgrade
$ aws iam put-role-policy \
  --role-name eks-s3-access-role \
  --policy-name S3AccessPolicy \
  --policy-document file://s3-policy.json

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM/use-cases/cluster-version-upgrade
$ ROLE_ARN=$(aws iam get-role --role-name eks-s3-access-role --query 'Role.Arn' --output text)

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM/use-cases/cluster-version-upgrade
$ echo "Role ARN: $ROLE_ARN"
Role ARN: arn:aws:iam::183295435445:role/eks-s3-access-role

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM/use-cases/cluster-version-upgrade
$ cat > service-account.yaml <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: s3-access-sa
  namespace: default
  annotations:
    eks.amazonaws.com/role-arn: ${ROLE_ARN}
EOF

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM/use-cases/cluster-version-upgrade
$ cat service-account.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: s3-access-sa
  namespace: default
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::183295435445:role/eks-s3-access-role

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM/use-cases/cluster-version-upgrade
$ kubectl apply -f service-account.yaml
serviceaccount/s3-access-sa created

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM/use-cases/cluster-version-upgrade
$ kubectl get serviceAccounts
NAME           SECRETS   AGE
default        0         23h
s3-access-sa   0         16s

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM/use-cases/cluster-version-upgrade
$ cat > s3-test-pod.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: s3-test-pod
  namespace: default
spec:
  serviceAccountName: s3-access-sa
  containers:
  - name: aws-cli
    image: amazon/aws-cli:latest
    command:
      - sleep
      - "3600"
    env:
    - name: AWS_DEFAULT_REGION
      value: ap-south-1
EOF

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM/use-cases/cluster-version-upgrade
$ kubectl apply -f s3-test-pod.yaml
pod/s3-test-pod created

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM/use-cases/cluster-version-upgrade
$ kubectl get pods
NAME                     READY   STATUS    RESTARTS   AGE
brdep-7f85b6fdd9-246vb   1/1     Running   0          20h
brdep-7f85b6fdd9-2qvsf   1/1     Running   0          20h
s3-test-pod              1/1     Running   0          2m21s

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM/use-cases/cluster-version-upgrade
$ kubectl exec -it s3-test-pod
error: you must specify at least one command for the container

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM/use-cases/cluster-version-upgrade
$ kubectl exec -it s3-test-pod -- /bin/bash
error: Internal error occurred: Internal error occurred: error executing command in container: failed to exec in container: failed to start exec "daa47b29b4197f3c1751461be3f7f90b1968f3410323f511c3479418c4c12f31": OCI runtime exec failed: exec failed: unable to start container process: exec: "C:/Program Files/Git/usr/bin/bash": stat C:/Program Files/Git/usr/bin/bash: no such file or directory: unknown

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM/use-cases/cluster-version-upgrade
$ kubectl exec -it s3-test-pod -- /bin/sh
error: Internal error occurred: Internal error occurred: error executing command in container: failed to exec in container: failed to start exec "fa0e3112ab105df4f91379c85256bf221b60ffa5a5e401f8045996ab2b3e6b64": OCI runtime exec failed: exec failed: unable to start container process: exec: "C:/Program Files/Git/usr/bin/sh": stat C:/Program Files/Git/usr/bin/sh: no such file or directory: unknown

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM/use-cases/cluster-version-upgrade
$ kubectl exec -it s3-test-pod -- sh
sh-5.2# aws sts get-caller-identity

An error occurred (InvalidIdentityToken) when calling the AssumeRoleWithWebIdentity operation: No OpenIDConnect provider found in your account for https://oidc.eks.ap-south-1.amazonaws.com/id/6DC71F5E1888E9ECF73E19B179E321A5
sh-5.2# exit
exit
command terminated with exit code 254

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM/use-cases/cluster-version-upgrade
$ aws eks describe-cluster \
  --name <YOUR_CLUSTER_NAME> \
  --region ap-south-1 \
  --query "cluster.identity.oidc.issuer" \
  --output text
bash: YOUR_CLUSTER_NAME: No such file or directory

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM/use-cases/cluster-version-upgrade
$ aws eks describe-cluster   --name prac-eks-abhi   --region ap-south-1   --query "cluster.identity.oidc.issuer"   --output text
https://oidc.eks.ap-south-1.amazonaws.com/id/6DC71F5E1888E9ECF73E19B179E321A5


Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM/use-cases/cluster-version-upgrade
$ https://oidc.eks.ap-south-1.amazonaws.com/id/XXXXXXXXXXXX
bash: https://oidc.eks.ap-south-1.amazonaws.com/id/XXXXXXXXXXXX: No such file or directory

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM/use-cases/cluster-version-upgrade
$ eksctl utils associate-iam-oidc-provider \
  --cluster prac-eks-abhi \
  --region ap-south-1 \
  --approve
2026-02-10 12:26:25 [ℹ]  will create IAM Open ID Connect provider for cluster "prac-eks-abhi" in "ap-south-1"
2026-02-10 12:26:30 [✔]  created IAM Open ID Connect provider for cluster "prac-eks-abhi" in "ap-south-1"

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM/use-cases/cluster-version-upgrade
$ aws iam list-open-id-connect-providers | grep 6DC71F5E
            "Arn": "arn:aws:iam::183295435445:oidc-provider/oidc.eks.ap-south-1.amazonaws.com/id/6DC71F5E1888E9ECF73E19B179E321A5"

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM/use-cases/cluster-version-upgrade
$ kubectl describe pod s3-test-pod | grep AWS_ROLE_ARN
      AWS_ROLE_ARN:                 arn:aws:iam::183295435445:role/eks-s3-access-role

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM/use-cases/cluster-version-upgrade
$ kubectl get pods
NAME                     READY   STATUS    RESTARTS   AGE
brdep-7f85b6fdd9-246vb   1/1     Running   0          20h
brdep-7f85b6fdd9-2qvsf   1/1     Running   0          20h
s3-test-pod              1/1     Running   0          15m

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/NHA-ABDM/use-cases/cluster-version-upgrade
$ kubectl exec -it s3-test-pod -- sh
sh-5.2# aws sts get-caller-identity
{
    "UserId": "AROASVLKCMK2S2YA5755W:botocore-session-1770706864",
    "Account": "183295435445",
    "Arn": "arn:aws:sts::183295435445:assumed-role/eks-s3-access-role/botocore-session-1770706864"
}
sh-5.2# s3://prac-eks-abhi-irsa-demo/
sh: s3://prac-eks-abhi-irsa-demo/: No such file or directory
sh-5.2# aws ls s3://prac-eks-abhi-irsa-demo/

aws: [ERROR]: argument command: Found invalid choice 'ls'


usage: aws [options] <command> <subcommand> [<subcommand> ...] [parameters]
To see help text, you can run:

  aws help
  aws <command> help
  aws <command> <subcommand> help

sh-5.2# aws s3 ls s3://prac-eks-abhi-irsa-demo/
2026-02-10 05:22:07         32 test-data.txt
sh-5.2# aws s3 cp s3://prac-eks-abhi-irsa-demo/test-data.txt /tmp/test.txt
download: s3://prac-eks-abhi-irsa-demo/test-data.txt to ../tmp/test.txt
sh-5.2# cat /tmp/test.txt
Hello from S3! IRSA is working.
sh-5.2#


Note->

basically create: 1 trust policy, 1/many policy to assign to the trusted, create service account, and access whats required.

dont forget to attatch/register the OIDC to the iam:
eksctl utils associate-iam-oidc-provider \
  --cluster prac-eks-abhi \
  --region ap-south-1 \
  --approve



# How IRSA works

In Amazon EKS, IAM Roles for Service Accounts (IRSA) is built on top of Kubernetes ServiceAccount identities and OpenID Connect (OIDC). Every EKS cluster is automatically configured with an OIDC issuer URL at creation time. This issuer uniquely represents the cluster and is exposed through the cluster identity. Kubernetes uses this issuer when generating JSON Web Tokens (JWTs) for ServiceAccounts, allowing workloads running inside the cluster to present a verifiable identity that can be trusted by external systems such as AWS IAM.

When a pod is created and associated with a specific Kubernetes ServiceAccount, the Kubernetes control plane prepares to issue a ServiceAccount token for that pod. Modern Kubernetes uses projected ServiceAccount tokens instead of long-lived secrets. These tokens are short-lived, automatically rotated, and scoped to a specific audience. In EKS, the audience is typically set to sts.amazonaws.com, making the token suitable for AWS Security Token Service (STS) federation. The token itself is not generated until the pod is scheduled and started.

At pod startup, the kubelet requests a token from the Kubernetes API server on behalf of the pod’s ServiceAccount. The API server generates a signed JWT containing key identity claims such as the issuer (iss), subject (sub), audience (aud), and expiration time (exp). The subject uniquely identifies the ServiceAccount in the form system:serviceaccount:<namespace>:<serviceaccount-name>. This token is then mounted into the pod’s filesystem at a well-known path, along with environment variables that reference the token file and the IAM role to be assumed.

Inside the container, no AWS access keys or secrets are present. Instead, the pod relies on the AWS SDK or AWS CLI to consume the projected token. When the application makes an AWS API call, the SDK automatically detects the web identity token and role ARN and initiates a call to AssumeRoleWithWebIdentity against AWS STS. At this point, AWS IAM becomes involved in the authentication flow.

IAM first validates the token issuer by checking whether the cluster’s OIDC issuer URL has been registered as an IAM OIDC provider in the AWS account. This registration step is mandatory and establishes trust between IAM and the EKS cluster. If the issuer is not registered, IAM rejects the request with an invalid identity token error. Once the issuer is trusted, IAM evaluates the role’s trust policy to verify that the subject claim in the token matches the allowed ServiceAccount and namespace defined in the policy.

If the issuer, subject, audience, and token signature are all valid, IAM allows the role assumption and returns temporary security credentials. These credentials consist of an access key, secret key, and session token with a limited lifetime. The AWS SDK caches and refreshes these credentials automatically, ensuring seamless access without exposing long-term secrets to the pod. From this point onward, AWS services see the request as coming from an assumed IAM role, with permissions defined by the policies attached to that role.

This architecture cleanly separates identity and authorization responsibilities. Kubernetes remains responsible for issuing workload identities through ServiceAccounts, while AWS IAM enforces permission boundaries and access control. By using short-lived, automatically rotated tokens and avoiding static credentials, IRSA provides a secure, scalable, and auditable mechanism for granting fine-grained AWS permissions to Kubernetes workloads.


# Sequence Diagram
    
    autonumber
    participant Pod as Kubernetes Pod
    participant Kubelet
    participant APIServer as Kubernetes API Server
    participant OIDC as EKS OIDC Issuer
    participant STS as AWS STS
    participant IAM as AWS IAM
    participant AWS as AWS Service (e.g., S3)

    Pod->>Kubelet: Pod scheduled with ServiceAccount
    Kubelet->>APIServer: Request ServiceAccount token
    APIServer->>OIDC: Generate & sign JWT
    OIDC-->>APIServer: Signed OIDC JWT
    APIServer-->>Kubelet: Projected token
    Kubelet-->>Pod: Mount token & env vars

    Pod->>STS: AssumeRoleWithWebIdentity (JWT + Role ARN)
    STS->>IAM: Validate issuer, subject, audience
    IAM-->>STS: Trust policy & OIDC validation result
    STS-->>Pod: Temporary IAM credentials

    Pod->>AWS: AWS API request (signed with temp creds)
    AWS-->>Pod: Authorized response
