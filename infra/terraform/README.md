# Terraform: Cloud Pipeline single-master cluster infrastructure

Reusable Terraform for the AWS infrastructure described in [../README.md](../README.md): one
master node (control plane + platform services) and zero or more application nodes, all booted
from the AMI built in [packer](../../packer/README.md), joined via `kubeadm` (not EKS), sharing
an EFS or FSx for Lustre filesystem.

Modeled after the structure and conventions of
[cloud-pipeline's own AWS/EKS Terraform](https://github.com/epam/cloud-pipeline/tree/develop/deploy/infra/aws/terraform/cloud-native),
but scoped to this repository's deployment model: no EKS, no jump-server -- a single `kubeadm`
master plus application nodes.

```
infra/terraform/
├── modules/cp-cluster/        # the reusable module -- no backend/provider blocks
└── examples/single-node/   # a runnable root module that calls it
```

## Prerequisites

1. **An AMI** built from [`packer/aws/application_node`](../../packer/README.md). Record its ID.
2. **A VPC and subnet(s)** that all cluster nodes and the shared filesystem can reach, with
   connectivity back to your network (VPN, Direct Connect, or a bastion/jump host of your own).
3. **Terraform >= 1.5** and the AWS CLI configured with credentials for the target account.
4. **A remote state backend** (strongly recommended for anything beyond a personal test). An S3
   bucket + DynamoDB lock table, created once, up front:

   ```bash
   aws s3api create-bucket --bucket <state-bucket-name> --region <region> \
     --create-bucket-configuration LocationConstraint=<region>   # omit --create-bucket-configuration for us-east-1

   aws dynamodb create-table --table-name <lock-table-name> \
     --attribute-definitions AttributeName=LockID,AttributeType=S \
     --key-schema AttributeName=LockID,KeyType=HASH \
     --billing-mode PAY_PER_REQUEST --region <region>
   ```

5. If you intend to launch worker/compute nodes as EC2 Spot instances from Cloud Pipeline itself,
   the `AWSServiceRoleForEC2Spot` service-linked role must exist in the account (and
   `enable_spot_support = true` must be set), see
   [the AWS docs](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/service-linked-roles-spot-instance-requests.html).

## Usage

Copy [`examples/single-cluster`](examples/single-cluster) into your own repository (or reference
the module directly over git), fill in `terraform.tfvars`, uncomment the `backend "s3" {}` block
in `versions.tf`, and run:

```bash
cd examples/single-cluster
cp terraform.tfvars.example terraform.tfvars   # then edit it
terraform init
terraform plan
terraform apply
```

Calling the module directly looks like this:

```hcl
module "cp_cluster" {
  source = "git::https://<your-git-host>/cloud-pipeline-deployment//infra/terraform/modules/cp-cluster?ref=<tag-or-commit>"

  deployment_name = "cloud-pipeline"
  deployment_env  = "prod"

  vpc_id     = "vpc-xxxxxxxxxxxxxxxxx"
  subnet_ids = ["subnet-xxxxxxxxxxxxxxxxx"]

  ami_id = "ami-xxxxxxxxxxxxxxxxx"

  application_node_count = 2
  storage_type            = "efs"

  api_srv_host         = "cp.example.com"
  docker_registry_host = "docker.example.com"
  edge_host            = "edge.example.com"
  git_host             = "git.example.com"
}
```

### Key inputs

| Name | Default | Description |
|---|---|---|
| `deployment_name`, `deployment_env` | — (required) | Combined into the prefix used for every created resource's name. |
| `vpc_id`, `subnet_ids` | — (required) | Network placement. The master node and EFS mount targets start at the first subnet; application nodes spread round-robin across all of them. |
| `ami_id` | — (required) | AMI from the `packer` build. |
| `key_name` | generates one | Existing EC2 key pair name. Leave unset to have the module create one -- the private key is then returned via the sensitive `generated_ssh_private_key_pem` output. |
| `master_node_instance_type` / `application_node_instance_type` | `m5.xlarge` / `m5.2xlarge` | |
| `application_node_count` | `0` | Number of application nodes. |
| `master_node_labels` / `application_node_labels` | unset / `cloud-pipeline/cp-api-srv=true` | Forwarded into `bootstrap.env` as `CP_MASTER_NODE_LABELS` / `CP_APPLICATION_NODE_LABELS` -- see [../README.md#node-labels](../README.md#node-labels). |
| `storage_type` | `efs` | `efs` or `fsx`. |
| `create_s3_buckets` | `true` | Set `false` and supply `docker_registry_bucket_name` / `system_bucket_name` to reuse existing buckets instead. |
| `s3_force_destroy` | `false` | Keep `false` in production -- `true` lets `terraform destroy` delete buckets that still hold data. |
| `iam_role_permissions_boundary_arn` | `null` | Account-specific IAM permissions boundary, applied to every role this module creates. |
| `external_access_security_group_ids` | `[]` | Extra, pre-existing security groups to attach to every node (e.g. for a corporate VPN or an external load balancer). |
| `security_group_ids` | `[]` (generates one) | Existing security group IDs to attach to every node and the shared filesystem mount targets, instead of creating one (e.g. one for intra-cluster traffic plus another for corporate VPN access). Leave empty to have the module create its own. `internal_access_cidr_blocks` / `kube_api_access_cidr_blocks` only apply to the module-created security group, so they're ignored when this is set. |
| `internal_access_cidr_blocks` | `null` (closed) | Extra CIDRs allowed all-protocols ingress, beyond the cluster's own security group members. Leave unset to keep the cluster closed to anything outside itself. |
| `kube_api_access_cidr_blocks` | `[]` | Extra CIDRs allowed ingress to the Kubernetes API port (6443) only, e.g. for Cloud Pipeline run/worker nodes launched outside this security group. |
| `security_patch_schedule` | `null` (skipped) | systemd `OnCalendar` expression; when set, applies it to the `dnf-automatic` security-patch timer on every already-running node via SSM Run Command in this same apply (see [below](#security-patch-schedule)). |
| `api_srv_host`, `docker_registry_host`, `edge_host`, `git_host` | — (required) | External DNS hostnames for the corresponding services. |
| `idp_host` / `share_srv_host` | unset (disabled) | Supplying a hostname enables the in-cluster IdP / data-sharing service; leaving it unset disables that service. |
| `admin_name` / `admin_email` / `admin_password` | `pipe_admin` / `""` / generated | Default Cloud Pipeline administrator account. Leave `admin_password` unset to have the module generate one. |
| `db_password` / `gitlab_root_password` | generated | Internal Postgres and GitLab root passwords. Leave unset to have the module generate them. |
| `enable_search` / `enable_billing` / `enable_notifier` / `enable_monitoring` / `enable_storage_lifecycle` / `enable_dav` / `enable_run_policy_manager` / `enable_post_deploy` | all `true` | Set any to `false` to skip that service. All default on, so the generated `cp_values_yaml` installs the full Cloud Pipeline service set out of the box. |
| `worker_node_amis` | `[]` | AMIs (from `packer/aws/worker_node`) Cloud Pipeline launches to run pipeline jobs. Populates `CP_POST_DEPLOY_CLUSTER_NETWORKS_SPEC` in `cp_values_yaml`, along with `subnet_ids` (as the region's networks, named by AZ) and `worker_node_security_group_ids`. Left empty, this stays `{}` -- same as upstream's own placeholder -- and pipeline runs can't launch until it's set, here or by hand in `values.yaml`. |
| `worker_node_security_group_ids` | cluster's own internal security group | Security groups attached to dynamically launched worker/run nodes. Only used when `worker_node_amis` is set. |

Full reference: [`modules/cp-cluster/variables.tf`](modules/cp-cluster/variables.tf).

### Key outputs

| Name | Description |
|---|---|
| `master_node_ssm_session_command` | Ready-to-run `aws ssm start-session` command for the master node. |
| `docker_registry_bucket_name`, `system_bucket_name` | S3 buckets to reference from `helm/values.yaml`. |
| `kms_key_arn`, `s3_via_sts_role_arn`, `ssh_key_name` | Values needed by `apiSrv.cloudRegion.*` in `helm/values.yaml`. |
| `cp_values_yaml` | Sensitive. A full `values.yaml` with every service configured and wired to this infrastructure -- see below. |
| `generated_ssh_private_key_pem` / `admin_password` / `db_password` / `gitlab_root_password` | Sensitive. Only populated for the credentials you left unset. |

Full reference: [`modules/cp-cluster/outputs.tf`](modules/cp-cluster/outputs.tf).

## From infrastructure to a running cluster

1. `terraform apply`. User data on each instance writes its role into `bootstrap.env`
   automatically -- no manual EC2 user data editing needed (contrast with the generic
   [../README.md#node-configuration](../README.md#node-configuration) flow, which this module
   implements for you).
2. Connect to the master node:

   ```bash
   terraform output -raw master_node_ssm_session_command | bash
   ```

3. Watch first boot and the join flow:

   ```bash
   journalctl -fu k8s-first-boot.service
   kubectl get nodes -o wide
   ```

4. Write out the generated values file (it replaces `helm/values.yaml` wholesale -- it already
   configures every service):

   ```bash
   terraform output -raw cp_values_yaml > values.yaml
   ```

5. Continue with [TLS/PKI prerequisites](../../README.md) and `helmfile apply` as described in the
   root [CLAUDE.md](../../CLAUDE.md) / [helm/README.md](../../helm/README.md). Point `helmfile` at
   the generated file with `HELMFILE_VALUES=$(pwd)/values.yaml`.

## Design notes

- **No `backend` or `provider` block in the module itself.** Both are the calling root module's
  responsibility (see `examples/single-node/versions.tf`) -- a module that hardcodes either
  cannot be reused across environments or accounts.
- **Public, versioned registry modules** (`terraform-aws-modules/{kms,s3-bucket,security-group}/aws`)
  are used instead of hand-rolled resources wherever one exists, for the same reason
  `cloud-pipeline`'s own EKS Terraform does: less custom code to maintain, and the defaults already
  encode AWS best practices (KMS key rotation, S3 `BucketOwnerEnforced` ownership, etc.).
- **Everything encrypts with one customer-managed KMS key**: EBS root volumes, the shared
  filesystem, and both S3 buckets.
- **The shared filesystem backend is pluggable** (`storage_type = "efs" | "fsx"`), matching the two
  options already documented in [../README.md#shared-filesystem-options](../README.md#shared-filesystem-options).
- **`cp_values_yaml` installs the full Cloud Pipeline service set by default**, mirroring
  `helm/values.yaml`'s own schema and defaults (see
  [`templates/cp-values.yaml.tpl`](modules/cp-cluster/templates/cp-values.yaml.tpl)): idp,
  apiSrv, dockerRegistry (with Clair), edge, git, search, billing, notifier, monitoring,
  storageLifecycle, dav, shareSrv, runPolicyManager and postDeploy hooks are all wired up and
  enabled, with infrastructure values (KMS key, buckets, roles, master IP) filled in and
  credentials generated where you don't supply your own. Any `enable_*` variable turns a given
  service back off; anything this module doesn't expose as a variable (image tags, resource
  sizing, SMTP servers, etc.) is still a `helm/values.yaml` edit away.

## Security patch schedule

The AMI bakes in unattended OS security patching via `dnf-automatic`
(`packer/common/scripts/install_security_patches.sh`), excluding the pinned `kube*`/`docker*`/
`container*`/`runc*` packages, on a schedule set at build time by the packer
`security_patch_schedule` variable (default: weekly, Sunday 03:00 UTC).

Setting `var.security_patch_schedule` (a systemd `OnCalendar` expression, e.g.
`"Sun *-*-* 03:00:00"`) re-applies that schedule to every already-running node -- master and all
application nodes -- via SSM Run Command, in the same `terraform apply`, without rebuilding the
AMI or replacing any instance. It's implemented as a `null_resource` per node running
`aws ssm send-command` / `aws ssm wait command-executed` through a `local-exec` provisioner
(`modules/cp-cluster/security-patch-schedule.tf`), keyed on the schedule value via `triggers` so
changing it and re-applying is enough to roll it out everywhere; leaving the variable unset skips
this entirely.

This requires the `aws` CLI to be installed and authenticated wherever `terraform apply` runs,
with `ssm:SendCommand` / `ssm:GetCommandInvocation` permissions -- but no SSH, no bastion, and no
VPC network path to the nodes at all, since SSM traffic goes over the AWS API using the
`AmazonSSMManagedInstanceCore` permissions every node's instance profile already has (the same
mechanism behind the `master_node_ssm_session_command` output above).
