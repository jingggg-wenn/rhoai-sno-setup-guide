#!/bin/bash
###############################################################################
# gpu_installation.sh
#
# Create a GPU MachineSet (g6.2xlarge / NVIDIA L4) and configure the
# gpu-profile HardwareProfile with tolerations and nodeSelectors.
#
# This script is idempotent -- safe to re-run at any time.
#
# Created: 2026-10-06
# Last modified: 2026-10-06
#
# Usage:
#   bash gpu_installation.sh
#
# Prerequisites:
#   - oc login completed with cluster-admin privileges
#   - Cluster running on AWS with at least one existing worker MachineSet
#   - RHOAI installed (for HardwareProfile patching)
#   - python3 and PyYAML available (for MachineSet YAML generation)
###############################################################################
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }

###############################################################################
# Prerequisite checks
###############################################################################
if ! oc whoami &>/dev/null; then
    error "Not logged in to an OpenShift cluster. Run 'oc login' first."
    exit 1
fi
info "Logged in as: $(oc whoami)"
echo ""

###############################################################################
# Step 1: GPU MachineSet (g6.2xlarge / NVIDIA L4)
#   Creates the MachineSet definition only (replicas=0). Scale up manually:
#     oc scale machineset <name> -n openshift-machine-api --replicas=1
#   Requires: AWS credentials, existing worker subnet/SG in the cluster.
###############################################################################
info "=== Step 1: GPU MachineSet (g6.2xlarge) ==="

INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null)
if [ -z "$INFRA_ID" ]; then
    warn "Could not determine cluster infra ID — skipping MachineSet creation"
