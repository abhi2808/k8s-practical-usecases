# Central Observability Stack — Multi-Account EKS Monitoring

**Prometheus · Loki · Tempo · Grafana**  
Metrics + Logs + Traces from multiple EKS clusters across AWS accounts, unified in a single Grafana instance.

---

## Architecture

```
  Client Account A                          Client Account B
  ┌─────────────────────────┐              ┌────────────────────┐
  │  EKS Cluster-1          │              │  EKS Cluster-3     │
  │  ┌─────────────────┐    │              │  ┌──────────────┐  │
  │  │ kube-prom-stack │    │              │  │kube-prom-stk │  │
  │  │ fluent-bit      │    │              │  │fluent-bit    │  │
  │  │ otel-collector  │    │              │  │otel-collector│  │
  │  └────────┬────────┘    │              │  └──────┬───────┘  │
  └───────────┼─────────────┘              └─────────┼──────────┘
              │  :9090  remote_write  (metrics)      │
              │  :3100  loki push     (logs)         │
              │  :4317  otlp grpc     (traces)       │
              └──────────────────┬───────────────────┘
                                 ▼
                   ┌─────────────────────────┐
                   │  Central EC2            │
                   │  Prometheus  :9090      │
                   │  Loki        :3100      │
                   │  Tempo 2.4.2 :3200/4317 │
                   └────────────┬────────────┘
                                ▼
                   ┌─────────────────────────┐
                   │  Grafana EC2  :3000     │
                   │  Monitor-1 (Accounts)   │
                   │  Monitor-2 (Clusters)   │
                   │  Monitor-3 (Detail +    │
                   │  Metrics + Logs+Traces) │
                   └─────────────────────────┘
```

### Label Strategy

Every metric, log stream, and trace is stamped with two labels that identify its origin. All dashboard drill-downs depend on these exact names:

| Label | Example | Where it's set |
|-------|---------|----------------|
| `awsAccount` | `account-1` | Prometheus `externalLabels`, Fluent Bit `record_modifier` + `Labels` line, OTel `resource` processor |
| `clusterName` | `cluster-1` | Prometheus `externalLabels`, Fluent Bit `record_modifier` + `Labels` line, OTel `resource` processor |

### Port Reference

| Port | Direction | Purpose |
|------|-----------|---------|
| `9090` | EKS → Central EC2, Grafana → Central EC2 | Prometheus remote_write receive + query |
| `3100` | EKS → Central EC2, Grafana → Central EC2 | Loki log push + query |
| `3200` | Grafana → Central EC2 | Tempo HTTP query API |
| `4317` | EKS → Central EC2 | OTel gRPC trace ingestion |
| `4318` | EKS → Central EC2 | OTel HTTP trace ingestion (alternate) |
| `3000` | Browser → Grafana EC2 | Grafana UI |
| `22`   | Your IP → both EC2s | SSH |

---

## Prerequisites

**Local machine:**
- AWS CLI configured with IAM credentials for each account
- `kubectl`
- `helm v3+`

**Both EC2 instances:**
- Docker installed and running
- Security groups open for the ports listed above

---

## Part 1 — Central EC2 Setup

SSH into the central EC2 for all steps in this section.

---

### Step 1 — Central Prometheus

> WARNING: **`--web.enable-remote-write-receiver` is a CLI flag — never put it inside `prometheus.yml`.** The container will crash on startup if it appears in the config file.

> WARNING: **Prometheus running inside Docker cannot reach other containers via `localhost`.** Use the EC2 **private IP** for any inter-container URLs (e.g. scraping Tempo). Get it with: `hostname -I | awk '{print $1}'`

**Create config:**

```yaml
# ~/central-prometheus/prometheus.yml

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

  - job_name: 'tempo'
    static_configs:
      - targets: ['<PRIVATE_EC2_IP>:3200']   # Use private IP, NOT localhost
EOF
```

**Run container:**

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

**Verify:**

```bash
curl http://localhost:9090/-/healthy
# Expected: Prometheus Server is Healthy.
```

**If it keeps restarting:**

```bash
docker logs central-prometheus         # read the error first
docker rm -f central-prometheus
chmod 777 ~/central-prometheus/data    # fix permissions
# then re-run the docker run command above
```

**Reload config after changes (without restarting):**

```bash
docker exec central-prometheus kill -HUP 1
```

**Verify Tempo scrape target is up (run after Tempo is started):**

