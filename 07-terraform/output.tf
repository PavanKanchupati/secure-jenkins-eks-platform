output "cluster_name" {
  value = aws_eks_cluster.eks.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.eks.endpoint
}

output "efs_id" {
  value = aws_efs_file_system.efs.id
}

output "vpc_id" {
  value = aws_vpc.vpc.id
}

output "private_subnets" {
  value = aws_subnet.private[*].id
}

output "public_subnets" {
  value = aws_subnet.public[*].id
}
