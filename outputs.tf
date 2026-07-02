output "cluster_name" {
  value = module.eks.cluster_name

}

output "bastion_IP" {
  value = module.bastion_host.public_ip

}

output "vpc_id" {
  value = module.vpc.vpc_id

}
