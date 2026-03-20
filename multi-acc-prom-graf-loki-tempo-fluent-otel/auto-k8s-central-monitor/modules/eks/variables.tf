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

variable "tags" {
  type = map(string)
}
