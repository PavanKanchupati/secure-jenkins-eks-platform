provider "aws" {
  region = var.region
}

# ---------------- VPC ----------------

resource "aws_vpc" "vpc" {
  cidr_block = var.vpc_cidr
  tags = { Name = "eks-vpc" }
}

# ---------------- Public Subnets ----------------

resource "aws_subnet" "public" {
  count = 2

  vpc_id = aws_vpc.vpc.id
  cidr_block = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone = element(["ap-south-1a","ap-south-1b"], count.index)

  map_public_ip_on_launch = true

  tags = {
    Name = "public-${count.index}"
    "kubernetes.io/role/elb" = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# ---------------- Private Subnets ----------------

resource "aws_subnet" "private" {
  count = 2

  vpc_id = aws_vpc.vpc.id
  cidr_block = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = element(["ap-south-1a","ap-south-1b"], count.index)

  tags = {
    Name = "private-${count.index}"
    "kubernetes.io/role/internal-elb" = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# ---------------- IGW ----------------

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id
}

# ---------------- NAT ----------------

resource "aws_eip" "nat" {}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
}

# ---------------- Routes ----------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public" {
  count = 2
  subnet_id = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
}

resource "aws_route_table_association" "private" {
  count = 2
  subnet_id = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ---------------- Security Groups ----------------

resource "aws_security_group" "cluster_sg" {
  vpc_id = aws_vpc.vpc.id

  ingress {
    from_port=443
    to_port=443
    protocol="tcp"
    cidr_blocks=["0.0.0.0/0"]
  }

  egress {
    from_port=0
    to_port=0
    protocol="-1"
    cidr_blocks=["0.0.0.0/0"]
  }
}

# -------- EFS SG --------

resource "aws_security_group" "efs_sg" {
  vpc_id = aws_vpc.vpc.id

  ingress {
    from_port=2049
    to_port=2049
    protocol="tcp"
    security_groups=[aws_security_group.cluster_sg.id]
  }

  egress {
    from_port=0
    to_port=0
    protocol="-1"
    cidr_blocks=["0.0.0.0/0"]
  }
}

# ---------------- KMS ----------------

resource "aws_kms_key" "eks" {
  description = "EKS Secret Encryption"
}

# ---------------- IAM ----------------

resource "aws_iam_role" "cluster_role" {
  name = "eks-cluster-role"

  assume_role_policy = jsonencode({
    Version="2012-10-17"
    Statement=[{
      Effect="Allow"
      Principal={Service="eks.amazonaws.com"}
      Action="sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role = aws_iam_role.cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "node_role" {
  name = "eks-node-role"

  assume_role_policy = jsonencode({
    Version="2012-10-17"
    Statement=[{
      Effect="Allow"
      Principal={Service="ec2.amazonaws.com"}
      Action="sts:AssumeRole"
    }]
  })
}

# Base Node Policies

resource "aws_iam_role_policy_attachment" "node_base" {
  count = 3
  role  = aws_iam_role.node_role.name

  policy_arn = element([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  ], count.index)
}

# ✅ EBS CSI Policy

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.node_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ✅ EFS CSI Policy

resource "aws_iam_role_policy_attachment" "efs_csi" {
  role       = aws_iam_role.node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonElasticFileSystemFullAccess"
}

# ---------------- EKS ----------------

resource "aws_eks_cluster" "eks" {
  name = var.cluster_name
  role_arn = aws_iam_role.cluster_role.arn
  version = "1.35"

  vpc_config {
    subnet_ids = concat(
      aws_subnet.public[*].id,
      aws_subnet.private[*].id
    )
    endpoint_private_access = true
    endpoint_public_access  = true
    security_group_ids=[aws_security_group.cluster_sg.id]
  }

  encryption_config {
    provider { key_arn = aws_kms_key.eks.arn }
    resources=["secrets"]
  }
}

# ---------------- Node Group ----------------

resource "aws_eks_node_group" "nodes" {
  cluster_name  = aws_eks_cluster.eks.name
  node_role_arn = aws_iam_role.node_role.arn
  subnet_ids    = aws_subnet.private[*].id

  scaling_config {
    desired_size=3
    max_size=3
    min_size=2
  }

  instance_types=["t3.xlarge"]

  remote_access {
    ec2_ssh_key=var.ssh_key_name
  }
}

# ---------------- EFS Infra ----------------

resource "aws_efs_file_system" "efs" {
  encrypted=true
  tags={Name="eks-efs"}
}

resource "aws_efs_mount_target" "efs_mt" {
  count=2
  file_system_id=aws_efs_file_system.efs.id
  subnet_id=aws_subnet.private[count.index].id
  security_groups=[aws_security_group.efs_sg.id]
}

# ---------------- Addons ----------------

resource "aws_eks_addon" "addons" {
  for_each = toset([
    "vpc-cni",
    "coredns",
    "kube-proxy",
    "aws-efs-csi-driver"
  ])

  cluster_name = aws_eks_cluster.eks.name
  addon_name   = each.value
}
