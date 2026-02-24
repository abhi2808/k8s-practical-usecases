# Service Mesh

generally, with microservices in k8s if we dont want everything in the cluster to access each-other would need to setup complex networking(security, retry, metrics, tracing) make the micro service too complex.

Soultion: service mesh->

rather run a sidecar for this that acts as a proxy, cluster can configure to without knowing the background logic

dont need to deploy the sidecar with app deployment, the service mesh has a control plane which injects the sidecar/proxy in every microservice pod.(micro services communicate through the proxy)

best feature: traffic splitting->
say you update the service, can implement canary deployments.


## istio

its an implementation of servcie mesh, using envoy(open source) as a proxy, control plane: istiod(injects proxy)

till <1.5: istio cp=>(bundle of piloy, galley, citadel, mixer), thus multiple pods when you deployed, 1.5 combined them all to istiod


how to configure:

all config in istio, configure using yaml(using k8s CRD), thus using crd's we configure diff traffic route rules. 

2 main crd's:
- virtualService: it answers the question "where should this request go?", "If request comes in on host voting.com port 80 → send to vote service"
- destinationRule:  it answers "how should traffic behave once it reaches the destination?", "Once traffic reaches vote service → use round robin load balancing"

these are converted to envoy specific config and send to envoy proxies

istio has dynamic service discovery has certificate management(TLS communication), gets metrics/tracing data from envoy


## istio ingress gateway

entrypoint to cluster alternative to nginx ingress controller, runs as pod act as LB(directs traffic using virtual service components), implemented using gateway crd


## traffic

2 service traffic

user->istio gw->virtual service rules->web server microservice pod->envoy proxy 1->service 1->envoy proxy 1->virual service/rules for 2(mTLS)->envoy proxy 2->service 2(throiugh outh this metrics are being sent to control plane)



# IMPLEMENTATION


## How to setup

### 1. Enable Sidecar Injection
```bash
kubectl label namespace default istio-injection=enabled
```

### 2. Deploy the App
```bash
kubectl apply -f deployments-svc/
# Restart to inject Istio sidecars after labeling
kubectl rollout restart deployment vote result worker db redis
# Verify all pods show 2/2 READY
kubectl get pods
```

### 3. Patch Istio Ingress Gateway to open port 81
```bash
kubectl patch svc istio-ingressgateway -n istio-system \
  --type=json \
  -p='[{"op":"add","path":"/spec/ports/-","value":{"name":"http-result","port":81,"targetPort":8081,"protocol":"TCP"}}]'
```

### 4. Apply Istio Gateway and VirtualServices
```bash
kubectl apply -f gateway.yaml
kubectl apply -f vote-virtualservice.yaml
kubectl apply -f result-virtualservice.yaml
```

### 5. Get External URL and Access the App
```bash
kubectl get svc istio-ingressgateway -n istio-system
# Copy EXTERNAL-IP and hit:
# http://:80  → vote app
# http://:81  → result app
```

### 6. Verify
```bash
kubectl get gateway
kubectl get virtualservice
kubectl get pods   # all should be 2/2
```


## Learnings

### How the LoadBalancer, Gateway, and VirtualServices fit together

The AWS ELB was **not created by gateway.yaml** — it was created when you ran `istioctl install --set profile=demo`. That command deployed the `istio-ingressgateway` as a Kubernetes Service of type `LoadBalancer` in the `istio-system` namespace, and AWS automatically provisioned the ELB at that point. It was already running and waiting for configuration before any YAML was written.

The ingressgateway itself is a running **Envoy proxy pod** sitting between the AWS ELB and your app services. Without any configuration it just drops all traffic. `gateway.yaml` is what gives it instructions — which ports to listen on, which hostnames to accept. It is not infrastructure, it is just configuration for the already-running pod.

> **gateway.yaml = configuration, not infrastructure**

VirtualServices then tell the Envoy pod *where* to forward matching traffic. Without a VirtualService, traffic enters through the Gateway and has nowhere to go. VirtualServices are **one-directional — Gateway → Service only**, never the reverse.

The destination `host` in a VirtualService is always the **K8s ClusterIP Service name**, never a pod IP directly. Istio resolves it via Kubernetes DNS (`vote.default.svc.cluster.local`) and kube-proxy handles the rest.

