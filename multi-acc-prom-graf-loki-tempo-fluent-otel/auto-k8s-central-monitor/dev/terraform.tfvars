region      = "ap-south-1"
aws_profile = "default"

tags = {
  project = "platform"
  env     = "dev"
}

eks_clusters = {
  cross-acc-mon-2-6 = {
    version                 = "1.34"
    subnet_ids              = ["subnet-0de464b9374299f4f", "subnet-0d19c48e203f9d89f", "subnet-0a84ff1d27a0ec841", "subnet-0d3c0e54898968775"]
    endpoint_public_access  = true
    endpoint_private_access = true
    node_groups = {
      app = {
        instance_types = ["t2.medium"]
        desired_size   = 1
        min_size       = 1
        max_size       = 2
        disk_size      = 20
        ami_type       = "AL2023_x86_64_STANDARD"
      }
    }
  }
}

monitoring = {
  aws_account_label                   = "account-2"
  cluster_name_label                  = "cluster-6"
  central_prometheus_remote_write_url = "http://<--central-ip-->:9090/api/v1/write"
  central_loki_host                   = "<--central-ip-->"
  central_otel_grpc_endpoint          = "<--central-ip-->:4317"
  instrumentation_runtime             = "python"
  otel_service_name                   = "sample-app"
  app_deployment_name                 = ""
  instrumentation_app_namespace       = "default"
}
