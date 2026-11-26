# Cloud Pipeline — Getting Started

This guide walks through the three steps required to deploy a Cloud Pipeline platform from scratch.

---

## Step 1 — Build the AMI

The AMI is built using [Packer](https://developer.hashicorp.com/packer/docs).

The AMI is a pre-configured machine image that contains everything needed to deploy Cloud Pipeline platform: the
operating system, Kubernetes, and all Cloud Pipeline deployment files.
Building it is a one-time step that produces an image you can reuse for any new deployment.

See [packer/README.md](packer/README.md) for variables reference, build instructions, and details on what the AMI
provisions.

> This is the AMI for the Kubernetes **cluster nodes**. Cloud Pipeline also dynamically launches separate
> compute instances to run pipeline jobs — if you need custom CPU/GPU AMIs for those, see
> [packer/aws/worker_node/README.md](packer/aws/worker_node/README.md).

---

## Step 2 — Provision Infrastructure

This step creates the AWS resources needed to run Cloud Pipeline: 
 - EC2 instances (launched from the AMI built in Step 1),
 - Shared filesystem (EFS or FSx for Lustre)
 - Networking
 - Security groups
 - IAM roles
 - S3 buckets — one for Docker registry image storage and one for system needs (run logs, and backups, etc.).

Infrastructure can be provisioned using the AWS Console, Terraform, or CloudFormation — whichever suits your workflow.

See [infra/README.md](infra/README.md) for required resources, node configuration, and EC2 user data examples.

---

## Step 3 — Deploy Helm

With the server running, deploy Cloud Pipeline using [Helm](https://helm.sh/docs/)
and [Helmfile](https://helmfile.readthedocs.io/en/latest/#about).

1. Connect to the EC2 instance created in Step 2 using one of the following options:
    - **SSH:** `ssh -i your-key.pem ec2-user@<instance-ip>`
    - **AWS Systems Manager (SSM):** `aws ssm start-session --target <instance-id>`
    - **EC2 Instance Connect:** open a browser-based terminal session from the EC2 Console instance page

2. Create the required Kubernetes secrets from your existing certificates —
   see [prerequisites.md](helm/cloud-pipeline/prerequisites.md).

> **Note:** If you do not have certificates yet, you can generate self-signed ones using the scripts in
`helm/prerequisites/` (Not recommended for production use):
> ```bash
> cd helm/prerequisites
> ./generate-cp-pki-certs.sh
> ./generate-cp-jwt-pki-certs.sh
> ./generate-idp-certs.sh
> ```
> See [helm/prerequisites/README.md](helm/prerequisites/README.md) for details.

3. Fill in `helm/values.yaml` with your hostnames, region, and component settings:
   ```bash
   cd /var/lib/cloud-pipeline/deploy/helm
   # edit values.yaml with your preferred editor (e.g. vi values.yaml)
   ```

4. Once secrets are in place and `values.yaml` is configured, start the deployment:
   ```bash
   helmfile apply
   ```

See [helm/README.md](helm/README.md) for the full release dependency order, all `values.yaml` keys, secrets reference,
and post-deploy hooks.

---

## Verifying the deployment

Once `helmfile apply` completes, check that all pods are running:

```bash
kubectl get pods
```

All pods should show `Running` or `Completed` status. If any show an error status, check their logs with
`kubectl logs <pod-name>`.

Open the Cloud Pipeline UI in your browser using the domain you set in `apiSrv.service.host.external` in `values.yaml` —
this is the address you will type into your browser to access the platform.

---

## Platform configuration

### Configuring automatic security patches install

The AMI ships with `dnf-automatic` configured to install security-only OS patches on a schedule
(`kube*`, `docker*`, `container*`, `runc*` packages are always excluded). The schedule is a systemd
`OnCalendar` expression, baked in at build time via the `security_patch_schedule` Packer variable
(default: `Sun *-*-* 09:00:00 UTC`, i.e. weekly). Set it in
`packer/aws/application_node/variables.auto.pkrvars.hcl`:

```hcl
security_patch_schedule = "Sun *-*-* 09:00:00 UTC"
```

It can also be changed later on an already-running instance, without rebuilding the AMI:

```bash
sudo systemctl edit dnf-automatic.timer
# set OnCalendar=<new systemd OnCalendar expression> under [Timer], save and exit
systemctl list-timers dnf-automatic.timer   # confirm the new next-run time
```

**Reboot after patching.** AL2023's `dnf-automatic` has no built-in "reboot if needed" option, so
the AMI additionally installs `smart-restart` and a `dnf-automatic.service` drop-in
(`/etc/systemd/system/dnf-automatic.service.d/override.conf`) that runs
`/var/lib/cloud-pipeline/system-updates/reboot.sh` whenever a patch actually required a reboot
(kernel, glibc, systemd, etc.). `reboot.sh` logs to
`/opt/system/logs/<node-name>/reboot.log`, then reboots the instance one minute later.

**Graceful shutdown before reboot.** Before rebooting, `reboot.sh` reads this node's `ROLE`
(`master-node` or `application-node`, from `/etc/environment`) and runs every executable script it
finds in `/var/lib/cloud-pipeline/system-updates/pre_reboot_scripts/<role>/`.
The two role directories — `pre_reboot_scripts/master/` and `pre_reboot_scripts/application/` —
ship empty, so nothing runs there until you put something in them. This is intentional: which
scripts apply to which role is an infrastructure/deployment decision, not something the AMI itself
should assume.

You can add your own custom script: make it executable and put it straight into the role
directory, or keep it wherever you like and symlink it into the role directory instead.

You can also use the built-in default scripts — for example `grace_shutdown_api_db.sh` or
`grace_shutdown_git_db.sh`, which stop Postgres cleanly inside the relevant pod if (and only if)
this node is actually labeled to host it. They're stored one level up, in
`/var/lib/cloud-pipeline/system-updates/pre_reboot_scripts/`, so enable one for a role by
symlinking it into that role's directory:

```bash
sudo ln -sf /var/lib/cloud-pipeline/system-updates/pre_reboot_scripts/grace_shutdown_api_db.sh \
  /var/lib/cloud-pipeline/system-updates/pre_reboot_scripts/master/grace_shutdown_api_db.sh
```