DestinationRules work alongside VirtualServices but serve a different purpose — a VirtualService answers *where* to send traffic, a DestinationRule answers *how* to handle it once it arrives (mTLS, circuit breaking, load balancing policy). DestinationRules are optional for basic exposure but required for advanced traffic policies.

### Complete traffic flow

```
Browser (:80 or :81)
        ↓
    AWS ELB
        ↓
ingressgateway Envoy pod
        ↓
gateway.yaml → "I accept port 80 and 81"
        ↓
VirtualService → "port 80 → vote service | port 81 → result service"
        ↓
ClusterIP Service (K8s DNS resolution)
        ↓
App Pod :80
```

### Quick reference

| Component | Created by | Purpose |
|---|---|---|
| AWS ELB | `istioctl install` | External entry point |
| ingressgateway pod | `istioctl install` | Envoy proxy, handles routing |
| `gateway.yaml` | You | Configures ports/hosts on the Envoy pod |
| `VirtualService` | You | Routes traffic to the correct K8s service |
| `DestinationRule` | You | Defines traffic policy at the destination |


## CLI implementation

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ # Download Istio 1.24.3 (latest stable)
curl -L https://github.com/istio/istio/releases/download/1.24.3/istio-1.24.3-win.zip -o istio.zip

# Unzip it
unzip istio.zip

# Add to PATH
export PATH="$PWD/istio-1.24.3/bin:$PATH"

# Verify
istioctl version
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
  0     0   0     0   0     0     0     0  --:--:-- --:--:-- --:--:--     0
100 28111k 100 28111k   0     0  4936k     0   0:00:05  0:00:05 --:--:--  5843k
Archive:  istio.zip
   creating: istio-1.24.3/
  inflating: istio-1.24.3/LICENSE
  inflating: istio-1.24.3/README.md
   creating: istio-1.24.3/bin/
  inflating: istio-1.24.3/bin/istioctl.exe
  inflating: istio-1.24.3/manifest.yaml
   creating: istio-1.24.3/manifests/
   creating: istio-1.24.3/manifests/charts/
  inflating: istio-1.24.3/manifests/charts/README.md.......(for serveral 100 lines)


Istio is not present in the cluster: no running Istio pods in namespace "istio-system"
client version: 1.24.3

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ istioctl install --set profile=demo -y
        |\
        | \
        |  \
        |   \
      /||    \
     / ||     \
    /  ||      \
   /   ||       \
  /    ||        \
 /     ||         \
/______||__________\
____________________
  \__       _____/
     \_____/

WARNING: Istio 1.24.0 may be out of support (EOL) already: see https://istio.io/latest/docs/releases/supported-releases/ for supported releases
✔ Istio core installed ⛵️

