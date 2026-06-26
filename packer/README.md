# AMI Build

Packer builds an Amazon Linux 2023 AMI that is used for every node in the cluster — both the master
and any application nodes. The node role is determined at first boot via EC2 user data, not at build time.

See [infra.md](../infra/README.md) for infrastructure requirements and how to launch and configure EC2 instances.
See [helm.md](../helm/README.md) for Phase 2 — PKI secrets, `values.yaml` configuration, and `helmfile apply`.

---

## What the build provisions

1. Installs `amazon-efs-utils`, `lustre-client`, Docker 20.10.24, Helm v3.3.4, Helmfile v1.4.1,
   `helm-diff` v3.4.2, `jq`
2. Downloads and pre-loads Docker images: Calico v3.14.1, Flannel v0.26.4, kube-proxy v1.15.4, `pause:3.1`
3. Installs `kubeadm` and `kubelet` RPMs v1.15.4
4. Copies the entire `helm/` directory to `/var/lib/cloud-pipeline/deploy/helm`
5. Renders `kubeadm-init-config.yaml` and `canal.yaml` from templates
6. Installs `k8s-first-boot.service` (runs once on first boot) and `kube-join-watcher.service`
7. Writes the `bootstrap.env` skeleton to `/var/lib/cloud-pipeline/deploy/k8s-bootstrap/bootstrap.env`

---

## Fill in Packer variables

Edit `packer/aws/variables.auto.pkrvars.hcl`:

```hcl
vpc_id               = "vpc-xxxxxxxxxxxxxxxxx"
subnet_id            = "subnet-xxxxxxxxxxxxxxxxx"
instance_type        = "m7i.xlarge"
security_group_id    = "sg-xxxxxxxxxxxxxxxxx"
region               = "us-east-1"
iam_instance_profile = "my-packer-instance-profile"
ssh_interface        = ""   # "" = SSH direct; "session_manager" = AWS SSM
```

---

## Run the build

```bash
cd packer/aws
packer build .
```

Record the AMI ID printed at the end. It is needed in two places:

- `postDeploy.clusterNetworksConfig` in `values.yaml` — the AMI Cloud Pipeline uses when launching
  compute worker nodes
- The EC2 launch configuration for the cluster nodes themselves (see [infra.md](../infra/README.md))
