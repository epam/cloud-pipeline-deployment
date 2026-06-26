# Infrastructure Setup

This document describes the AWS infrastructure required to run a Cloud Pipeline cluster and how to
configure EC2 instances so they bootstrap Kubernetes automatically on first boot.

---

## Required infrastructure

A Cloud Pipeline cluster needs:

| Resource                                      | Purpose                                                                                                                                                                                   |
|-----------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **EC2 instances**                             | One master node (control plane + platform services) and zero or more application nodes (compute workloads). All launched from the same AMI.                                               |
| **Shared filesystem** — EFS or FSx for Lustre | Mounted at `/opt` on every node. Serves as Cloud Pipeline's runtime storage and as the join-credential exchange point that lets application nodes find and join the master automatically. |
| **VPC, subnet, security group**               | Standard network isolation. All nodes must be able to reach each other and the shared filesystem.                                                                                         |
| **IAM instance profile**                      | Grants nodes access to AWS APIs (S3, KMS, EC2) used by Cloud Pipeline at runtime.                                                                                                         |
| **S3 bucket — Docker registry**               | Object storage backend for the internal Docker registry. Set as `CP_DOCKER_STORAGE_CONTAINER` in `values.yaml`.                                                                           |
| **S3 bucket — system storage**                | Used for issue attachments, FSBrowser transfers, pipeline run logs, search index backups, and platform backup. Set as `CP_PREF_STORAGE_SYSTEM_STORAGE_NAME` in `values.yaml`.             |

### Shared filesystem options

| Type                      | When to use                                            |
|---------------------------|--------------------------------------------------------|
| **Amazon EFS**            | General purpose; simple setup; suits most deployments  |
| **Amazon FSx for Lustre** | High-throughput workloads with large genomics datasets |

The filesystem must be mounted and reachable from all nodes before `k8s-first-boot.service` runs.
If the filesystem is not mounted on the master, join credentials are never written and the cluster
initializes as single-node only (no application nodes can join).

---

## Provisioning

You can provision the infrastructure in any way that suits your workflow:

- **AWS Console** — launch EC2 instances manually, create an EFS filesystem from the console
- **Terraform** — define EC2, EFS/FSx, VPC, IAM resources as code; version-controlled and repeatable
- **AWS CloudFormation** — AWS-native IaC; integrates with Service Catalog and StackSets

Whichever method you use, the result must be:

1. An EFS or FSx filesystem accessible from all cluster nodes
2. EC2 instances launched from the AMI built in [packer](../packer/README.md), with EC2 user data that configures
   `bootstrap.env` on each node (see [Node configuration](#node-configuration) below)

---

## Node configuration

Every node reads its role and storage configuration from
`/var/lib/cloud-pipeline/deploy/k8s-bootstrap/bootstrap.env` on first boot. The AMI ships an
all-comments skeleton. Supply real values by appending to it via **EC2 user data**.

### Node roles

| Role        | `ROLE` value                       | What first-boot does                                                                                          |
|-------------|------------------------------------|---------------------------------------------------------------------------------------------------------------|
| Master      | `master-node` (default when unset) | Runs `kubeadm init`, applies Canal CNI, writes join credentials to the shared filesystem, applies node labels |
| Application | `application-node`                 | Mounts shared filesystem, polls for join credentials, runs `kubeadm join`, registers node labels via kubelet  |

### `bootstrap.env` — variable reference

| Variable                       | Default                           | Description                                                                                                                                                                       |
|--------------------------------|-----------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `ROLE`                         | `master-node`                     | `master-node` or `application-node`                                                                                                                                               |
| `CP_STORAGE_TYPE`              | `efs`                             | `efs` or `lustre`                                                                                                                                                                 |
| `CP_STORAGE_ID`                | unset                             | EFS filesystem ID — e.g. `fs-xxxxxxxxx` (EFS only)                                                                                                                                |
| `CP_STORAGE_LUSTRE_DNS`        | unset                             | FSx Lustre DNS name (Lustre only)                                                                                                                                                 |
| `CP_STORAGE_LUSTRE_MOUNT`      | unset                             | FSx Lustre mount name (Lustre only)                                                                                                                                               |
| `APPLICATION_NODE_COUNT`       | `0`                               | Number of application nodes expected. Master removes join credentials as soon as this many nodes have joined. Falls back to a 2-hour cleanup timer if the count is never reached. |
| `CP_MASTER_NODE_LABELS`        | unset                             | Comma-separated `key=value` labels applied to the master after `kubeadm init`. When unset the full default service label set is applied (see [Node labels](#node-labels)).        |
| `CP_APPLICATION_NODE_LABELS`   | `cloud-pipeline/cp-api-srv=true`  | Extra labels applied to application nodes at kubelet registration time. `cloud-pipeline/application-node=true` is always prepended and cannot be overridden.                      |
| `KUBE_DNS_NODE_SELECTOR_LABEL` | `node-role.kubernetes.io/master=` | Node label used to pin kube-dns pods to a specific node.                                                                                                                          |
| `CP_KUBE_JOIN_TIMEOUT`         | `600`                             | Seconds an application node polls for join credentials before warning and continuing.                                                                                             |

### EC2 user data examples

**Master node** (single-node, or head of a multi-node cluster):

```bash
#!/bin/bash
cat >> /var/lib/cloud-pipeline/deploy/k8s-bootstrap/bootstrap.env <<'EOF'
ROLE=master-node
CP_STORAGE_TYPE=efs
CP_STORAGE_ID=fs-xxxxxxxxxxxxxxxxx
APPLICATION_NODE_COUNT=2
EOF
```

**Application node:**

```bash
#!/bin/bash
cat >> /var/lib/cloud-pipeline/deploy/k8s-bootstrap/bootstrap.env <<'EOF'
ROLE=application-node
CP_STORAGE_TYPE=efs
CP_STORAGE_ID=fs-xxxxxxxxxxxxxxxxx
CP_APPLICATION_NODE_LABELS=cloud-pipeline/cp-api-srv=true,cloud-pipeline/cp-edge=true
EOF
```

---

## Multi-node join flow

The master and application nodes coordinate through a directory on the shared filesystem
(`/opt/.temp_kube_join`). The master writes credentials there after `kubeadm init`; application
nodes poll until the `ready.txt` signal appears, then source the credentials and join.

```
Master node                              Application node(s)
───────────────────────────────────────  ───────────────────────────────────────
Mount EFS at /opt
kubeadm init
Write /opt/.temp_kube_join/
  join.env (K8S_JOIN_ENDPOINT,           Mount EFS at /opt (same filesystem)
            K8S_JOIN_TOKEN,              Poll every 10s for ready.txt
            K8S_JOIN_CA_CERT_HASH)         (timeout: CP_KUBE_JOIN_TIMEOUT=600s)
  admin.conf (kubeconfig copy)
  ready.txt ────────────────────────────► Source join.env
                                          kubeadm join $K8S_JOIN_ENDPOINT \
                                            --token $K8S_JOIN_TOKEN \
                                            --discovery-token-ca-cert-hash \
                                              $K8S_JOIN_CA_CERT_HASH
                                          Registers with kubelet node labels:
                                          ◄── cloud-pipeline/application-node=true
                                          ◄── $CP_APPLICATION_NODE_LABELS

kube-join-watcher.service polls:
  kubectl get nodes \
    -l cloud-pipeline/application-node=true
  → when count == APPLICATION_NODE_COUNT:
      delete bootstrap-token kube secret
      rm -rf /opt/.temp_kube_join
  (2h fallback if count never reached)
```

> The join token written to `join.env` has a 24-hour TTL. The watcher also deletes the corresponding
> `bootstrap-token-*` Secret from `kube-system` as part of cleanup.

---

## Node labels

Node labels control which Kubernetes nodes each Cloud Pipeline service is scheduled on.

### Master node

`cloud-pipeline/region=<region>` is always applied unconditionally.

When `CP_MASTER_NODE_LABELS` is **unset**, the full default set is applied with
`kubectl label nodes --all` after `kubeadm init`:

```
cloud-pipeline/cp-api-srv=true          cloud-pipeline/cp-edge=true
cloud-pipeline/cp-idp=true              cloud-pipeline/cp-docker-registry=true
cloud-pipeline/cp-api-db=true           cloud-pipeline/cp-git=true
cloud-pipeline/cp-gitlab-db=true        cloud-pipeline/cp-notifier=true
cloud-pipeline/cp-search-elk=true       cloud-pipeline/cp-search-srv=true
cloud-pipeline/cp-heapster-elk=true     cloud-pipeline/cp-heapster=true
cloud-pipeline/cp-vm-monitor=true       cloud-pipeline/cp-billing-srv=true
cloud-pipeline/application-node=true    (and others)
```

When `CP_MASTER_NODE_LABELS` **is set**, only those labels are applied (plus `cloud-pipeline/region`).
Use this in a multi-node cluster to restrict which services land on the master.

### Application nodes

Labels are set via `KUBELET_EXTRA_ARGS=--node-labels=...` before `kubeadm join` and are registered
with the node at creation time, not applied post-join via `kubectl label`:

```
cloud-pipeline/application-node=true   # always, cannot be overridden
<CP_APPLICATION_NODE_LABELS>           # default: cloud-pipeline/cp-api-srv=true
```

### Multi-node service placement example

To run infrastructure services on the master and API + edge on a dedicated application node:

Master `bootstrap.env`:

```bash
CP_MASTER_NODE_LABELS=cloud-pipeline/cp-idp=true,cloud-pipeline/cp-api-db=true,\
cloud-pipeline/cp-docker-registry=true,cloud-pipeline/cp-git=true,\
cloud-pipeline/cp-monitoring=true,cloud-pipeline/cp-billing-srv=true
```

Application node `bootstrap.env`:

```bash
CP_APPLICATION_NODE_LABELS=cloud-pipeline/cp-api-srv=true,cloud-pipeline/cp-edge=true
```

---

## Verify the cluster is ready

Follow first-boot progress on any node:

```bash
journalctl -fu k8s-first-boot.service
```

Check join-credential watcher on the master:

```bash
journalctl -fu kube-join-watcher.service
ls -la /opt/.temp_kube_join/    # directory disappears once all nodes join
```

Verify all nodes have joined:

```bash
kubectl get nodes -o wide
kubectl get nodes --show-labels
```

Expected output for master + 2 application nodes:

```
NAME          STATUS   ROLES    AGE   VERSION
ip-10-0-1-1   Ready    master   5m    v1.15.4
ip-10-0-1-2   Ready    <none>   3m    v1.15.4
ip-10-0-1-3   Ready    <none>   3m    v1.15.4
```

Once all nodes show `Ready`, proceed to [helm.md](../helm/README.md) to deploy the platform.
