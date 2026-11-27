# Shared by the master node, every application node and the filesystem mount
# targets: Kubernetes (kubeadm init/join, pod/service networking) and NFS/Lustre
# traffic between nodes requires broad reachability between cluster members.
#
# Only created when var.security_group_ids is empty -- see local.internal_access_sg_ids.
module "internal_access_sg" {
  count = length(var.security_group_ids) == 0 ? 1 : 0

  source  = "terraform-aws-modules/security-group/aws"
  version = "6.0.0"

  vpc_id      = data.aws_vpc.this.id
  name        = "${local.resource_name_prefix}-internal-access-sg"
  description = "Internal access for the Cloud Pipeline cluster nodes and shared filesystem"

  ingress_rules = merge(
    {
      self = {
        ip_protocol                  = "-1"
        referenced_security_group_id = "self"
      }
    },
    {
      for idx, cidr in coalesce(var.internal_access_cidr_blocks, []) :
      "internal-${idx}" => {
        ip_protocol = "-1"
        cidr_ipv4   = cidr
      }
    },
    {
      for idx, cidr in var.kube_api_access_cidr_blocks :
      "kube-api-${idx}" => {
        ip_protocol = "tcp"
        from_port   = 6443
        to_port     = 6443
        cidr_ipv4   = cidr
      }
    }
  )

  egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }

  tags = local.tags
}
