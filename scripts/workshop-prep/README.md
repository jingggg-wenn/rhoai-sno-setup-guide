# Workshop Preparation Scripts

Created: 2026-10-06
Last modified: 2026-10-19

Scripts to prepare an OpenShift cluster for the RHOAI Basic Inference Workshop.
Run these from a local terminal after logging in with `oc login`.

## Prerequisites

- `oc` CLI installed and logged in with cluster-admin privileges
- `htpasswd` CLI available (built-in on macOS, `httpd-tools` on RHEL)
- `python3` (for MachineSet JSON generation)
- Cluster running on AWS with RHOAI installed

## Scripts

> **Note:** Run these scripts from a **local terminal**, not the OpenShift Web Terminal.
> The Web Terminal container does not include `htpasswd`, and patching the OAuth
> configuration on first run triggers an OAuth pod restart that can disconnect
> an active Web Terminal session.

### 1. create_workshop_users.sh

Creates workshop user accounts with htpasswd authentication.
**Automatically adds a worker node** (m6a.4xlarge) to prevent pod/resource
exhaustion on the SNO master node — essential when 20+ users each run
workbenches, model serving, and pipelines simultaneously.

```bash
bash create_workshop_users.sh                  # creates user1..user20 + worker node
bash create_workshop_users.sh --num-users=5    # creates user1..user5 + worker node
bash create_workshop_users.sh --num-users=50   # creates user1..user50 + 3 worker nodes
bash create_workshop_users.sh --skip-worker-node   # users only, no worker node
bash create_workshop_users.sh --worker-instance-type=m6a.8xlarge  # bigger worker
```


| Argument                          | Default       | Description                                     |
| --------------------------------- | ------------- | ----------------------------------------------- |
| `--num-users=<N>`                 | 20            | Number of users to create (`user1` .. `userN`) |
| `--skip-worker-node`              | *(off)*       | Skip worker node addition                       |
| `--worker-instance-type=<type>`   | m6a.4xlarge   | EC2 instance type for worker node               |


What it does:

1. **Adds a worker node** to the SNO cluster (m6a.4xlarge, same region/AZ as master)
   - Scales worker count by user count: 1 worker per ~20 users
   - EC2 provisioning starts immediately; node joins while users are being set up
   - Calls `../add-worker-node.sh` under the hood
2. Generates users (`user1` through `userN`) with password `openshift`
3. Sets up htpasswd as an identity provider on the OAuth cluster resource (preserves existing IDPs)
4. Grants `cluster-admin` RBAC to each user
5. Adds all users to the `rhods-admins` group for RHOAI dashboard admin access
6. Waits for OAuth pods to roll out

> **Why a worker node?** SNO has a 250 pod per node limit. A single workshop
> user running a workbench + pipeline server + model serving already uses ~15
> pods. At 20 users, system + user pods easily exceed the limit, causing
> scheduling failures. The m6a.4xlarge (16 vCPU, 64 GiB) provides enough
> headroom for a typical workshop. Cost: ~$0.69/hr (us-east-1).

### 2. gpu_machineset_hardwareprofiles.sh

Configures GPU infrastructure for model serving workloads.

```bash
bash gpu_machineset_hardwareprofiles.sh
```

What it does:

- Creates a GPU MachineSet (`g6.2xlarge` / NVIDIA L4) with `replicas=0` (scale up manually when needed)
- Patches the `gpu-profile` HardwareProfile with nodeSelector (`nvidia.com/gpu.present`) and toleration (`nvidia.com/gpu:NoSchedule`) so workloads schedule onto GPU nodes
- Uses `scheduling.type: Node` (native Kubernetes scheduling) -- does not require Kueue

### 3. add-worker-node.sh (standalone)

The worker node script can also be used independently outside the workshop context:

```bash
bash ../add-worker-node.sh                                   # m6a.4xlarge (default)
bash ../add-worker-node.sh --instance-type m6a.8xlarge       # bigger instance
bash ../add-worker-node.sh --replicas 2                      # two worker nodes
bash ../add-worker-node.sh --dry-run                         # preview without applying
```

### 4. deploy-showroom.sh (optional)

Deploy workshop content from a Git repository to Showroom on an existing OpenShift cluster.

Requires `oc` login and permission to create namespaces and workloads.

```bash
export GIT_URL="https://github.com/jingggg-wenn/rhoai-basic-inference-workshop.git"
export GIT_REF="main"           # branch or tag
export CONTENT_PATH="content"   # directory containing antora.yml

bash ./deploy-showroom.sh
```


## Run Order

Run the scripts in the order listed above. User accounts (+ worker node) should
be set up before participants access the cluster. GPU infrastructure can be
configured at any time before model deployment exercises.

```bash
oc login --server=https://api.<cluster-domain>:6443
bash create_workshop_users.sh          # users + worker node
bash gpu_machineset_hardwareprofiles.sh  # GPU MachineSet + HardwareProfile
```

## Post-Workshop Cleanup

Scale down worker nodes to stop EC2 charges:

```bash
# Find the worker MachineSet name
oc get machinesets -n openshift-machine-api

# Scale to 0
oc scale machineset <worker-ms-name> -n openshift-machine-api --replicas=0
```
