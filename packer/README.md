# AMI Build

There are two independent Packer builds under `packer/aws/`:

| Directory                                              | Produces                                                                          | Used for                                                                                       |
|---------------------------------------------------------|------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------|
| [`application_node`](aws/application_node)             | One Amazon Linux 2023 AMI, pre-loaded with Kubernetes and the Cloud Pipeline helm files | Every node in the k8s cluster — the one master node and any application nodes. The node role is determined at first boot via EC2 user data, not at build time. |
| [`worker_node`](aws/worker_node/README.md)              | CPU and GPU Amazon Linux 2023 AMIs                                                | The compute instances Cloud Pipeline launches dynamically to run pipeline jobs — referenced in `postDeploy.clusterNetworksConfig` (`values.yaml`) |

This page covers `application_node` (the cluster AMI you need for Steps 2–3 of the main
[README](../README.md)). See [worker_node/README.md](aws/worker_node/README.md) for the compute-worker AMI build.

See [infra/README.md](../infra/README.md) for infrastructure requirements and how to launch and configure EC2 instances.
See [helm/README.md](../helm/README.md) for Phase 2 — PKI secrets, `values.yaml` configuration, and `helmfile apply`.

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

Edit `packer/aws/application_node/variables.auto.pkrvars.hcl`:

```hcl
vpc_id            = "vpc-xxxxxxxxxxxxxxxxx"
subnet_id         = "subnet-xxxxxxxxxxxxxxxxx"
instance_type     = "m7i.xlarge"
security_group_id = "sg-xxxxxxxxxxxxxxxxx"
region            = "us-east-1"
# iam_instance_profile = "my-packer-instance-profile"           # required if ssh_interface = "session_manager"
# ssh_interface        = ""   # "" = SSH direct; "session_manager" = AWS SSM
# cloud_pipeline_deployment_commit = "abc123..."                # pin to a specific commit; defaults to "main"
# docker_data_root     = "/opt/docker"                           # custom Docker data root; leave empty for default
```

---

## Run the build

```bash
cd packer/aws/application_node
packer build .
```

Record the AMI ID printed at the end — it is needed in the EC2 launch configuration for the cluster
nodes themselves (see [infra/README.md](../infra/README.md)).
