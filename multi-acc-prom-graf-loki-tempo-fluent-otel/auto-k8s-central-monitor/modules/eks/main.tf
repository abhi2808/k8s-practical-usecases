locals {
  node_groups = flatten([
    for cluster_name, cluster in var.eks_clusters : [
      for ng_name, ng in cluster.node_groups : {
        cluster_name = cluster_name
        node_name    = ng_name
        config       = ng
      }
    ]
  ])
}

resource "aws_iam_role" "cluster_role" {
  for_each = var.eks_clusters
  name     = "${each.key}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  for_each   = var.eks_clusters
  role       = aws_iam_role.cluster_role[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "this" {
  for_each = var.eks_clusters
  name     = each.key
  version  = each.value.version
  role_arn = aws_iam_role.cluster_role[each.key].arn

  vpc_config {
    subnet_ids              = each.value.subnet_ids
    endpoint_public_access  = each.value.endpoint_public_access
    endpoint_private_access = each.value.endpoint_private_access
  }

  tags       = var.tags
  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}

resource "aws_iam_role" "node_role" {
  for_each = {
    for ng in local.node_groups : "${ng.cluster_name}-${ng.node_name}" => ng
  }

  name = "${each.key}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  for_each   = aws_iam_role.node_role
  role       = each.value.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  for_each   = aws_iam_role.node_role
  role       = each.value.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  for_each   = aws_iam_role.node_role
  role       = each.value.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_eks_node_group" "this" {
  for_each = {
    for ng in local.node_groups : "${ng.cluster_name}-${ng.node_name}" => ng
  }

  cluster_name    = each.value.cluster_name
  node_group_name = each.value.node_name
  node_role_arn   = aws_iam_role.node_role[each.key].arn
  subnet_ids      = var.eks_clusters[each.value.cluster_name].subnet_ids
  instance_types  = each.value.config.instance_types
  disk_size       = each.value.config.disk_size
  ami_type        = each.value.config.ami_type

  scaling_config {
    desired_size = each.value.config.desired_size
    min_size     = each.value.config.min_size
    max_size     = each.value.config.max_size
  }

  tags = var.tags

  depends_on = [
    aws_eks_cluster.this,
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]
}

resource "aws_eks_addon" "vpc_cni" {
  for_each                    = var.eks_clusters
  cluster_name                = each.key
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.this]
}

resource "aws_eks_addon" "kubeproxy" {
  for_each                    = var.eks_clusters
  cluster_name                = each.key
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.this]
}

resource "aws_eks_addon" "coredns" {
  for_each                    = var.eks_clusters
  cluster_name                = each.key
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.this]
}
