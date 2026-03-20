terraform {
  required_version = ">= 1.3"
  required_providers {
    aws        = { source = "hashicorp/aws",        version = ">= 5.0"  }
    helm       = { source = "hashicorp/helm",       version = ">= 3.0"  }
    kubernetes = { source = "hashicorp/kubernetes", version = ">= 2.27" }
    null       = { source = "hashicorp/null",       version = ">= 3.2"  }
  }
}

locals {
  cluster_name = keys(var.eks_clusters)[0]
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile
}

data "aws_eks_cluster" "this" {
  name       = local.cluster_name
  depends_on = [module.eks]
}

data "aws_eks_cluster_auth" "this" {
  name       = local.cluster_name
  depends_on = [module.eks]
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

module "eks" {
  source       = "../modules/eks"
  eks_clusters = var.eks_clusters
  tags         = var.tags
}

module "eks_monitoring" {
  source = "../modules/eks-full-monitoring"

  cluster_name           = local.cluster_name
  cluster_endpoint       = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = data.aws_eks_cluster.this.certificate_authority[0].data
  aws_region             = var.region
  aws_profile            = var.aws_profile

  aws_account_label                   = var.monitoring.aws_account_label
  cluster_name_label                  = var.monitoring.cluster_name_label
  central_prometheus_remote_write_url = var.monitoring.central_prometheus_remote_write_url
  central_loki_host                   = var.monitoring.central_loki_host
  central_loki_port                   = var.monitoring.central_loki_port
  central_otel_grpc_endpoint          = var.monitoring.central_otel_grpc_endpoint
  monitoring_namespace                = var.monitoring.monitoring_namespace
  instrumentation_app_namespace       = var.monitoring.instrumentation_app_namespace
  instrumentation_runtime             = var.monitoring.instrumentation_runtime
  otel_service_name                   = var.monitoring.otel_service_name
  app_deployment_name                 = var.monitoring.app_deployment_name
  enable_kube_prometheus              = var.monitoring.enable_kube_prometheus
  enable_fluent_bit                   = var.monitoring.enable_fluent_bit
  enable_otel_collector               = var.monitoring.enable_otel_collector
  enable_otel_operator                = var.monitoring.enable_otel_operator
  kube_prometheus_chart_version       = var.monitoring.kube_prometheus_chart_version
  fluent_bit_chart_version            = var.monitoring.fluent_bit_chart_version
  otel_collector_chart_version        = var.monitoring.otel_collector_chart_version
  prometheus_local_retention          = var.monitoring.prometheus_local_retention

  depends_on = [module.eks]
}