else
    # Derive cluster-specific values from an existing MachineSet
    EXISTING_MS=$(oc get machinesets -n openshift-machine-api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$EXISTING_MS" ]; then
        warn "No existing MachineSet found — skipping GPU MachineSet creation"
    else
        AWS_REGION=$(oc get machineset "$EXISTING_MS" -n openshift-machine-api \
            -o jsonpath='{.spec.template.spec.providerSpec.value.placement.region}' 2>/dev/null)
        AWS_AZ=$(oc get machineset "$EXISTING_MS" -n openshift-machine-api \
            -o jsonpath='{.spec.template.spec.providerSpec.value.placement.availabilityZone}' 2>/dev/null)
        AMI_ID=$(oc get machineset "$EXISTING_MS" -n openshift-machine-api \
            -o jsonpath='{.spec.template.spec.providerSpec.value.ami.id}' 2>/dev/null)
        IAM_PROFILE=$(oc get machineset "$EXISTING_MS" -n openshift-machine-api \
            -o jsonpath='{.spec.template.spec.providerSpec.value.iamInstanceProfile.id}' 2>/dev/null)

        GPU_MS_NAME="${INFRA_ID}-worker-gpu-${AWS_AZ}"

        if oc get machineset "$GPU_MS_NAME" -n openshift-machine-api &>/dev/null; then
            CURRENT_REPLICAS=$(oc get machineset "$GPU_MS_NAME" -n openshift-machine-api \
                -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
            success "GPU MachineSet $GPU_MS_NAME already exists (replicas=$CURRENT_REPLICAS)"
        else
            info "Creating GPU MachineSet: $GPU_MS_NAME (g6.2xlarge, replicas=0)"

            # Extract subnet and security groups from existing MachineSet
            SUBNET_JSON=$(oc get machineset "$EXISTING_MS" -n openshift-machine-api \
                -o jsonpath='{.spec.template.spec.providerSpec.value.subnet}' 2>/dev/null)
            SG_JSON=$(oc get machineset "$EXISTING_MS" -n openshift-machine-api \
                -o jsonpath='{.spec.template.spec.providerSpec.value.securityGroups}' 2>/dev/null)
            TAGS_JSON=$(oc get machineset "$EXISTING_MS" -n openshift-machine-api \
                -o jsonpath='{.spec.template.spec.providerSpec.value.tags}' 2>/dev/null)

            # Build the MachineSet YAML using python for reliable JSON embedding
            python3 -c "
import json, yaml, sys

infra_id = '${INFRA_ID}'
ms_name = '${GPU_MS_NAME}'
region = '${AWS_REGION}'
az = '${AWS_AZ}'
ami_id = '${AMI_ID}'
iam_profile = '${IAM_PROFILE}'
subnet = json.loads('''${SUBNET_JSON}''')
security_groups = json.loads('''${SG_JSON}''')
tags = json.loads('''${TAGS_JSON}''')

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
            'capacity.cluster-autoscaler.kubernetes.io/labels': 'kubernetes.io/arch=amd64,node-role.kubernetes.io/worker-gpu=',
            'machine.openshift.io/GPU': '1',
            'machine.openshift.io/memoryMb': '32768',
            'machine.openshift.io/vCPU': '8',
        },
    },
    'spec': {
        'replicas': 0,
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
                    'node-role.kubernetes.io/worker-gpu': '',
                },
            },
            'spec': {
                'metadata': {
                    'labels': {
                        'node-role.kubernetes.io/worker-gpu': '',
                    },
                },
                'taints': [
                    {
                        'key': 'nvidia.com/gpu',
                        'value': 'True',
                        'effect': 'NoSchedule',
                    },
                ],
                'providerSpec': {
                    'value': {
                        'apiVersion': 'machine.openshift.io/v1beta1',
                        'kind': 'AWSMachineProviderConfig',
                        'instanceType': 'g6.2xlarge',
                        'placement': {
                            'availabilityZone': az,
                            'region': region,
                        },
                        'ami': {'id': ami_id},
                        'iamInstanceProfile': {'id': iam_profile},
                        'subnet': subnet,
                        'securityGroups': security_groups,
                        'tags': tags,
                        'userDataSecret': {'name': 'worker-user-data'},
                        'credentialsSecret': {'name': 'aws-cloud-credentials'},
                        'deviceIndex': 0,
                        'blockDevices': [
                            {
                                'ebs': {
                                    'encrypted': True,
                                    'volumeSize': 100,
                                    'volumeType': 'gp2',
                                    'iops': 0,
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

yaml.dump(ms, sys.stdout, default_flow_style=False)
" | oc apply -f -

            success "GPU MachineSet created: $GPU_MS_NAME (replicas=0)"
            info "  Scale up when needed: oc scale machineset $GPU_MS_NAME -n openshift-machine-api --replicas=1"
        fi
    fi
fi
echo ""

###############################################################################
# Step 2: GPU Hardware Profile scheduling
#   Ensures the gpu-profile HardwareProfile has the correct toleration and
#   nodeSelector so workloads schedule onto tainted GPU worker nodes.
###############################################################################
info "=== Step 2: GPU Hardware Profile scheduling ==="

if oc get hardwareprofile gpu-profile -n redhat-ods-applications &>/dev/null; then
    # Check if scheduling is already configured correctly
    SCHED_TYPE=$(oc get hardwareprofile gpu-profile -n redhat-ods-applications \
        -o jsonpath='{.spec.scheduling.type}' 2>/dev/null || true)
    NODE_SEL_GPU=$(oc get hardwareprofile gpu-profile -n redhat-ods-applications \
        -o jsonpath='{.spec.scheduling.node.nodeSelector.nvidia\.com/gpu\.present}' 2>/dev/null || true)
    # Check if any toleration matches nvidia.com/gpu (not just index 0)
    TOL_KEYS=$(oc get hardwareprofile gpu-profile -n redhat-ods-applications \
        -o jsonpath='{.spec.scheduling.node.tolerations[*].key}' 2>/dev/null || true)
    HAS_GPU_TOL=false
    for k in $TOL_KEYS; do [ "$k" = "nvidia.com/gpu" ] && HAS_GPU_TOL=true; done

    if [ "$SCHED_TYPE" = "Node" ] && [ "$NODE_SEL_GPU" = "true" ] && [ "$HAS_GPU_TOL" = "true" ]; then
        success "gpu-profile scheduling already configured (type=Node, toleration + nodeSelector)"
    else
        info "Patching gpu-profile with GPU toleration and nodeSelector..."
        oc patch hardwareprofile gpu-profile -n redhat-ods-applications --type=merge -p '
spec:
  scheduling:
    type: Node
    node:
      nodeSelector:
        nvidia.com/gpu.present: "true"
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
'
        success "gpu-profile patched: toleration=nvidia.com/gpu:NoSchedule, nodeSelector=nvidia.com/gpu.present"
    fi
else
    warn "gpu-profile HardwareProfile not found in redhat-ods-applications — create it via the dashboard first"
fi
echo ""

echo "=============================================="
success "GPU installation complete."
echo ""
echo "  Next steps:"
echo "  • Scale up GPU node:"
echo "    oc scale machineset <gpu-ms-name> -n openshift-machine-api --replicas=1"
echo ""
echo "  • Monitor node join:"
echo "    oc get machines -n openshift-machine-api -w"
echo "    oc get nodes -l node-role.kubernetes.io/worker-gpu="
echo ""
echo "  • Verify GPU detection (after node joins):"
echo "    oc get nodes -l nvidia.com/gpu.present=true"
echo "=============================================="