```bash
curl -s 'http://localhost:9090/api/v1/targets' | python3 -m json.tool | grep -A8 'scrapePool.*tempo'
# Look for: "health": "up" and "lastError": ""
```

---

### Step 2 — Central Loki

> WARNING: **Do NOT include `chunk_store_config.max_look_back_period`** — this field was removed in newer Loki versions and causes a parse error + crash. Use `limits_config.reject_old_samples_max_age` instead.

**Create config:**

```bash
mkdir -p ~/central-loki/data
cd ~/central-loki

cat > loki-config.yml << 'EOF'
auth_enabled: false

server:
  http_listen_port: 3100

common:
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    instance_addr: 127.0.0.1
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  reject_old_samples: true
  reject_old_samples_max_age: 168h
  ingestion_rate_mb: 4
  ingestion_burst_size_mb: 8
EOF
```

**Run container:**

```bash
docker run -d \
  --name loki \
  --restart unless-stopped \
  -p 3100:3100 \
  -v ~/central-loki/loki-config.yml:/etc/loki/loki-config.yml \
  -v ~/central-loki/data:/loki \
  grafana/loki:latest \
  -config.file=/etc/loki/loki-config.yml
```

**Verify:**

```bash
curl http://localhost:3100/ready
# Expected: ready
```

**If it keeps restarting (permissions):**

```bash
docker rm -f loki
chmod 777 ~/central-loki/data
# re-run the docker run command above
```

---

### Step 3 — Central Tempo

> CRITICAL: **Always use `grafana/tempo:2.4.2` — NOT `:latest`.** Tempo v2.7+ introduced a partition ring feature that is enabled by default but broken in single-node setups. It causes an `empty ring` error on every query, making traces completely invisible in Grafana.

> WARNING: **Do NOT include a `compactor:` block** — not a valid top-level field in 2.4.x, causes parse error.

> WARNING: **`overrides.metrics_generator_processors` must be at the TOP LEVEL of `overrides:`** — NOT nested under `overrides.defaults.`. Putting it under `defaults` silently does nothing.

> WARNING: **`ingester.lifecycler` is REQUIRED for single-node.** Without it Tempo cannot find itself in the ring and queries return empty ring errors.

> WARNING: **`metrics_generator.storage.remote_write`** is how Tempo pushes span metrics to Prometheus. It does **NOT** expose them on `/metrics` for scraping. Use the EC2 private IP, not localhost.

**Create config:**

```bash
mkdir -p ~/central-tempo/data
cd ~/central-tempo

cat > tempo-config.yml << 'EOF'
server:
  http_listen_port: 3200

distributor:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318

ingester:
  max_block_duration: 5m
  lifecycler:
    ring:
      replication_factor: 1
      kvstore:
        store: inmemory
    address: 127.0.0.1
    final_sleep: 0s

metrics_generator:
  registry:
    external_labels:
      source: tempo
  storage:
    path: /tmp/tempo/generator/wal
    remote_write:
      - url: http://<PRIVATE_EC2_IP>:9090/api/v1/write   # private IP, not localhost
        send_exemplars: true
  processor:
    span_metrics:
      dimensions:
        - service.name
        - http.method
        - http.route
        - http.status_code
        - awsAccount
        - clusterName

storage:
  trace:
    backend: local
    local:
      path: /tmp/tempo/blocks
    wal:
      path: /tmp/tempo/wal

overrides:
  metrics_generator_processors:    # TOP LEVEL — NOT under overrides.defaults
    - span-metrics
EOF
```

**Run container:**

```bash
docker run -d \
  --name tempo \
  --restart unless-stopped \
  -p 3200:3200 \
  -p 4317:4317 \
  -p 4318:4318 \
  -v ~/central-tempo/tempo-config.yml:/etc/tempo/tempo-config.yml \
  -v ~/central-tempo/data:/tmp/tempo \
  grafana/tempo:2.4.2 \
  -config.file=/etc/tempo/tempo-config.yml
```

**Verify:**

```bash
curl http://localhost:3200/ready
# Expected: ready

docker logs tempo --tail=20
# The recurring "warn  no jobs found" is NORMAL — it just means no traces to compact yet.
```

**If it keeps restarting (permissions):**

```bash
docker rm -f tempo
chmod 777 ~/central-tempo/data
# re-run the docker run command above
```

**After adding new span_metrics dimensions — clear the generator WAL so labels regenerate cleanly:**

```bash
docker rm -f tempo
rm -rf ~/central-tempo/data/generator
# re-run the docker run command above
```

---

