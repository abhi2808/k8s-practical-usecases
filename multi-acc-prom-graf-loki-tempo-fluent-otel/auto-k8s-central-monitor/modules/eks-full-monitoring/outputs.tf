output "monitoring_namespace" {
  value = var.monitoring_namespace
}

output "otel_collector_service_dns" {
  value = "otel-collector-opentelemetry-collector.${var.monitoring_namespace}.svc.cluster.local"
}
