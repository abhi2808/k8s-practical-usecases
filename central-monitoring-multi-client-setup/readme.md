# Central K8s Monitoring — Multi-Client Setup

> Prometheus + Grafana across multiple EKS clusters, all funneled into one place.

---

## What We Built

Two client EKS clusters, each running their own Prometheus that stamps every metric with a `clientName` label and ships it to a single central Prometheus sitting on an EC2. Grafana sits on another EC2, points at that central Prometheus, and serves two dashboards — one that lists all clients at a glance, and one that drills into a specific client's cluster when you click on them.

No LoadBalancers. No Ingress. No exposing your clusters to the world. Prometheus just pushes data *out* — outbound traffic from EKS is open by default in AWS, so it just works.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           AWS ap-south-1                                │
│                                                                         │
│  ┌─────────────────────────────┐   ┌─────────────────────────────┐      │
│  │        client-1-eks         │   │        client-2-eks         │      │
│  │                             │   │                             │      │
│  │  ┌───────────────────────┐  │   │  ┌───────────────────────┐  │      │
│  │  │  kube-prometheus-     │  │   │  │  kube-prometheus-     │  │      │
│  │  │  stack (Helm)         │  │   │  │  stack (Helm)         │  │      │
│  │  │                       │  │   │  │                       │  │      │
│  │  │  • Prometheus         │  │   │  │  • Prometheus         │  │      │
│  │  │  • node-exporter      │  │   │  │  • node-exporter      │  │      │
│  │  │  • kube-state-metrics │  │   │  │  • kube-state-metrics │  │      │
│  │  │                       │  │   │  │                       │  │      │
│  │  │  externalLabel:       │  │   │  │  externalLabel:       │  │      │
│  │  │  clientName=client-1  │  │   │  │  clientName=client-2  │  │      │
│  │  └───────────┬───────────┘  │   │  └───────────┬───────────┘  │      │
│  └──────────────│──────────────┘   └──────────────│──────────────┘      │
│                 │  remote_write                   │  remote_write       │
│                 │  (outbound, port 9090)          │  (outbound, 9090)   │
│                 └──────────────────┬──────────────┘                     │ 
│                                    ▼                                    │
│                     ┌────────────────────────── ┐                       │
│                     │    Central Prometheus     │                       │
│                     │    EC2 · Docker           │                       │
│                     │    65.0.81.49:9090        │                       │
│                     │                           │                       │
│                     │  --web.enable-remote-     │                       │
│                     │    write-receiver         │                       │
│                     └──────────────┬────────────┘                       │
│                                    │  data source (port 9090)           │
│                                    ▼                                    │
│                     ┌──────────────────────────┐                        │ 
│                     │         Grafana          │                        │
│                     │    EC2 · Docker          │                        │
│                     │    15.206.153.237:3000   │                        │
│                     │                          │                        │
│                     │  Monitor-1 (overview)    │                        │
│                     │  Monitor-2 (per client)  │                        │
│                     └──────────────────────────┘                        │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Folder Structure

```
central-k8s-monitoring/
├── README.md                  ← you are here
├── prom-values-client1.yml    ← helm values for client-1 cluster
├── prom-values-client2.yml    ← helm values for client-2 cluster
├── monitor-1.json             ← grafana dashboard: clients overview
└── monitor-2.json             ← grafana dashboard: per-client cluster detail
```

---

## Before You Start

Make sure you have these installed locally:
- AWS CLI (configured with the right IAM creds)
- `kubectl`
- `helm` v3+

And on both EC2 instances:
- Docker

---

## Step 0 — EKS Clusters

Two EKS clusters (`client-1-eks`, `client-2-eks`) were created with node groups in `ap-south-1`. Once up, pull the kubeconfigs:

```bash
aws eks update-kubeconfig --name client-1-eks --region ap-south-1
aws eks update-kubeconfig --name client-2-eks --region ap-south-1
```

Verify both are reachable:

```bash
kubectl get nodes   # switch context between clusters to check both
```

---

## Step 1 — Spin Up Grafana on EC2

SSH into your Grafana EC2 and run:

```bash
docker run -d \
  --name grafana \
  --restart unless-stopped \
  -p 3000:3000 \
  grafana/grafana:latest
```

Hit `http://<grafana-public-ip>:3000` in the browser. Default login is `admin / admin`.

**Security group — open on the Grafana EC2:**
- Port `3000` inbound — from anywhere (or restrict to your IP)
- Port `22` inbound — your IP for SSH

---

## Step 2 — Spin Up Central Prometheus on EC2

This is the one that receives all the data from the clusters. SSH into your central Prometheus EC2.

### Create the config file

```bash
mkdir -p ~/central-prometheus/data
cd ~/central-prometheus

cat > prometheus.yml << 'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'central-prometheus'
    static_configs:
      - targets: ['localhost:9090']
EOF
```

> Just this. Nothing else in the yml. The `remote_write_receiver` thing is a **CLI flag**, not a config field — don't put it in the yml or the container will crash on startup.

### Run it

```bash
docker run -d \
  --name central-prometheus \
  --restart unless-stopped \
  -p 9090:9090 \
  -v ~/central-prometheus/prometheus.yml:/etc/prometheus/prometheus.yml \
  -v ~/central-prometheus/data:/prometheus \
  prom/prometheus:latest \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/prometheus \
  --storage.tsdb.retention.time=30d \
  --web.enable-remote-write-receiver \
  --web.console.libraries=/usr/share/prometheus/console_libraries \
  --web.console.templates=/usr/share/prometheus/consoles
```

> Don't put inline `#` comments after the `\` line continuations — bash will break the command.