## Part 2 — Grafana EC2 Setup

SSH into the Grafana EC2.

---

### Step 4 — Run Grafana

```bash
docker run -d \
  --name grafana \
  --restart unless-stopped \
  -p 3000:3000 \
  grafana/grafana:latest
```

Open `http://<GRAFANA_EC2_IP>:3000` — default login: `admin / admin`.

---

### Step 5 — Add Data Sources

Go to **Connections → Data Sources → Add data source** for each:

| Name | Type | URL |
|------|------|-----|
| Prometheus | Prometheus | `http://<CENTRAL_EC2_IP>:9090` |
| Loki | Loki | `http://<CENTRAL_EC2_IP>:3100` |
| Tempo | Tempo | `http://<CENTRAL_EC2_IP>:3200` |

For the **Tempo** datasource — scroll down to **Trace to logs** and set:
- Data source: `Loki`
- Tags: `awsAccount`, `clusterName`

This links traces directly to the matching pod logs in Loki at the same timestamp.

---

### Step 6 — Import Dashboards

**Grafana → Dashboards → New → Import** — import in this order:

1. `monitor-1.json` — account overview table
2. `monitor-2.json` — cluster list per account
3. `monitor-3.json` — full cluster detail (metrics + logs + traces)

> CRITICAL: **Do not change the dashboard UIDs.** They are baked in as `monitor-1`, `monitor-2`, `monitor-3`. The drill-down links between dashboards use these exact UIDs. If changed, clicking an account in Monitor-1 returns a 404.

---

## Part 3 — Per-Cluster Agent Setup

**Repeat Steps 7–10 for every EKS cluster.** Switch `kubectl` context to the target cluster before each install. Only the values files change — the Helm commands are identical.

---

### Step 7 — Pull Kubeconfig

```bash
aws eks update-kubeconfig --name <cluster-name> --region ap-south-1 --profile <account-profile>

# Verify
kubectl get nodes
```

---

### Step 8 — kube-prometheus-stack (Metrics)

> WARNING: **`alertmanager`, `grafana`, `nodeExporter`, `kubeStateMetrics` must be at the TOP LEVEL of the values file** — NOT nested inside `prometheus:`. Only `prometheusSpec:` goes under `prometheus:`. Nesting them inside `prometheus:` causes them to deploy with wrong or default config.

**Create values file — `prom-values-account1-cluster1.yml`:**

```yaml
prometheus:
  prometheusSpec:
    externalLabels:
      awsAccount: account-1     # change per cluster
      clusterName: cluster-1    # change per cluster
    remoteWrite:
      - url: "http://<CENTRAL_EC2_IP>:9090/api/v1/write"
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

**Install:**

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

kubectl create namespace monitoring

helm install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f prom-values-account1-cluster1.yml
```

**Verify:**

```bash
kubectl get pods -n monitoring

kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus --tail=20
# Healthy = deprecation warnings only. No WARN/ERROR about the remote_write URL.
# Error "dial tcp: lookup ...: no such host" = placeholder IP still in values file.
```

**Upgrade after changing values:**

```bash
helm upgrade prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f prom-values-account1-cluster1.yml
```

---

### Step 9 — Fluent Bit (Logs)

> WARNING: **`awsAccount` and `clusterName` must appear in TWO places:**
> 1. In the `[FILTER] record_modifier` block — adds them to the log record body
> 2. In the `[OUTPUT] Labels` line — stamps them as Loki stream labels
>
> Missing from either = labels won't be queryable in Grafana.
> Use the static `Labels` line — do NOT use `Label_Keys`.

**Create values file — `fluent-bit-values-account1-cluster1.yml`:**

```yaml
config:
  inputs: |
    [INPUT]
        Name              tail
        Path              /var/log/containers/*.log
        multiline.parser  docker, cri
        Tag               kube.*
        Mem_Buf_Limit     50MB
        Skip_Long_Lines   On

  filters: |
    [FILTER]
        Name                kubernetes
        Match               kube.*
        Kube_URL            https://kubernetes.default.svc:443
        Kube_CA_File        /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        Kube_Token_File     /var/run/secrets/kubernetes.io/serviceaccount/token
        Kube_Tag_Prefix     kube.var.log.containers.
        Merge_Log           On
        Keep_Log            Off
        K8S-Logging.Parser  On
        K8S-Logging.Exclude On

    [FILTER]
        Name    record_modifier
        Match   kube.*
        Record  awsAccount account-1    # change per cluster
        Record  clusterName cluster-1   # change per cluster

  outputs: |
    [OUTPUT]
        Name         loki
        Match        kube.*
        Host         <CENTRAL_EC2_IP>
        Port         3100
        Labels       job=fluent-bit,awsAccount=account-1,clusterName=cluster-1
        line_format  json
```

