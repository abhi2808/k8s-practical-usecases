locals {
  kubeconfig_path            = "/tmp/kubeconfig-${var.cluster_name}"
  instrumentation_annotation = "instrumentation.opentelemetry.io/inject-${var.instrumentation_runtime}"
  kubeconfig_env = {
    KUBECONFIG         = "/tmp/kubeconfig-${var.cluster_name}"
    AWS_PROFILE        = var.aws_profile
    AWS_DEFAULT_REGION = var.aws_region
  }

  instrumentation_manifest = <<-MANIFEST
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: ${var.instrumentation_runtime}-instrumentation
  namespace: ${var.instrumentation_app_namespace}
spec:
  exporter:
    endpoint: http://otel-collector-opentelemetry-collector.${var.monitoring_namespace}.svc.cluster.local:4318
  propagators:
    - tracecontext
    - baggage
  ${var.instrumentation_runtime}:
    env:
      - name: OTEL_SERVICE_NAME
        value: ${var.otel_service_name}
      - name: OTEL_RESOURCE_ATTRIBUTES
        value: awsAccount=${var.aws_account_label},clusterName=${var.cluster_name_label}
      - name: OTEL_EXPORTER_OTLP_PROTOCOL
        value: http/protobuf
MANIFEST
}

resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name   = var.monitoring_namespace
    labels = { "managed-by" = "terraform" }
  }
}

resource "helm_release" "kube_prometheus" {
  count            = var.enable_kube_prometheus ? 1 : 0
  name             = "prometheus"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = var.monitoring_namespace
  version          = var.kube_prometheus_chart_version != "" ? var.kube_prometheus_chart_version : null
  create_namespace = false
  wait             = true
  timeout          = 600

  values = [templatefile("${path.module}/templates/kube-prometheus-values.yaml.tpl", {
    aws_account_label  = var.aws_account_label
    cluster_name_label = var.cluster_name_label
    remote_write_url   = var.central_prometheus_remote_write_url
    retention          = var.prometheus_local_retention
  })]

  depends_on = [kubernetes_namespace_v1.monitoring]
}

resource "helm_release" "fluent_bit" {
  count            = var.enable_fluent_bit ? 1 : 0
  name             = "fluent-bit"
  repository       = "https://fluent.github.io/helm-charts"
  chart            = "fluent-bit"
  namespace        = var.monitoring_namespace
  version          = var.fluent_bit_chart_version != "" ? var.fluent_bit_chart_version : null
  create_namespace = false
  wait             = true
  timeout          = 300

  values = [templatefile("${path.module}/templates/fluent-bit-values.yaml.tpl", {
    aws_account_label  = var.aws_account_label
    cluster_name_label = var.cluster_name_label
    loki_host          = var.central_loki_host
    loki_port          = var.central_loki_port
  })]

  depends_on = [kubernetes_namespace_v1.monitoring]
}

resource "helm_release" "otel_collector" {
  count            = var.enable_otel_collector ? 1 : 0
  name             = "otel-collector"
  repository       = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart            = "opentelemetry-collector"
  namespace        = var.monitoring_namespace
  version          = var.otel_collector_chart_version != "" ? var.otel_collector_chart_version : null
  create_namespace = false
  wait             = true
  timeout          = 300

  values = [yamlencode({
    image   = { repository = "ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-k8s" }
    command = { name = "otelcol-k8s" }
    mode    = "daemonset"
    config = {
      receivers = {
        otlp = {
          protocols = {
            grpc = { endpoint = "0.0.0.0:4317" }
            http = { endpoint = "0.0.0.0:4318" }
          }
        }
      }
      processors = {
        batch = {}
        resource = {
          attributes = [
            { key = "awsAccount",  value = var.aws_account_label,  action = "upsert" },
            { key = "clusterName", value = var.cluster_name_label, action = "upsert" },
          ]
        }
      }
      exporters = {
        otlp = {
          endpoint = var.central_otel_grpc_endpoint
          tls      = { insecure = true }
        }
      }
      service = {
        pipelines = {
          traces = {
            receivers  = ["otlp"]
            processors = ["resource", "batch"]
            exporters  = ["otlp"]
          }
        }
      }
    }
    ports = {
      otlp      = { enabled = true, containerPort = 4317, servicePort = 4317, protocol = "TCP" }
      otlp-http = { enabled = true, containerPort = 4318, servicePort = 4318, protocol = "TCP" }
    }
    service = { enabled = true, type = "ClusterIP" }
  })]

  depends_on = [kubernetes_namespace_v1.monitoring]
}

resource "null_resource" "kubeconfig_update" {
  count    = var.enable_otel_operator ? 1 : 0
  triggers = { cluster_name = var.cluster_name, region = var.aws_region }

  provisioner "local-exec" {
    command     = "aws eks update-kubeconfig --name ${var.cluster_name} --region ${var.aws_region} --profile ${var.aws_profile} --kubeconfig ${local.kubeconfig_path}"
    environment = local.kubeconfig_env
  }
}

