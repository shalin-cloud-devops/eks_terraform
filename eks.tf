module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = "boutique-app-eks"
  kubernetes_version = "1.33"
  # Dummy
  addons = {

    coredns = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
    }
  }

  endpoint_public_access                   = false
  enable_cluster_creator_admin_permissions = true

  vpc_id                        = module.vpc.vpc_id
  subnet_ids                    = module.vpc.private_subnets
  additional_security_group_ids = [aws_security_group.boutique_app_sg.id]

  eks_managed_node_groups = {
    boutique_nodes = {

      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["c7i-flex.large"]

      desired_capacity = 2
      max_capacity     = 10
      min_capacity     = 2

      tags = {
        Name        = "boutique_app_node_group"
        Environment = "dev"
      }
    }
  }


}

