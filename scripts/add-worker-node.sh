#!/bin/bash
###############################################################################
# add-worker-node.sh
#
# Add a worker node (m6a.4xlarge) to an SNO cluster to alleviate resource
# pressure. The script detects the master node's region and AZ automatically
# and creates a MachineSet in the same location.
#
# m6a.4xlarge specs: 16 vCPU (AMD EPYC), 64 GiB RAM, EBS-only
#
# On SNO clusters, all workloads run on the single master node which can
# hit pod limits (250) or memory pressure. Adding one worker node offloads
# user workloads (workbenches, model serving, pipelines) from the master.
#
# This script is idempotent -- safe to re-run at any time.
#
# Usage:
#   bash add-worker-node.sh                          # m6a.4xlarge (default)
#   bash add-worker-node.sh --instance-type m6a.8xlarge  # custom type
#   bash add-worker-node.sh --replicas 2             # two worker nodes
#   bash add-worker-node.sh --dry-run                # preview without applying
#
# Prerequisites:
#   - oc login completed with cluster-admin privileges
#   - Cluster running on AWS (IPI-provisioned)
#   - python3 available (for MachineSet JSON generation)
###############################################################################
set -euo pipefail

INSTANCE_TYPE="m6a.4xlarge"
REPLICAS=1
DRY_RUN=false
DISK_SIZE=120

while [[ $# -gt 0 ]]; do
    case "$1" in
        --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
        --replicas)      REPLICAS="$2"; shift 2 ;;
        --disk-size)     DISK_SIZE="$2"; shift 2 ;;
        --dry-run)       DRY_RUN=true; shift ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "  --instance-type <type>   EC2 instance type (default: m6a.4xlarge)"
            echo "  --replicas <n>           Number of worker nodes (default: 1)"
            echo "  --disk-size <gb>         Root EBS volume size in GiB (default: 120)"
            echo "  --dry-run                Preview MachineSet YAML without applying"
            echo "  --help                   Show this help"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }

echo "=============================================="
echo " SNO — Add Worker Node"
echo "=============================================="
echo ""
info "Instance type : $INSTANCE_TYPE"
info "Replicas      : $REPLICAS"
info "Disk size     : ${DISK_SIZE} GiB"
[ "$DRY_RUN" = true ] && info "Mode          : DRY RUN (no changes will be made)"
echo ""

###############################################################################
# Prerequisite checks
###############################################################################
info "=== Prerequisites ==="

if ! oc whoami &>/dev/null; then
    error "oc login required"
    exit 1
fi
success "Logged in: $(oc whoami) @ $(oc whoami --show-server)"

if ! command -v python3 &>/dev/null; then
    error "'python3' required for MachineSet JSON generation"
    exit 1
fi

PLATFORM=$(oc get infrastructure cluster -o jsonpath='{.status.platform}' 2>/dev/null)
if [ "$PLATFORM" != "AWS" ]; then
    error "This script supports AWS clusters only (detected: ${PLATFORM:-unknown})"
    exit 1
fi
success "Platform: AWS ✓"
echo ""

###############################################################################
# Step 1: Detect master node region / AZ from existing infrastructure
#
#   On SNO there are no worker MachineSets. We extract providerSpec from
#   the master Machine object in openshift-machine-api.
#   Fallback: try existing MachineSets (non-SNO or post-expansion clusters).
###############################################################################
info "=== Step 1: Detect cluster infrastructure ==="

INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null)
if [ -z "$INFRA_ID" ]; then
    error "Could not determine cluster infrastructure ID"
    exit 1
fi
info "Infrastructure ID: $INFRA_ID"

# Try MachineSets first (works on non-SNO or already-expanded clusters)
SOURCE_TYPE=""
SOURCE_NAME=""

EXISTING_MS=$(oc get machinesets -n openshift-machine-api --no-headers 2>/dev/null \
    | awk '{print $1}' | head -1)
