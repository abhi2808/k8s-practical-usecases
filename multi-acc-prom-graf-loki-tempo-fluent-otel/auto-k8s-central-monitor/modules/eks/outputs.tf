output "cluster_name" {
  value = keys(var.eks_clusters)[0]
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this[keys(var.eks_clusters)[0]].endpoint
}

output "cluster_ca" {
  value = aws_eks_cluster.this[keys(var.eks_clusters)[0]].certificate_authority[0].data
}
