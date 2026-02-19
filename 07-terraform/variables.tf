variable "region" {
  default = "ap-south-1"
}

variable "cluster_name" {
  default = "devopsshack-cluster"
}

variable "vpc_cidr" {
  default = "10.0.0.0/16"
}

variable "ssh_key_name" {
  default = "DevSecOps" # replace with you SSH key pair name in AWS
}