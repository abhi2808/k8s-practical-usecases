variable "region"      { type = string }
variable "aws_profile" {
  type    = string
  default = "default"
}
variable "tags"        { type = map(string) }

variable "eks_clusters" {
  type = map(object({
    version                 = string
    subnet_ids              = list(string)
    endpoint_public_access  = bool
    endpoint_private_access = bool
    node_groups = map(object({
      instance_types = list(string)
      desired_size   = number
      min_size       = number
      max_size       = number
      disk_size      = number
      ami_type       = string
    }))
  }))
}

variable "monitoring" {
  type = object({
    aws_account_label                   = string
    cluster_name_label                  = string
    central_prometheus_remote_write_url = string
    central_loki_host                   = string
    central_otel_grpc_endpoint          = string
    central_loki_port                   = optional(number, 3100)
    monitoring_namespace                = optional(string, "monitoring")
    instrumentation_app_namespace       = optional(string, "default")
    instrumentation_runtime             = optional(string, "python")
    otel_service_name                   = optional(string, "sample-app")
    app_deployment_name                 = optional(string, "")
    enable_kube_prometheus              = optional(bool, true)
    enable_fluent_bit                   = optional(bool, true)
    enable_otel_collector               = optional(bool, true)
    enable_otel_operator                = optional(bool, true)
    kube_prometheus_chart_version       = optional(string, "")
    fluent_bit_chart_version            = optional(string, "")
    otel_collector_chart_version        = optional(string, "")
    prometheus_local_retention          = optional(string, "2h")
  })
}