✔ Istiod installed 🧠
✔ Egress gateways installed 🛫
✔ Ingress gateways installed 🛬
✔ Installation complete

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ ls
cl.yml  example-voting-app/  istio-1.24.3/  istio.zip  nodegroup-config.yaml  readme.md

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ mkdir deployments

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ cd deployments/

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr/deployments (main)
$ touch vote.yml result.yml worker.yml redis.yml

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr/deployments (main)
$ touch db.yml

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr/deployments (main)
$ cd ..

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl get pods -n istio-system
NAME                                    READY   STATUS    RESTARTS   AGE
istio-egressgateway-5868fcbc58-5xjfq    1/1     Running   0          73m
istio-ingressgateway-5896f57fbb-sdskg   1/1     Running   0          73m
istiod-6fb9db6b6-5sgwv                  1/1     Running   0          73m

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ cd deployments-svc/

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr/deployments-svc (main)
$ kubectl apply -f k8s-specifications/
error: the path "k8s-specifications/" does not exist

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr/deployments-svc (main)
$ cd ..

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl apply -f deployments-svc/
service/db created
deployment.apps/db created
service/redis created
deployment.apps/redis created
service/result created
deployment.apps/result created
service/vote created
deployment.apps/worker created
error: error validating "deployments-svc\\vote.yml": error validating data: apiVersion not set; if you choose to ignore these errors, turn validation off with --validate=false

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl delete -f deployments-svc/
service "db" deleted from default namespace
deployment.apps "db" deleted from default namespace
service "redis" deleted from default namespace
deployment.apps "redis" deleted from default namespace
service "result" deleted from default namespace
deployment.apps "result" deleted from default namespace
service "vote" deleted from default namespace
deployment.apps "worker" deleted from default namespace
Error from server (NotFound): error when deleting "deployments-svc\\vote.yml": deployments.apps "vote" not found

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl apply -f deployments-svc/
service/db created
deployment.apps/db created
service/redis created
deployment.apps/redis created
service/result created
deployment.apps/result created
service/vote created
deployment.apps/vote created
deployment.apps/worker created

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl get deployments
NAME     READY   UP-TO-DATE   AVAILABLE   AGE
db       1/1     1            1           22s
redis    0/1     1            0           22s
result   2/2     2            2           22s
vote     1/2     2            1           22s
worker   1/2     2            1           22s

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl get deployments
NAME     READY   UP-TO-DATE   AVAILABLE   AGE
db       1/1     1            1           33s
redis    1/1     1            1           33s
result   2/2     2            2           33s
vote     1/2     2            1           33s
worker   2/2     2            2           33s

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl delete -f deployments-svc/
service "db" deleted from default namespace
deployment.apps "db" deleted from default namespace
service "redis" deleted from default namespace
deployment.apps "redis" deleted from default namespace
service "result" deleted from default namespace
deployment.apps "result" deleted from default namespace
service "vote" deleted from default namespace
deployment.apps "vote" deleted from default namespace
deployment.apps "worker" deleted from default namespace

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl apply -f deployments-svc/
service/db created
deployment.apps/db created
service/redis created
deployment.apps/redis created
service/result created
deployment.apps/result created
service/vote created
deployment.apps/vote created
deployment.apps/worker created

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl get deployments
NAME     READY   UP-TO-DATE   AVAILABLE   AGE
db       1/1     1            1           17s
redis    1/1     1            1           17s
result   2/2     2            2           16s
vote     1/2     2            1           16s
worker   1/2     2            1           16s

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl get svc
NAME         TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
db           ClusterIP   10.100.124.80   <none>        5432/TCP   25s
kubernetes   ClusterIP   10.100.0.1      <none>        443/TCP    5h2m
redis        ClusterIP   10.100.70.36    <none>        6379/TCP   25s
result       ClusterIP   10.100.194.76   <none>        80/TCP     25s
vote         ClusterIP   10.100.57.225   <none>        80/TCP     24s

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl get pods
NAME                      READY   STATUS    RESTARTS   AGE
db-74574d66dd-tft4b       1/1     Running   0          77s
redis-6c5fb9c4b7-hc8x4    1/1     Running   0          77s
result-dd5458665-dx66c    1/1     Running   0          76s
result-dd5458665-xvzzc    1/1     Running   0          76s
vote-65cff6f9c9-64f47     1/1     Running   0          76s
vote-65cff6f9c9-zj75l     1/1     Running   0          76s
worker-6f85695f94-64xl6   1/1     Running   0          76s
worker-6f85695f94-glxkc   1/1     Running   0          76s

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl exec -it $(kubectl get pod -l app=vote -o jsonpath='{.items[0].metadata.name}') -- wget -qO- http://localhost:80
error: Internal error occurred: Internal error occurred: error executing command in container: failed to exec in container: failed to start exec "a1b9c76deaac3e1e6d5cd18af71f1aaf4facb6545cfe6a9db7b91a8668e19b54": OCI runtime exec failed: exec failed: unable to start container process: exec: "wget": executable file not found in $PATH: unknown

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl exec -it $(kubectl get pod -l app=result -o jsonpath='{.items[0].metadata.name}') -- wget -qO- http://localhost:80
error: Internal error occurred: Internal error occurred: error executing command in container: failed to exec in container: failed to start exec "e97d38fe5111180eb477dec8ec18147c4d0abfe951b32e62d4f0ab2ab3726cf1": OCI runtime exec failed: exec failed: unable to start container process: exec: "wget": executable file not found in $PATH: unknown

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl logs -l app=worker
Waiting for db
Waiting for db
Connected to db
Found redis at 10.100.70.36
Connecting to redis
Connected to db
Found redis at 10.100.70.36
Connecting to redis

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl exec -it $(kubectl get pod -l app=redis -o jsonpath='{.items[0].metadata.name}') -- redis-cli ping
# Should return PONG
PONG

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ ^C

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ # Test vote
kubectl exec -it $(kubectl get pod -l app=vote -o jsonpath='{.items[0].metadata.name}') -- curl http://localhost:80