**Install:**

```bash
helm repo add fluent https://fluent.github.io/helm-charts
helm repo update

helm install fluent-bit fluent/fluent-bit \
  -n monitoring \
  -f fluent-bit-values-account1-cluster1.yml
```

**Verify:**

```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=fluent-bit

kubectl logs -n monitoring -l app.kubernetes.io/name=fluent-bit --tail=20
# Healthy:  lines showing [output:loki:loki.0] <CENTRAL_EC2_IP>:3100 ... OK
# Bad:      "Misformatted domain name" = placeholder IP still in values file
# Bad:      "no upstream connections" = port 3100 blocked in security group
```

**Upgrade after changing values:**

```bash
helm upgrade fluent-bit fluent/fluent-bit \
  -n monitoring \
  -f fluent-bit-values-account1-cluster1.yml
```

---

### Step 10 — OTel Collector (Traces)

> WARNING: **`image.repository` MUST point to `ghcr.io`** — DockerHub OTel image is deprecated. Without this the chart errors: `[ERROR] 'image.repository' must be set`.

> WARNING: **`command.name: otelcol-k8s` is REQUIRED** when using the k8s distro image.

> WARNING: **`service.enabled: true` is REQUIRED.** Daemonset mode does not create a Kubernetes Service by default. Without it, the auto-instrumentation DNS lookup (`otel-collector-opentelemetry-collector.monitoring.svc.cluster.local`) fails and no traces reach the collector.

**Create values file — `otel-values-account1-cluster1.yml`:**

```yaml
image:
  repository: ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-k8s

command:
  name: otelcol-k8s

mode: daemonset

config:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318

  processors:
    batch: {}
    resource:
      attributes:
        - key: awsAccount
          value: "account-1"    # change per cluster
          action: upsert
        - key: clusterName
          value: "cluster-1"    # change per cluster
          action: upsert

  exporters:
    otlp:
      endpoint: "<CENTRAL_EC2_IP>:4317"
      tls:
        insecure: true

  service:
    pipelines:
      traces:
        receivers: [otlp]
        processors: [resource, batch]
        exporters: [otlp]

ports:
  otlp:
    enabled: true
    containerPort: 4317
    servicePort: 4317
    protocol: TCP
  otlp-http:
    enabled: true
    containerPort: 4318
    servicePort: 4318
    protocol: TCP

service:
  enabled: true
  type: ClusterIP
```

**Install:**

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

helm install otel-collector open-telemetry/opentelemetry-collector \
  -n monitoring \
  -f otel-values-account1-cluster1.yml
```

**Verify:**

```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=opentelemetry-collector

# MUST show a ClusterIP service with ports 4317 and 4318
kubectl get svc -n monitoring | grep otel

kubectl logs -n monitoring -l app.kubernetes.io/name=opentelemetry-collector --tail=20
# Healthy: "Everything is ready. Begin running and processing data."
```

**Upgrade after changing values:**

```bash
helm upgrade otel-collector open-telemetry/opentelemetry-collector \
  -n monitoring \
  -f otel-values-account1-cluster1.yml
```

---

## Part 4 — App Auto-Instrumentation (No Code Changes)

The OTel Operator injects instrumentation via an init container — no source code changes or image rebuilds required.

---

### Step 11 — Install cert-manager

> CRITICAL: **cert-manager MUST be fully `Running` before installing the OTel Operator.** The operator needs cert-manager to generate its webhook TLS certificate. If you install the operator first, it will be stuck with a missing secret error. Fix: delete the operator, install cert-manager, wait for Ready, reinstall the operator.

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

# Wait — all 3 pods must be 1/1 Running before proceeding
kubectl get pods -n cert-manager -w
```

---

### Step 12 — Install OTel Operator

```bash
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml

# Verify TLS cert was created by cert-manager
kubectl get certificate -n opentelemetry-operator-system

# Verify operator pod is 1/1 Running
kubectl get pods -n opentelemetry-operator-system -w
```

---

### Step 13 — Create Instrumentation CR

**Create `instrumentation.yaml`:**

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: python-instrumentation
  namespace: default