if [ -n "$EXISTING_MS" ]; then
    # Verify it has a valid providerSpec (some SNO clusters have empty MachineSets)
    TEST_REGION=$(oc get machineset "$EXISTING_MS" -n openshift-machine-api \
        -o jsonpath='{.spec.template.spec.providerSpec.value.placement.region}' 2>/dev/null || true)
    if [ -n "$TEST_REGION" ]; then
        SOURCE_TYPE="machineset"
        SOURCE_NAME="$EXISTING_MS"
    fi
fi

# Fallback: use Machine objects (master node)
if [ -z "$SOURCE_TYPE" ]; then
    EXISTING_MACHINE=$(oc get machines -n openshift-machine-api --no-headers 2>/dev/null \
        | grep -i "running\|provisioned" | awk '{print $1}' | head -1)
    if [ -n "$EXISTING_MACHINE" ]; then
        SOURCE_TYPE="machine"
        SOURCE_NAME="$EXISTING_MACHINE"
    fi
fi

if [ -z "$SOURCE_TYPE" ]; then
    error "No existing Machine or MachineSet found to derive infrastructure config"
    exit 1
fi
info "Source: $SOURCE_TYPE/$SOURCE_NAME"

# Extract infrastructure values from the source object
if [ "$SOURCE_TYPE" = "machineset" ]; then
    BASE_PATH=".spec.template.spec.providerSpec.value"
    OBJ_TYPE="machineset"
else
    BASE_PATH=".spec.providerSpec.value"
    OBJ_TYPE="machine"
fi

AWS_REGION=$(oc get "$OBJ_TYPE" "$SOURCE_NAME" -n openshift-machine-api \
    -o jsonpath="{${BASE_PATH}.placement.region}" 2>/dev/null)
AWS_AZ=$(oc get "$OBJ_TYPE" "$SOURCE_NAME" -n openshift-machine-api \
    -o jsonpath="{${BASE_PATH}.placement.availabilityZone}" 2>/dev/null)
AMI_ID=$(oc get "$OBJ_TYPE" "$SOURCE_NAME" -n openshift-machine-api \
    -o jsonpath="{${BASE_PATH}.ami.id}" 2>/dev/null)
IAM_PROFILE=$(oc get "$OBJ_TYPE" "$SOURCE_NAME" -n openshift-machine-api \
    -o jsonpath="{${BASE_PATH}.iamInstanceProfile.id}" 2>/dev/null)

# For worker nodes, try to use the worker IAM profile instead of master
# Master IAM profile pattern: <infra-id>-master-profile
# Worker IAM profile pattern: <infra-id>-worker-profile
WORKER_IAM="${INFRA_ID}-worker-profile"
if echo "$IAM_PROFILE" | grep -q "master"; then
    info "Detected master IAM profile — switching to worker profile"
    IAM_PROFILE="$WORKER_IAM"
fi