Check it's actually running and not just restarting:

```bash
docker ps
curl http://localhost:9090/-/healthy
# Should say: Prometheus Server is Healthy.
```

If it keeps restarting, check logs first:

```bash
docker logs central-prometheus
```

Common causes:
- Something wrong in the yml → check for typos or extra fields
- Permissions on the data folder → run the below then re-run the docker command

```bash
docker rm -f central-prometheus
chmod 777 ~/central-prometheus/data
```

**Security group — open on the Central Prometheus EC2:**
- Port `9090` inbound — from anywhere (EKS nodes push to this, Grafana reads from it)
- Port `22` inbound — your IP for SSH

---

## Step 3 — Install Prometheus on Each EKS Cluster

Each cluster gets its own Prometheus via Helm. It scrapes everything inside the cluster and ships it to central Prometheus with a `clientName` label stamped on every metric.

### The values files

Already in this folder. Just make sure the IP is correct in both.

**`prom-values-client1.yml`:**
```yaml
prometheus:
  prometheusSpec:
    externalLabels:
      clientName: client-1
    remoteWrite:
      - url: "http://<CENTRAL_PROMETHEUS_IP>:9090/api/v1/write"
    retention: 2h

alertmanager:
  enabled: false

grafana:
  enabled: false

nodeExporter:
  enabled: true

kubeStateMetrics:
  enabled: true
```

**`prom-values-client2.yml`** — same thing, just `clientName: client-2`.

> `alertmanager`, `grafana`, `nodeExporter`, `kubeStateMetrics` must be at the **top level** of the file — not nested inside `prometheus:`. Only `prometheusSpec` stuff goes under `prometheus:`.

### Install on client-1

```bash
aws eks update-kubeconfig --name client-1-eks --region ap-south-1

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

kubectl create namespace monitoring

helm install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f prom-values-client1.yml
```

### Install on client-2

```bash
aws eks update-kubeconfig --name client-2-eks --region ap-south-1

kubectl create namespace monitoring

helm install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f prom-values-client2.yml
```

### Verify pods are up

```bash
kubectl get pods -n monitoring
```

You should see node-exporter, kube-state-metrics, the operator, and the main prometheus pod all running.

### Verify data is flowing

```bash
kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus --tail=20
```

Healthy = only deprecation warnings about `v1 Endpoints`. No `WARN` or `ERROR` about the remote_write URL.

If you see `dial tcp: lookup <...>: no such host` — the placeholder IP is still in the values file. Fix it and run:

```bash
helm upgrade prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f prom-values-client1.yml   # or client2
```

---

## Step 4 — Connect Grafana to Central Prometheus

1. Open Grafana in the browser
2. **Connections → Data Sources → Add data source**
3. Pick **Prometheus**
4. URL: `http://<CENTRAL_PROMETHEUS_IP>:9090`
5. **Save & Test** — should go green ✅

---

## Step 5 — Import the Dashboards

Do this for both `monitor-1.json` and `monitor-2.json`. Import Monitor-1 first.

1. Grafana → **Dashboards** → **New** → **Import**
2. Paste the JSON → **Load** → **Import**

> The dashboard UIDs are baked in as `monitor-1` and `monitor-2`. Don't change them — Monitor-1's client links route to `/d/monitor-2/monitor-2?var-client=...` and if the UID doesn't match, clicking a client will 404.

### What you get

**Monitor-1** — the landing page. A table of all clients with health status, node count, running pods, failed pods, CPU and memory. Click any client name → goes to Monitor-2 for that client, pre-filtered.

**Monitor-2** — the detail view. Driven by a `$client` dropdown that auto-populates from your Prometheus labels. Has node stats, pod tables (running + failed with reasons), namespace breakdowns, network graphs, and resource utilization gauges.

---

## Verify Everything End-to-End

Run this from anywhere that can reach the central Prometheus:

```bash
curl -s "http://<CENTRAL_PROMETHEUS_IP>:9090/api/v1/query?query=count+by+(clientName)(up)" | python3 -m json.tool
```

You should see both clients with non-zero counts:

```json
{
  "status": "success",
  "data": {
    "result": [
      { "metric": { "clientName": "client-1" }, "value": ["...", "19"] },
      { "metric": { "clientName": "client-2" }, "value": ["...", "18"] }
    ]
  }
}
```

Both showing up = pipeline is fully working.

---

## Test the Failure Panels

The "Failed Pods" and "Container Restarts" panels will show "No data" when everything is healthy — which is good. To verify they actually work:

```bash
kubectl run test-broken --image=nginx:this-tag-does-not-exist --restart=Never -n default
```

Wait 30 seconds, refresh Monitor-2 — should show up in the failed pods table with `ImagePullBackOff` as the reason. Clean up after:

```bash
kubectl delete pod test-broken -n default
```

---

## Things That Might Catch You Out

- **Container keeps restarting immediately** — `remote_write_receiver: true` was put in the yml. It's a CLI flag, not a config field. Remove it from the yml entirely.

- **Container keeps restarting** — can't write to the data folder. Fix: `chmod 777 ~/central-prometheus/data`, remove the container, re-run.

- **Inline comments breaking docker run** — bash breaks on `# comment` after a `\` line continuation. Never put comments inside a multi-line shell command.

- **Clicking client name in Monitor-1 goes to 404** — dashboard UID doesn't match what the data link expects. Go to Settings and confirm the UID is exactly `monitor-2`.

- **`clientName` label not appearing in Grafana** — `externalLabels` nested in the wrong place in the yml. Must be under `prometheusSpec:`, and `alertmanager`/`grafana`/`nodeExporter` etc. at the top level.