spec:
  exporter:
    endpoint: http://otel-collector-opentelemetry-collector.monitoring.svc.cluster.local:4318
  propagators:
    - tracecontext
    - baggage
  python:
    env:
      - name: OTEL_SERVICE_NAME
        value: sample-app
      - name: OTEL_RESOURCE_ATTRIBUTES
        value: awsAccount=account-1,clusterName=cluster-1
      - name: OTEL_EXPORTER_OTLP_PROTOCOL
        value: http/protobuf
```

> NOTE: The endpoint uses HTTP port `:4318`, not gRPC `:4317`. Python OTel SDK defaults to HTTP.  
> NOTE: `OTEL_EXPORTER_OTLP_PROTOCOL: http/protobuf` must be set explicitly for Python.  
> NOTE: For other runtimes: change `python:` to `java:`, `nodejs:`, or `dotnet:` and change the annotation in Step 14 accordingly.

```bash
kubectl apply -f instrumentation.yaml
# "Warning: sampler type not set" is expected and harmless.
```

---

### Step 14 — Annotate the Deployment

Add one annotation to the pod template in your deployment spec:

```yaml
# Under spec.template.metadata.annotations:
annotations:
  instrumentation.opentelemetry.io/inject-python: "true"
```

```bash
kubectl apply -f dep.yml

# Verify init container was injected (pods must restart for annotation to take effect)
kubectl describe pod -l app=sample-app -n default | grep -A5 'Init Containers'
# Expected: opentelemetry-auto-instrumentation-python

# Confirm pods are 1/1 Running
kubectl get pods -n default -w
```

---

## Part 5 — End-to-End Verification

### Metrics

```bash
# Both awsAccount and clusterName must appear for every cluster
curl -s 'http://<CENTRAL_EC2_IP>:9090/api/v1/query?query=count+by+(awsAccount,clusterName)(up)' \
  | python3 -m json.tool
```

### Logs

```bash
# Check label exists in Loki
curl -s 'http://<CENTRAL_EC2_IP>:3100/loki/api/v1/label/awsAccount/values' | python3 -m json.tool

# In Grafana → Explore → Loki
{awsAccount="account-1", clusterName="cluster-1"}
```

### Traces

```bash
# Generate some traffic first
kubectl port-forward svc/<your-app-svc> 5000:80 -n default
# In a second terminal:
curl http://localhost:5000/
curl http://localhost:5000/order

# Wait ~15 seconds for batch processor to flush, then check Tempo received traces
curl -s 'http://<CENTRAL_EC2_IP>:3200/api/search?limit=5' | python3 -m json.tool

# In Grafana → Explore → Tempo → TraceQL
{ resource.service.name = "sample-app" }
```

### Span Metrics (Request Rate + Latency panels in Monitor-3)

```bash
# Verify span metrics arrived in Prometheus via Tempo remote_write
curl -s 'http://<CENTRAL_EC2_IP>:9090/api/v1/query?query=traces_spanmetrics_calls_total' \
  | python3 -m json.tool | grep -E 'awsAccount|clusterName|service_name'
# Expected: awsAccount, clusterName, service_name labels on every result
```

### Full Checklist

| Check | Command | Expected |
|-------|---------|----------|
| Prometheus healthy | `curl http://<CENTRAL_EC2_IP>:9090/-/healthy` | `Prometheus Server is Healthy.` |
| Loki healthy | `curl http://<CENTRAL_EC2_IP>:3100/ready` | `ready` |
| Tempo healthy | `curl http://<CENTRAL_EC2_IP>:3200/ready` | `ready` |
| Metrics flowing | Grafana → Prometheus → Test | Green ✅ |
| Logs flowing | Grafana → Loki → Explore `{awsAccount=...}` | Log lines visible |
| Traces flowing | Grafana → Tempo → TraceQL | Trace list visible |
| OTel init injected | `kubectl describe pod -l app=... \| grep Init` | `opentelemetry-auto-instrumentation-python` |
| Span metrics | `traces_spanmetrics_calls_total` in Prometheus | Labels: `awsAccount`, `clusterName`, `service_name` |

---

## Adding a New Cluster

The central stack needs no changes. Create three values files, change only the two labels, run three Helm installs.

| File | Fields to change |
|------|-----------------|
| `prom-values-<account>-<cluster>.yml` | `awsAccount`, `clusterName` under `prometheusSpec.externalLabels` |
| `fluent-bit-values-<account>-<cluster>.yml` | `awsAccount`, `clusterName` in `record_modifier` block **AND** in `Labels` line |
| `otel-values-<account>-<cluster>.yml` | `awsAccount`, `clusterName` under `config.processors.resource.attributes` |