# Extract subnet and security groups as JSON
SUBNET_JSON=$(oc get "$OBJ_TYPE" "$SOURCE_NAME" -n openshift-machine-api \
    -o json 2>/dev/null | python3 -c "
import json, sys
obj = json.load(sys.stdin)
if '${SOURCE_TYPE}' == 'machineset':
    ps = obj['spec']['template']['spec']['providerSpec']['value']
else:
    ps = obj['spec']['providerSpec']['value']
print(json.dumps(ps.get('subnet', {})))
")

SG_JSON=$(oc get "$OBJ_TYPE" "$SOURCE_NAME" -n openshift-machine-api \
    -o json 2>/dev/null | python3 -c "
import json, sys
obj = json.load(sys.stdin)
if '${SOURCE_TYPE}' == 'machineset':
    ps = obj['spec']['template']['spec']['providerSpec']['value']
else:
    ps = obj['spec']['providerSpec']['value']
# For worker nodes, filter out master-specific SGs and use worker SGs
sgs = ps.get('securityGroups', [])
print(json.dumps(sgs))
")

TAGS_JSON=$(oc get "$OBJ_TYPE" "$SOURCE_NAME" -n openshift-machine-api \
    -o json 2>/dev/null | python3 -c "
import json, sys
obj = json.load(sys.stdin)
if '${SOURCE_TYPE}' == 'machineset':
    ps = obj['spec']['template']['spec']['providerSpec']['value']
else:
    ps = obj['spec']['providerSpec']['value']
tags = ps.get('tags', [])
print(json.dumps(tags))
")

# Validate extracted values
MISSING=""
[ -z "$AWS_REGION" ] && MISSING="${MISSING} region"
[ -z "$AWS_AZ" ] && MISSING="${MISSING} az"
[ -z "$AMI_ID" ] && MISSING="${MISSING} ami"
[ -z "$IAM_PROFILE" ] && MISSING="${MISSING} iam-profile"

if [ -n "$MISSING" ]; then
    error "Could not determine:${MISSING}"
    error "Check: oc get ${OBJ_TYPE} ${SOURCE_NAME} -n openshift-machine-api -o yaml"
    exit 1
fi

success "Region : $AWS_REGION"
success "AZ     : $AWS_AZ"
success "AMI    : $AMI_ID"
success "IAM    : $IAM_PROFILE"
echo ""

###############################################################################
# Step 2: Create worker MachineSet
###############################################################################
info "=== Step 2: Create worker MachineSet ==="

# Naming: <infra-id>-worker-<az>
MS_NAME="${INFRA_ID}-worker-${AWS_AZ}"

# Check if MachineSet already exists
if oc get machineset "$MS_NAME" -n openshift-machine-api &>/dev/null 2>&1; then
    CURRENT_REPLICAS=$(oc get machineset "$MS_NAME" -n openshift-machine-api \
        -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
    CURRENT_TYPE=$(oc get machineset "$MS_NAME" -n openshift-machine-api \
        -o jsonpath='{.spec.template.spec.providerSpec.value.instanceType}' 2>/dev/null || echo "?")
    success "MachineSet $MS_NAME already exists (type=$CURRENT_TYPE, replicas=$CURRENT_REPLICAS)"

    if [ "$CURRENT_REPLICAS" = "0" ]; then
        info "Scaling $MS_NAME to $REPLICAS..."
        if [ "$DRY_RUN" = true ]; then
            info "[DRY RUN] Would run: oc scale machineset $MS_NAME -n openshift-machine-api --replicas=$REPLICAS"
        else
            oc scale machineset "$MS_NAME" -n openshift-machine-api --replicas="$REPLICAS"
            success "Scaled to $REPLICAS"
        fi
    elif [ "$CURRENT_REPLICAS" -lt "$REPLICAS" ] 2>/dev/null; then
        info "Scaling $MS_NAME from $CURRENT_REPLICAS to $REPLICAS..."
        if [ "$DRY_RUN" = true ]; then
            info "[DRY RUN] Would run: oc scale machineset $MS_NAME -n openshift-machine-api --replicas=$REPLICAS"
        else
            oc scale machineset "$MS_NAME" -n openshift-machine-api --replicas="$REPLICAS"
            success "Scaled to $REPLICAS"
        fi
    else
        info "Already at $CURRENT_REPLICAS replica(s) — no change needed"
    fi
else
    info "Creating MachineSet: $MS_NAME ($INSTANCE_TYPE, replicas=$REPLICAS)"

    MS_JSON=$(python3 -c "
import json, sys

infra_id = '${INFRA_ID}'
ms_name = '${MS_NAME}'
region = '${AWS_REGION}'
az = '${AWS_AZ}'
ami_id = '${AMI_ID}'
iam_profile = '${IAM_PROFILE}'
instance_type = '${INSTANCE_TYPE}'
replicas = ${REPLICAS}
disk_size = ${DISK_SIZE}
subnet = json.loads('''${SUBNET_JSON}''')
security_groups = json.loads('''${SG_JSON}''')
tags = json.loads('''${TAGS_JSON}''')

# Fix security groups: replace master SG with worker SG
# Pattern: <infra-id>-master-sg → <infra-id>-worker-sg
fixed_sgs = []
for sg in security_groups:
    for filter_entry in sg.get('filters', []):
        for val in filter_entry.get('values', []):
            if '-master-sg' in val:
                filter_entry['values'] = [v.replace('-master-sg', '-worker-sg') for v in filter_entry['values']]
    fixed_sgs.append(sg)

ms = {
    'apiVersion': 'machine.openshift.io/v1beta1',
    'kind': 'MachineSet',
    'metadata': {
        'name': ms_name,
        'namespace': 'openshift-machine-api',
        'labels': {
            'machine.openshift.io/cluster-api-cluster': infra_id,
        },
        'annotations': {
            'machine.openshift.io/memoryMb': '65536',
            'machine.openshift.io/vCPU': '16',
        },
    },
    'spec': {
        'replicas': replicas,
        'selector': {
            'matchLabels': {
                'machine.openshift.io/cluster-api-cluster': infra_id,
                'machine.openshift.io/cluster-api-machineset': ms_name,
            },
        },
        'template': {
            'metadata': {
                'labels': {
                    'machine.openshift.io/cluster-api-cluster': infra_id,
                    'machine.openshift.io/cluster-api-machine-role': 'worker',
                    'machine.openshift.io/cluster-api-machine-type': 'worker',
                    'machine.openshift.io/cluster-api-machineset': ms_name,
                },
            },
            'spec': {
                'metadata': {
                    'labels': {
                        'node-role.kubernetes.io/worker': '',
                    },
                },
                'providerSpec': {
                    'value': {
                        'apiVersion': 'machine.openshift.io/v1beta1',
                        'kind': 'AWSMachineProviderConfig',
                        'instanceType': instance_type,
                        'placement': {
                            'availabilityZone': az,
                            'region': region,
                        },
                        'ami': {'id': ami_id},
                        'iamInstanceProfile': {'id': iam_profile},
                        'subnet': subnet,
                        'securityGroups': fixed_sgs,
                        'tags': tags,
                        'userDataSecret': {'name': 'worker-user-data'},
                        'credentialsSecret': {'name': 'aws-cloud-credentials'},
                        'deviceIndex': 0,
                        'blockDevices': [
                            {
                                'ebs': {
                                    'encrypted': True,
                                    'volumeSize': disk_size,
                                    'volumeType': 'gp3',
                                    'iops': 3000,
                                    'kmsKey': {'arn': ''},
                                },
                            },
                        ],
                        'metadataServiceOptions': {},
                        'metadata': {'creationTimestamp': None},
                    },
                },
            },
        },
    },
}

json.dump(ms, sys.stdout, indent=2)
")

    if [ "$DRY_RUN" = true ]; then
        info "[DRY RUN] MachineSet YAML:"
        echo "$MS_JSON" | python3 -c "import sys,json; import json as j; j.dump(j.load(sys.stdin), sys.stdout, indent=2)"
        echo ""
        info "To apply: $0 (without --dry-run)"
    else
        echo "$MS_JSON" | oc apply -f -
        success "MachineSet created: $MS_NAME"
    fi
fi
echo ""

###############################################################################
# Step 3: Wait for Machine provisioning and node join
###############################################################################
if [ "$DRY_RUN" = true ]; then
    info "=== Step 3: Wait for node [SKIPPED — dry run] ==="
    echo ""
else
    info "=== Step 3: Wait for Machine provisioning ==="

    # Wait for Machine to be created (up to 60s)
    info "Waiting for Machine to be created..."
    WAIT=0
    MACHINE_NAME=""
    while [ $WAIT -lt 60 ]; do
        MACHINE_NAME=$(oc get machines -n openshift-machine-api --no-headers 2>/dev/null \
            | grep "$MS_NAME" | grep -v "master" | awk '{print $1}' | head -1)
        [ -n "$MACHINE_NAME" ] && break
        sleep 5; WAIT=$((WAIT + 5))
    done

    if [ -z "$MACHINE_NAME" ]; then
        warn "Machine not yet created — it may take a few moments"
        warn "Monitor with: oc get machines -n openshift-machine-api -w"
    else
        success "Machine: $MACHINE_NAME"

        # Wait for Machine to reach Running phase (up to 10 min)
        info "Waiting for Machine to reach Running phase (up to 10 min)..."
        info "  This includes: EC2 launch → ignition bootstrap → kubelet join"
        WAIT=0
        while [ $WAIT -lt 600 ]; do
            PHASE=$(oc get machine "$MACHINE_NAME" -n openshift-machine-api \
                -o jsonpath='{.status.phase}' 2>/dev/null || true)

            case "$PHASE" in
                Running)
                    success "Machine $MACHINE_NAME is Running ✓"
                    break ;;
                Failed)
                    error "Machine $MACHINE_NAME failed!"
                    oc get machine "$MACHINE_NAME" -n openshift-machine-api \
                        -o jsonpath='{.status.errorMessage}' 2>/dev/null
                    echo ""
                    exit 1 ;;
            esac

            if [ $((WAIT % 30)) -eq 0 ] && [ $WAIT -gt 0 ]; then
                info "  Phase: ${PHASE:-Pending} (${WAIT}s elapsed)"
            fi
            sleep 10; WAIT=$((WAIT + 10))
        done

        if [ "$PHASE" != "Running" ]; then
            warn "Machine not Running after 10 min (current: ${PHASE:-unknown})"
            warn "EC2 provisioning may still be in progress"
        fi
    fi

    # Wait for Node to become Ready (up to 5 min after Machine is Running)
    info "Waiting for worker Node to become Ready..."
    WAIT=0
    NODE_READY=false
    while [ $WAIT -lt 300 ]; do
        WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker \
            --no-headers 2>/dev/null | grep -v "master" || true)
        if [ -n "$WORKER_NODES" ]; then
            READY_COUNT=$(echo "$WORKER_NODES" | grep -c " Ready" || true)
            if [ "$READY_COUNT" -ge "$REPLICAS" ]; then
                NODE_READY=true
                break
            fi
        fi
        sleep 10; WAIT=$((WAIT + 10))
    done

    if [ "$NODE_READY" = true ]; then
        success "Worker node(s) Ready ✓"
    else
        warn "Worker node not Ready yet — may still be joining"
        warn "Monitor with: oc get nodes -w"
    fi
fi
echo ""

###############################################################################
# Step 4: Post-join verification
###############################################################################
info "=== Step 4: Verification ==="

echo ""
info "MachineSet:"
oc get machineset -n openshift-machine-api --no-headers 2>/dev/null | while IFS= read -r line; do
    echo "  $line"
done

echo ""
info "Machines:"
oc get machines -n openshift-machine-api --no-headers 2>/dev/null | while IFS= read -r line; do
    echo "  $line"
done

echo ""
info "Nodes:"
oc get nodes --no-headers 2>/dev/null | while IFS= read -r line; do
    echo "  $line"
done

echo ""
# Pod capacity check
TOTAL_PODS=$(oc get pods -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
info "Total pods across cluster: $TOTAL_PODS"

echo ""
echo "=============================================="
success "Worker node setup complete!"
echo ""
echo "  MachineSet    : $MS_NAME"
echo "  Instance type : $INSTANCE_TYPE"
echo "  Region/AZ     : $AWS_REGION / $AWS_AZ"
echo "  Replicas      : $REPLICAS"
echo ""
echo "  Management:"
echo "  ────────────────────────────────────────────"
echo "  Scale up    : oc scale machineset $MS_NAME -n openshift-machine-api --replicas=2"
echo "  Scale down  : oc scale machineset $MS_NAME -n openshift-machine-api --replicas=0"
echo "  Monitor     : oc get machines -n openshift-machine-api -w"
echo "  Nodes       : oc get nodes -l node-role.kubernetes.io/worker"
echo ""
echo "  ⚠ Cost note:"
echo "    m6a.4xlarge ~ \$0.69/hr (us-east-1). Scale to 0 when not needed."
echo "=============================================="
