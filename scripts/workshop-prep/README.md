# Workshop Preparation Scripts

Created: 2026-10-06
Last modified: 2026-10-06

Scripts to prepare an OpenShift cluster for the RHOAI Basic Inference Workshop.
Run these from a local terminal after logging in with `oc login`.

## Prerequisites

- `oc` CLI installed and logged in with cluster-admin privileges
- `htpasswd` CLI available (built-in on macOS, `httpd-tools` on RHEL)
- `python3` (for GPU MachineSet generation)
- Cluster running on AWS with RHOAI installed

## Scripts

> **Note:** Run these scripts from a **local terminal**, not the OpenShift Web Terminal.
> The Web Terminal container does not include `htpasswd`, and patching the OAuth
> configuration on first run triggers an OAuth pod restart that can disconnect
> an active Web Terminal session.

### 1. create_workshop_users.sh

Creates workshop user accounts with htpasswd authentication.

```bash
bash create_workshop_users.sh                  # creates user01..user20 (default)
bash create_workshop_users.sh --num-users=5    # creates user01..user05
bash create_workshop_users.sh --num-users=50   # creates user01..user50
```


| Argument          | Default | Description                                     |
| ----------------- | ------- | ----------------------------------------------- |
| `--num-users=<N>` | 20      | Number of users to create (`user01` .. `userN`) |


What it does:

- Generates users (`user01` through `userN`) with password `openshift`
- Sets up htpasswd as an identity provider on the OAuth cluster resource (preserves existing IDPs)
- Grants `cluster-admin` RBAC to each user
- Adds all users to the `rhods-admins` group for RHOAI dashboard admin access
- Waits for OAuth pods to roll out

### 2. gpu_machineset_hardwareprofiles.sh

Configures GPU infrastructure for model serving workloads.

```bash
bash gpu_machineset_hardwareprofiles.sh
```

What it does:

- Creates a GPU MachineSet (`g6.2xlarge` / NVIDIA L4) with `replicas=0` (scale up manually when needed)
- Patches the `gpu-profile` HardwareProfile with nodeSelector (`nvidia.com/gpu.present`) and toleration (`nvidia.com/gpu:NoSchedule`) so workloads schedule onto GPU nodes
- Uses `scheduling.type: Node` (native Kubernetes scheduling) -- does not require Kueue
- 

## Run Order

Run the scripts in the order listed above. User accounts should be set up before participants access the cluster. GPU infrastructure can be configured at any time before model deployment exercises.

```bash
oc login --server=https://api.<cluster-domain>:6443
bash create_workshop_users.sh
bash gpu_machineset_hardwareprofiles.sh
```