```bash
# 1. Pull kubeconfig
aws eks update-kubeconfig --name <new-cluster> --region ap-south-1 --profile <account-profile>

# 2. Create namespace
kubectl create namespace monitoring

# 3. Install all three agents
helm install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring -f prom-values-<account>-<cluster>.yml

helm install fluent-bit fluent/fluent-bit \
  -n monitoring -f fluent-bit-values-<account>-<cluster>.yml

helm install otel-collector open-telemetry/opentelemetry-collector \
  -n monitoring -f otel-values-<account>-<cluster>.yml

# 4. Install cert-manager + OTel Operator (if not already on this cluster)
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
kubectl get pods -n cert-manager -w   # wait for all 1/1
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml

# 5. Apply Instrumentation CR and annotate deployment
kubectl apply -f instrumentation.yaml
kubectl apply -f dep.yml
```

---

## Troubleshooting

| Symptom | Root Cause | Fix |
|---------|-----------|-----|
| Container restarts immediately | `--web.enable-remote-write-receiver` or `chunk_store_config` in yml | Remove from yml — CLI flags go in `docker run` only |
| Container restarts (permissions) | Data folder not writable | `chmod 777 ~/central-<service>/data`, `docker rm -f <container>`, re-run |
| Tempo: `empty ring` error in Grafana | Using `grafana/tempo:latest` (v2.7+ bug) | Pin to `grafana/tempo:2.4.2` |
| Tempo: span metrics never appear | `overrides.defaults.metrics_generator.processors` used | Use `overrides.metrics_generator_processors` at top level |
| Tempo: new dimensions missing from metrics | Old WAL has metrics without new labels | `docker rm -f tempo && rm -rf ~/central-tempo/data/generator`, re-run |
| Prometheus can't scrape Tempo | `localhost:3200` in `prometheus.yml` | Use private EC2 IP (`hostname -I \| awk '{print $1}'`) |
| Fluent Bit: `Misformatted domain name` | Placeholder IP still in values | Replace with actual IP, `helm upgrade` |
| Fluent Bit: `no upstream connections` | Port 3100 blocked in security group | Add inbound TCP 3100 rule |
| No `awsAccount` label on metrics | `externalLabels` nested wrong in prom values | Must be under `prometheusSpec:`, not `prometheus:` |
| Traces: DNS resolution error in pod logs | OTel Collector Service not created | Add `service.enabled: true` to otel values, `helm upgrade` |
| OTel Operator stuck `ContainerCreating` | cert-manager not installed first | Delete operator, install cert-manager, wait for Ready, reinstall operator |
| No traces after app restart | Collector Service DNS wrong or absent | `kubectl get svc -n monitoring \| grep otel` — confirm ClusterIP exists |
| Monitor-1 click → 404 | Dashboard UID mismatch | Set UID to exactly `monitor-2` in Grafana Dashboard Settings |

---

## Dashboard Reference

| Dashboard | UID | Content | Click Action |
|-----------|-----|---------|-------------|
| Monitor-1 | `monitor-1` | Account overview — health, node count, running/failed pods, CPU%, Memory% per account | Click account → Monitor-2 |
| Monitor-2 | `monitor-2` | Cluster list — same stats per cluster within the selected account | Click cluster → Monitor-3 |
| Monitor-3 | `monitor-3` | Full cluster detail — node stats, pod tables, namespace breakdown, network graphs, all logs, error logs, trace list | Trace ID → full span waterfall |

### Monitor-3 Traces Section

| Panel | Data Source | Query |
|-------|------------|-------|
| Request Rate by Service | Prometheus | `rate(traces_spanmetrics_calls_total{awsAccount="$account",clusterName="$cluster"}[5m])` |
| Latency p50/p95/p99 | Prometheus | `histogram_quantile(0.95, sum(rate(traces_spanmetrics_latency_bucket{...}[5m])) by (le, service_name))` |
| Recent Traces | Tempo (TraceQL) | `{ resource.awsAccount = "$account" && resource.clusterName = "$cluster" }` |


> NOTE: Request Rate and Latency panels require span metrics flowing from Tempo → Prometheus. Verify with `traces_spanmetrics_calls_total`.  
> NOTE: Recent Traces queries Tempo directly — works as soon as traces are flowing, no span metrics needed.

---

*Minfy Technologies — Internal Documentation*