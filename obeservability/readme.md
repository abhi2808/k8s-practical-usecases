# Observability - Open-Source Prom-Grafana


## What our helm does

The kube-prometheus-stack Helm chart deploys Prometheus, Grafana, and all required metric exporters in a way that is fully Kubernetes-native and largely self-configuring. When installed, it automatically creates Kubernetes Services, ServiceAccounts, ClusterRoles, and ClusterRoleBindings that allow Prometheus to securely discover and scrape metrics from the Kubernetes control plane, nodes, and workloads without any manual port exposure or node-level configuration.

Node-level metrics such as CPU, memory, filesystem, and network usage are collected using node-exporter, which is deployed as a DaemonSet. This ensures that one exporter pod runs on every node. The exporter listens on an internal port (typically 9100) that is not exposed outside the cluster. Prometheus accesses this port using Kubernetes service discovery and the cluster network, meaning no node ports or security group changes are required.

Container and pod-level metrics are collected from the kubelet's built-in cAdvisor endpoint, which runs on each node. The chart configures Prometheus with the correct authentication and TLS settings to securely scrape these endpoints over the cluster network. Access to kubelet metrics is governed by RBAC rules created by the chart, ensuring Prometheus has read-only access to metrics and no broader permissions.

Kubernetes object state (Deployments, Pods, Services, ReplicaSets, etc.) is exposed through kube-state-metrics, which runs as a standard Deployment. This component does not interact with nodes directly; instead, it reads object state from the Kubernetes API server. Prometheus scrapes these metrics via an internal ClusterIP service, again without exposing any external ports.

Grafana itself is deployed as a Deployment with a ClusterIP Service by default. In your case, changing the service type to LoadBalancer instructs Kubernetes to provision an AWS load balancer and expose only port 80 publicly. Internally, this maps to Grafana's container port (3000). No other monitoring component is exposed externally, and no additional ports are opened on worker nodes.

Crucially, the Helm chart does not require you to manually open ports on EC2 instances, configure iptables, or adjust security groups for metric collection. All communication between Prometheus and exporters happens over the Kubernetes overlay network, and AWS security groups only need to allow traffic from the load balancer to the nodes for Grafana access. This design keeps the cluster secure while still providing full observability.

In summary, the Helm chart encapsulates all required networking, port wiring, and access control for observability. The only conscious exposure decision you make is whether Grafana should remain internal or be exposed via a LoadBalancer. Everything else remains private, authenticated, and managed by Kubernetes itself.


# Finally while managing your dashboards:

## DOs (Recommended & Safe)

### 1. Dashboard creation & provisioning
- Do write your own Grafana dashboard JSON (from scratch or by exporting an existing one).
- Do store the dashboard JSON in a ConfigMap in the `monitoring` namespace.
- Do label the ConfigMap with `grafana_dashboard=1`.
- Do apply the ConfigMap and let Grafana auto-provision the dashboard.

### 2. Dashboard customization
- Do modify, delete, or redesign panels in dashboards you own.
- Do create simplified, app-only dashboards (for example, only `brdep` metrics).

### 3. Access control & visibility
- Do organize dashboards using Grafana folders.
- Do restrict user access using Grafana RBAC so users see only selected dashboards.

### 4. Architecture & exposure
- Do expose Grafana via a separate LoadBalancer.
- Do keep Prometheus and node metrics private inside the cluster.

---

## DON'Ts (Not Recommended / Unsafe)

### 1. Helm-managed dashboards
- Don't edit Helm-generated dashboard ConfigMaps (`monitoring-kube-prometheus-*`).
- Don't delete default dashboards directly.
- Don't rely on UI edits for Helm-provisioned dashboards.
- Don't modify where Helm dashboards source their JSON.

### 2. Dashboard JSON constraints
- Don't use panel JSON alone.
- Don't provision anything other than full dashboard JSON.

### 3. Access assumptions
- Don't assume dashboards control visibility.
- Don't expose cluster-level dashboards to users who should not see them (use RBAC).


# If you want to implement alert notifications:

1) Create alertmanager-values.yaml
2) Run helm upgrade

Helm:
- Updates the Alertmanager configuration
- Stores it as a Kubernetes Secret
- Mounts it into the Alertmanager pod
- Triggers an automatic config reload




setup:

# Observability - Open-Source Prom-Grafana


## What our helm does

The kube-prometheus-stack Helm chart deploys Prometheus, Grafana, and all required metric exporters in a way that is fully Kubernetes-native and largely self-configuring. When installed, it automatically creates Kubernetes Services, ServiceAccounts, ClusterRoles, and ClusterRoleBindings that allow Prometheus to securely discover and scrape metrics from the Kubernetes control plane, nodes, and workloads without any manual port exposure or node-level configuration.