# Test result
kubectl exec -it $(kubectl get pod -l app=result -o jsonpath='{.items[0].metadata.name}') -- curl http://localhost:80
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8">
    <title>Cats vs Dogs!</title>
    <base href="/index.html">
    <meta name = "viewport" content = "width=device-width, initial-scale = 1.0">
    <meta name="keywords" content="docker-compose, docker, stack">
    <meta name="author" content="Tutum dev team">
    <link rel='stylesheet' href="/static/stylesheets/style.css" />
    <link rel="stylesheet" href="https://maxcdn.bootstrapcdn.com/font-awesome/4.4.0/css/font-awesome.min.css">
  </head>
  <body>
    <div id="content-container">
      <div id="content-container-center">
        <h3>Cats vs Dogs!</h3>
        <form id="choice" name='form' method="POST" action="/">
          <button id="a" type="submit" name="vote" class="a" value="a">Cats</button>
          <button id="b" type="submit" name="vote" class="b" value="b">Dogs</button>
        </form>
        <div id="tip">
          (Tip: you can change your vote)
        </div>
        <div id="hostname">
          Processed by container ID vote-65cff6f9c9-64f47
        </div>
      </div>
    </div>
    <script src="http://code.jquery.com/jquery-latest.min.js" type="text/javascript"></script>
    <script src="//cdnjs.cloudflare.com/ajax/libs/jquery-cookie/1.4.1/jquery.cookie.js"></script>


  </body>
</html><!DOCTYPE html>
<html ng-app="catsvsdogs">
  <head>
    <meta charset="utf-8">
    <title>Cats vs Dogs -- Result</title>
    <base href="/index.html">
    <meta name = "viewport" content = "width=device-width, initial-scale = 1.0">
    <meta name="keywords" content="docker-compose, docker, stack">
    <meta name="author" content="Docker">
    <link rel='stylesheet' href='/stylesheets/style.css' />
  </head>
  <body ng-controller="statsCtrl" >
     <div id="background-stats">
       <div id="background-stats-1">
       </div><!--
      --><div id="background-stats-2">
      </div>
    </div>
    <div id="content-container">
      <div id="content-container-center">
        <div id="choice">
          <div class="choice cats">
            <div class="label">Cats</div>
            <div class="stat">{{aPercent | number:1}}%</div>
          </div>
          <div class="divider"></div>
          <div class="choice dogs">
            <div class="label">Dogs</div>
            <div class="stat">{{bPercent | number:1}}%</div>
          </div>
        </div>
      </div>
    </div>
    <div id="result">
      <span ng-if="total == 0">No votes yet</span>
      <span ng-if="total == 1">{{total}} vote</span>
      <span ng-if="total >= 2">{{total}} votes</span>
    </div>
    <script src="socket.io.js"></script>
    <script src="angular.min.js"></script>
    <script src="app.js"></script>
  </body>
</html>

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ # Label namespace
kubectl label namespace default istio-injection=enabled

# Restart all deployments to inject sidecars
kubectl rollout restart deployment vote result worker db redis

