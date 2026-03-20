variable "cluster_name"           { type = string }
variable "cluster_endpoint"       { type = string }
variable "cluster_ca_certificate" { type = string }
variable "aws_region"             { type = string }

variable "aws_profile" {
  type    = string
  default = "default"
}

variable "aws_account_label"  { type = string }
variable "cluster_name_label" { type = string }

variable "central_prometheus_remote_write_url" { type = string }
variable "central_loki_host"                   { type = string }
variable "central_otel_grpc_endpoint"          { type = string }

variable "central_loki_port" {
  type    = number
  default = 3100
}

variable "monitoring_namespace" {
  type    = string
  default = "monitoring"
}

variable "instrumentation_app_namespace" {
  type    = string
  default = "default"
}

variable "instrumentation_runtime" {
  type    = string
  default = "python"
}

variable "otel_service_name" {
  type    = string
  default = "sample-app"
}

variable "app_deployment_name" {
  type    = string
  default = ""
}

variable "enable_kube_prometheus" {
  type    = bool
  default = true
}

variable "enable_fluent_bit" {
  type    = bool
  default = true
}

variable "enable_otel_collector" {
  type    = bool
  default = true
}

variable "enable_otel_operator" {
  type    = bool
  default = true
}

variable "kube_prometheus_chart_version" {
  type    = string
  default = ""
}

variable "fluent_bit_chart_version" {
  type    = string
  default = ""
}

variable "otel_collector_chart_version" {
  type    = string
  default = ""
}

variable "prometheus_local_retention" {
  type    = string
  default = "2h"
}