resource "null_resource" "cert_manager" {
  count    = var.enable_otel_operator ? 1 : 0
  triggers = { cluster_name = var.cluster_name }

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-ExecutionPolicy", "Bypass", "-Command"]
    command     = <<-EOT
      kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml --kubeconfig ${local.kubeconfig_path}
      kubectl rollout status deployment/cert-manager -n cert-manager --timeout=120s --kubeconfig ${local.kubeconfig_path}
      kubectl rollout status deployment/cert-manager-cainjector -n cert-manager --timeout=120s --kubeconfig ${local.kubeconfig_path}
      kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=120s --kubeconfig ${local.kubeconfig_path}

      Write-Host "==> Waiting for cert-manager-webhook endpoint..."
      $max = 36
      $i = 0
      do {
        $i++
        Start-Sleep -Seconds 5
        $ep = kubectl get endpoints cert-manager-webhook -n cert-manager -o jsonpath='{.subsets[0].addresses[0].ip}' --kubeconfig ${local.kubeconfig_path} 2>$null
        Write-Host "Attempt $i endpoint: $ep"
      } while ([string]::IsNullOrEmpty($ep) -and $i -lt $max)

      if ([string]::IsNullOrEmpty($ep)) {
        Write-Host "ERROR: cert-manager-webhook endpoint not ready after 3 minutes"
        exit 1
      }
      Write-Host "==> cert-manager-webhook endpoint ready: $ep"
    EOT
    environment = local.kubeconfig_env
  }

  depends_on = [null_resource.kubeconfig_update]
}

resource "null_resource" "otel_operator" {
  count    = var.enable_otel_operator ? 1 : 0
  triggers = { cluster_name = var.cluster_name }

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-ExecutionPolicy", "Bypass", "-Command"]
    command     = <<-EOT
      $max = 10
      $i = 0
      $ok = $false

      while (-not $ok -and $i -lt $max) {
        $i++
        Write-Host "==> Attempt $i applying OTel Operator..."
        kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml --kubeconfig ${local.kubeconfig_path}
        if ($LASTEXITCODE -eq 0) {
          $ok = $true
        } else {
          Write-Host "==> Apply failed, waiting 20s..."
          Start-Sleep -Seconds 20
        }
      }

      if (-not $ok) { Write-Host "ERROR: OTel Operator apply failed"; exit 1 }

      kubectl rollout status deployment/opentelemetry-operator-controller-manager -n opentelemetry-operator-system --timeout=180s --kubeconfig ${local.kubeconfig_path}

      Write-Host "==> Waiting for OTel Operator webhook endpoint..."
      $j = 0
      do {
        $j++
        Start-Sleep -Seconds 5
        $ep = kubectl get endpoints opentelemetry-operator-webhook-service -n opentelemetry-operator-system -o jsonpath='{.subsets[0].addresses[0].ip}' --kubeconfig ${local.kubeconfig_path} 2>$null
        Write-Host "Attempt $j endpoint: $ep"
      } while ([string]::IsNullOrEmpty($ep) -and $j -lt 36)

      if ([string]::IsNullOrEmpty($ep)) { Write-Host "ERROR: OTel webhook endpoint not ready"; exit 1 }
      Write-Host "==> OTel Operator webhook ready: $ep"
    EOT
    environment = local.kubeconfig_env
  }

  depends_on = [null_resource.cert_manager]
}

resource "null_resource" "instrumentation_cr" {
  count = var.enable_otel_operator ? 1 : 0
  triggers = {
    cluster_name            = var.cluster_name
    aws_account_label       = var.aws_account_label
    cluster_name_label      = var.cluster_name_label
    otel_service_name       = var.otel_service_name
    instrumentation_runtime = var.instrumentation_runtime
    app_namespace           = var.instrumentation_app_namespace
  }

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-ExecutionPolicy", "Bypass", "-Command"]
    command     = <<-EOT
      $max = 10
      $i = 0
      $ok = $false

      $manifest = @'
${local.instrumentation_manifest}
'@

      while (-not $ok -and $i -lt $max) {
        $i++
        Write-Host "==> Attempt $i applying Instrumentation CR..."
        $manifest | kubectl apply -f - --kubeconfig ${local.kubeconfig_path} 2>&1
        if ($LASTEXITCODE -eq 0) {
          $ok = $true
          Write-Host "==> Instrumentation CR applied successfully"
        } else {
          Write-Host "==> Not ready yet, waiting 15s..."
          Start-Sleep -Seconds 15
        }
      }

      if (-not $ok) { Write-Host "ERROR: Instrumentation CR failed"; exit 1 }
    EOT
    environment = local.kubeconfig_env
  }

  depends_on = [null_resource.otel_operator, helm_release.otel_collector]
}

resource "null_resource" "annotate_deployment" {
  count = (var.enable_otel_operator && var.app_deployment_name != "") ? 1 : 0
  triggers = {
    cluster_name        = var.cluster_name
    app_deployment_name = var.app_deployment_name
  }

  provisioner "local-exec" {
    command     = <<-EOT
      kubectl annotate deployment ${var.app_deployment_name} "${local.instrumentation_annotation}=true" --namespace ${var.instrumentation_app_namespace} --overwrite --kubeconfig ${local.kubeconfig_path}
      kubectl rollout status deployment/${var.app_deployment_name} --namespace ${var.instrumentation_app_namespace} --timeout=120s --kubeconfig ${local.kubeconfig_path}
    EOT
    environment = local.kubeconfig_env
  }

  depends_on = [null_resource.instrumentation_cr]
}