# Watch pods come back up — should show 2/2 this time
kubectl get pods -w
namespace/default labeled
deployment.apps/vote restarted
deployment.apps/result restarted
deployment.apps/worker restarted
deployment.apps/db restarted
deployment.apps/redis restarted
NAME                      READY   STATUS     RESTARTS   AGE
db-74574d66dd-tft4b       1/1     Running    0          8m32s
db-84c78cd8c9-vh7gt       0/2     Init:0/1   0          2s
redis-545bcfd5b8-cpnzh    0/2     Init:0/1   0          2s
redis-6c5fb9c4b7-hc8x4    1/1     Running    0          8m32s
result-6645d46654-7cwbf   1/2     Running    0          3s
result-dd5458665-dx66c    1/1     Running    0          8m31s
result-dd5458665-xvzzc    1/1     Running    0          8m31s
vote-65cff6f9c9-64f47     1/1     Running    0          8m31s
vote-65cff6f9c9-zj75l     1/1     Running    0          8m31s
vote-76869c5b6-6mnsh      0/2     Init:0/1   0          3s
worker-59b9d85bff-khn2w   0/2     Init:0/1   0          3s
worker-6f85695f94-64xl6   1/1     Running    0          8m31s
worker-6f85695f94-glxkc   1/1     Running    0          8m31s
result-6645d46654-7cwbf   2/2     Running    0          4s
result-dd5458665-dx66c    1/1     Terminating   0          8m32s
result-6645d46654-lnpw5   0/2     Pending       0          0s
result-6645d46654-lnpw5   0/2     Pending       0          0s
result-6645d46654-lnpw5   0/2     Init:0/1      0          0s
result-dd5458665-dx66c    0/1     Error         0          8m32s
result-dd5458665-dx66c    0/1     Error         0          8m33s
result-dd5458665-dx66c    0/1     Error         0          8m33s
result-6645d46654-lnpw5   0/2     PodInitializing   0          9s
result-6645d46654-lnpw5   1/2     Running           0          10s
result-6645d46654-lnpw5   1/2     Running           0          10s
result-6645d46654-lnpw5   2/2     Running           0          11s
result-dd5458665-xvzzc    1/1     Terminating       0          8m43s
result-dd5458665-xvzzc    0/1     Error             0          8m43s
result-dd5458665-xvzzc    0/1     Error             0          8m44s
result-dd5458665-xvzzc    0/1     Error             0          8m44s


Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl get deployments
NAME     READY   UP-TO-DATE   AVAILABLE   AGE
db       1/1     1            1           9m23s
redis    1/1     1            1           9m23s
result   2/2     2            2           9m22s
vote     2/2     1            2           9m22s
worker   2/2     2            2           9m22s

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl get pods -o wide
NAME                      READY   STATUS     RESTARTS     AGE     IP               NODE                                           NOMINATED NODE   READINESS GATES
db-84c78cd8c9-vh7gt       2/2     Running    0            79s     172.31.137.20    ip-172-31-142-47.ap-south-1.compute.internal   <none>           <none>
redis-545bcfd5b8-cpnzh    0/2     Init:0/1   0            79s     <none>           ip-172-31-142-47.ap-south-1.compute.internal   <none>           <none>
redis-6c5fb9c4b7-hc8x4    1/1     Running    0            9m49s   172.31.130.39    ip-172-31-142-47.ap-south-1.compute.internal   <none>           <none>
result-6645d46654-7cwbf   2/2     Running    1 (7s ago)   80s     172.31.140.144   ip-172-31-142-47.ap-south-1.compute.internal   <none>           <none>
result-6645d46654-lnpw5   2/2     Running    1 (7s ago)   76s     172.31.151.214   ip-172-31-150-90.ap-south-1.compute.internal   <none>           <none>
vote-65cff6f9c9-64f47     1/1     Running    0            9m48s   172.31.150.177   ip-172-31-150-90.ap-south-1.compute.internal   <none>           <none>
vote-65cff6f9c9-zj75l     1/1     Running    0            9m48s   172.31.138.209   ip-172-31-142-47.ap-south-1.compute.internal   <none>           <none>
vote-76869c5b6-6mnsh      0/2     Init:0/1   0            80s     <none>           ip-172-31-142-47.ap-south-1.compute.internal   <none>           <none>
worker-59b9d85bff-khn2w   1/2     Error      1 (7s ago)   80s     172.31.133.197   ip-172-31-142-47.ap-south-1.compute.internal   <none>           <none>
worker-59b9d85bff-wrch4   2/2     Running    1 (7s ago)   40s     172.31.156.228   ip-172-31-150-90.ap-south-1.compute.internal   <none>           <none>

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl get pods -o wide
NAME                      READY   STATUS     RESTARTS      AGE   IP               NODE                                           NOMINATED NODE   READINESS GATES
db-84c78cd8c9-vh7gt       2/2     Running    0             94s   172.31.137.20    ip-172-31-142-47.ap-south-1.compute.internal   <none>           <none>
redis-545bcfd5b8-cpnzh    0/2     Init:0/1   0             94s   <none>           ip-172-31-142-47.ap-south-1.compute.internal   <none>           <none>
redis-6c5fb9c4b7-hc8x4    1/1     Running    0             10m   172.31.130.39    ip-172-31-142-47.ap-south-1.compute.internal   <none>           <none>
result-6645d46654-7cwbf   2/2     Running    1 (22s ago)   95s   172.31.140.144   ip-172-31-142-47.ap-south-1.compute.internal   <none>           <none>
result-6645d46654-lnpw5   2/2     Running    1 (22s ago)   91s   172.31.151.214   ip-172-31-150-90.ap-south-1.compute.internal   <none>           <none>
vote-65cff6f9c9-64f47     1/1     Running    0             10m   172.31.150.177   ip-172-31-150-90.ap-south-1.compute.internal   <none>           <none>
vote-65cff6f9c9-zj75l     1/1     Running    0             10m   172.31.138.209   ip-172-31-142-47.ap-south-1.compute.internal   <none>           <none>
vote-76869c5b6-6mnsh      0/2     Init:0/1   0             95s   <none>           ip-172-31-142-47.ap-south-1.compute.internal   <none>           <none>
worker-59b9d85bff-khn2w   2/2     Running    2 (19s ago)   95s   172.31.133.197   ip-172-31-142-47.ap-south-1.compute.internal   <none>           <none>
worker-59b9d85bff-wrch4   2/2     Running    1 (22s ago)   55s   172.31.156.228   ip-172-31-150-90.ap-south-1.compute.internal   <none>           <none>

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl get pods -o wide
NAME                      READY   STATUS    RESTARTS        AGE     IP               NODE                                           NOMINATED NODE   READINESS GATES
db-84c78cd8c9-vh7gt       2/2     Running   0               4m51s   172.31.137.20    ip-172-31-142-47.ap-south-1.compute.internal   <none>           <none>
redis-545bcfd5b8-cpnzh    2/2     Running   0               4m51s   172.31.138.209   ip-172-31-142-47.ap-south-1.compute.internal   <none>           <none>
result-6645d46654-7cwbf   2/2     Running   1 (3m39s ago)   4m52s   172.31.140.144   ip-172-31-142-47.ap-south-1.compute.internal   <none>           <none>
result-6645d46654-lnpw5   2/2     Running   1 (3m39s ago)   4m48s   172.31.151.214   ip-172-31-150-90.ap-south-1.compute.internal   <none>           <none>
vote-76869c5b6-54fnl      2/2     Running   0               3m2s    172.31.159.205   ip-172-31-150-90.ap-south-1.compute.internal   <none>           <none>
vote-76869c5b6-6mnsh      2/2     Running   0               4m52s   172.31.129.91    ip-172-31-142-47.ap-south-1.compute.internal   <none>           <none>
worker-59b9d85bff-khn2w   2/2     Running   2 (3m36s ago)   4m52s   172.31.133.197   ip-172-31-142-47.ap-south-1.compute.internal   <none>           <none>
worker-59b9d85bff-wrch4   2/2     Running   1 (3m39s ago)   4m12s   172.31.156.228   ip-172-31-150-90.ap-south-1.compute.internal   <none>           <none>

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl get namespaces
NAME              STATUS   AGE
default           Active   5h17m
istio-system      Active   96m
kube-node-lease   Active   5h17m
kube-public       Active   5h17m
kube-system       Active   5h17m

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ vim gateway.yml

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ vim vote-virtualservice.yml

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ vim result-virtualservice.yml

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl apply -f gateway.yml
kubectl apply -f vote-virtualservice.yml
kubectl apply -f result-virtualservice.yml
gateway.networking.istio.io/voting-gateway created
virtualservice.networking.istio.io/vote-vs created
virtualservice.networking.istio.io/result-vs created

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl get gateway
kubectl get virtualservice
NAME             AGE
voting-gateway   26s
NAME        GATEWAYS             HOSTS   AGE
result-vs   ["voting-gateway"]   ["*"]   24s
vote-vs     ["voting-gateway"]   ["*"]   26s

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl get svc istio-ingressgateway -n istio-system
NAME                   TYPE           CLUSTER-IP    EXTERNAL-IP                                                                PORT(S)
                                AGE
istio-ingressgateway   LoadBalancer   10.100.9.13   a1131e5cd8ec9411a98c11749be6db94-1325492322.ap-south-1.elb.amazonaws.com   15021:32433/TCP,80:32538/TCP,443:32073/TCP,31400:31332/TCP,15443:31846/TCP   129m

Minfy@AbhinavBisht MINGW64 ~/OneDrive - MINFY TECHNOLOGIES PRIVATE LIMITED/desktop/k8s-use-cases/istio+cross-acc-ecr (main)
$ kubectl patch svc istio-ingressgateway -n istio-system \
  --type=json \
  -p='[{"op":"add","path":"/spec/ports/-","value":{"name":"http-result","port":81,"targetPort":8081,"protocol":"TCP"}}]'
service/istio-ingressgateway patched