Node-level metrics such as CPU, memory, filesystem, and network usage are collected using node-exporter, which is deployed as a DaemonSet. This ensures that one exporter pod runs on every node. The exporter listens on an internal port (typically 9100) that is not exposed outside the cluster. Prometheus accesses this port using Kubernetes service discovery and the cluster network, meaning no node ports or security group changes are required.

Container and pod-level metrics are collected from the kubelet's built-in cAdvisor endpoint, which runs on each node. The chart configures Prometheus with the correct authentication and TLS settings to securely scrape these endpoints over the cluster network. Access to kubelet metrics is governed by RBAC rules created by the chart, ensuring Prometheus has read-only access to metrics and no broader permissions.

Kubernetes object state (Deployments, Pods, Services, ReplicaSets, etc.) is exposed through kube-state-metrics, which runs as a standard Deployment. This component does not interact with nodes directly; instead, it reads object state from the Kubernetes API server. Prometheus scrapes these metrics via an internal ClusterIP service, again without exposing any external ports.

Grafana itself is deployed as a Deployment with a ClusterIP Service by default. In your case, changing the service type to LoadBalancer instructs Kubernetes to provision an AWS load balancer and expose only port 80 publicly. Internally, this maps to Grafana's container port (3000). No other monitoring component is exposed externally, and no additional ports are opened on worker nodes.

Crucially, the Helm chart does not require you to manually open ports on EC2 instances, configure iptables, or adjust security groups for metric collection. All communication between Prometheus and exporters happens over the Kubernetes overlay network, and AWS security groups only need to allow traffic from the load balancer to the nodes for Grafana access. This design keeps the cluster secure while still providing full observability.

In summary, the Helm chart encapsulates all required networking, port wiring, and access control for observability. The only conscious exposure decision you make is whether Grafana should remain internal or be exposed via a LoadBalancer. Everything else remains private, authenticated, and managed by Kubernetes itself.


# Finally while managing your dashboards:

## DOs (Recommended & Safe)

### 1. Dashboard creation & provisioning
- Do write your own Grafana dashboard JSON (from scratch or by exporting an existing one).
- Do store the dashboard JSON in a ConfigMap in the `monitoring` namespace.
- Do label the ConfigMap with `grafana_dashboard=1`.
- Do apply the ConfigMap and let Grafana auto-provision the dashboard.

### 2. Dashboard customization
- Do modify, delete, or redesign panels in dashboards you own.
- Do create simplified, app-only dashboards (for example, only `brdep` metrics).

### 3. Access control & visibility
- Do organize dashboards using Grafana folders.
- Do restrict user access using Grafana RBAC so users see only selected dashboards.

### 4. Architecture & exposure
- Do expose Grafana via a separate LoadBalancer.
- Do keep Prometheus and node metrics private inside the cluster.

---

## DON'Ts (Not Recommended / Unsafe)

### 1. Helm-managed dashboards
- Don't edit Helm-generated dashboard ConfigMaps (`monitoring-kube-prometheus-*`).
- Don't delete default dashboards directly.
- Don't rely on UI edits for Helm-provisioned dashboards.
- Don't modify where Helm dashboards source their JSON.

### 2. Dashboard JSON constraints
- Don't use panel JSON alone.
- Don't provision anything other than full dashboard JSON.

### 3. Access assumptions
- Don't assume dashboards control visibility.
- Don't expose cluster-level dashboards to users who should not see them (use RBAC).


# If you want to implement alert notifications:

1) Create alertmanager-values.yaml
2) Run helm upgrade

Helm:
- Updates the Alertmanager configuration
- Stores it as a Kubernetes Secret
- Mounts it into the Alertmanager pod
- Triggers an automatic config reload



setup:


```bash

AbhinavBisht MINGW64 ~/OneDrive/desktop/use-cases/app-deployment-eks
$ helm version
version.BuildInfo{Version:"v4.1.0", GitCommit:"4553a0a96e5205595079b6757236cc6f969ed1b9", GitTreeState:"clean", GoVersion:"go1.25.6", KubeClientVersion:"v1.35"}

AbhinavBisht MINGW64 ~/OneDrive/desktop/use-cases/app-deployment-eks
$ kubectl create namespace monitoring
namespace/monitoring created

AbhinavBisht MINGW64 ~/OneDrive/desktop/use-cases/app-deployment-eks
$ kubectl get namespaces
NAME              STATUS   AGE
default           Active   26h
kube-node-lease   Active   26h
kube-public       Active   26h
kube-system       Active   26h
monitoring        Active   63s

AbhinavBisht MINGW64 ~/OneDrive/desktop/use-cases/app-deployment-eks
$ helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
"prometheus-community" has been added to your repositories
Hang tight while we grab the latest from your chart repositories...
...Successfully got an update from the "prometheus-community" chart repository
Update Complete. Happy Helming!

AbhinavBisht MINGW64 ~/OneDrive/desktop/use-cases/app-deployment-eks
$ helm install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring
NAME: monitoring
LAST DEPLOYED: Tue Feb 10 15:03:38 2026
NAMESPACE: monitoring
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete
NOTES:
kube-prometheus-stack has been installed. Check its status by running:
  kubectl --namespace monitoring get pods -l "release=monitoring"

AbhinavBisht MINGW64 ~/OneDrive/desktop/use-cases/app-deployment-eks
$ kubectl apply -f monitoring-grafana-svc.yaml
error: the path "monitoring-grafana-svc.yaml" does not exist

AbhinavBisht MINGW64 ~/OneDrive/desktop/use-cases/app-deployment-eks
$ kubectl apply -f C:\\Users\\AbhinavBisht\\AppData\\Local\\Temp\\kubectl.exe-edit-3503235381.yaml
Warning: resource services/monitoring-grafana is missing the kubectl.kubernetes.io/last-applied-configuration annotation which is required by kubectl apply. kubectl apply should only be used on resources created declaratively by either kubectl create --save-config or kubectl apply. The missing annotation will be patched automatically.
service/monitoring-grafana configured

AbhinavBisht MINGW64 ~/OneDrive/desktop/use-cases/app-deployment-eks
$ kubectl get services -n
error: flag needs an argument: 'n' in -n
See 'kubectl get --help' for usage.

AbhinavBisht MINGW64 ~/OneDrive/desktop/use-cases/app-deployment-eks
$ kubectl get services -n monitoring
NAME                                      TYPE           CLUSTER-IP       EXTERNAL-IP                                                               PORT(S)
     AGE
alertmanager-operated                     ClusterIP      None             <none>                                                                    9093/TCP,9094/TCP,9094/UDP   15m
monitoring-grafana                        LoadBalancer   10.100.189.17    a139890e7734b46cfb901538eaefdc2a-187042770.ap-south-1.elb.amazonaws.com   80:30955/TCP
     15m
monitoring-kube-prometheus-alertmanager   ClusterIP      10.100.251.98    <none>                                                                    9093/TCP,8080/TCP            15m
monitoring-kube-prometheus-operator       ClusterIP      10.100.129.107   <none>                                                                    443/TCP
     15m
monitoring-kube-prometheus-prometheus     ClusterIP      10.100.45.97     <none>                                                                    9090/TCP,8080/TCP            15m
monitoring-kube-state-metrics             ClusterIP      10.100.135.85    <none>                                                                    8080/TCP
     15m
monitoring-prometheus-node-exporter       ClusterIP      10.100.217.182   <none>                                                                    9100/TCP
     15m
prometheus-operated                       ClusterIP      None             <none>                                                                    9090/TCP
     15m

AbhinavBisht MINGW64 ~/OneDrive/desktop/use-cases/app-deployment-eks
$ kubectl describe service monitoring-grafana -n monitoring
Name:                     monitoring-grafana
Namespace:                monitoring
Labels:                   app.kubernetes.io/instance=monitoring
                          app.kubernetes.io/managed-by=Helm
                          app.kubernetes.io/name=grafana
                          app.kubernetes.io/version=12.3.2
                          helm.sh/chart=grafana-11.1.0
Annotations:              meta.helm.sh/release-name: monitoring
                          meta.helm.sh/release-namespace: monitoring
                          service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
Selector:                 app.kubernetes.io/instance=monitoring,app.kubernetes.io/name=grafana
Type:                     LoadBalancer
IP Family Policy:         SingleStack
IP Families:              IPv4
IP:                       10.100.189.17
IPs:                      10.100.189.17
LoadBalancer Ingress:     a139890e7734b46cfb901538eaefdc2a-187042770.ap-south-1.elb.amazonaws.com
Port:                     http-web  80/TCP
TargetPort:               grafana/TCP
NodePort:                 http-web  30955/TCP
Endpoints:                172.31.59.120:3000
Session Affinity:         None
External Traffic Policy:  Cluster
Internal Traffic Policy:  Cluster
Events:
  Type    Reason                Age    From                Message
  ----    ------                ----   ----                -------
  Normal  EnsuringLoadBalancer  3m56s  service-controller  Ensuring load balancer
  Normal  EnsuredLoadBalancer   3m53s  service-controller  Ensured load balancer

AbhinavBisht MINGW64 ~/OneDrive/desktop/use-cases/app-deployment-eks
$ kubectl get secret monitoring-grafana -n monitoring \
  -o jsonpath="{.data.admin-password}" | base64 --decode
do0aLTq5PIde............

```