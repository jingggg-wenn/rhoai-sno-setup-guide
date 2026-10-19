#!/bin/bash
###############################################################################
# create_workshop_users.sh
#
# Create workshop users (user01-user20) with htpasswd IDP,
# cluster-admin RBAC, and rhods-admins group membership.
# Automatically adds a worker node (m6a.4xlarge) to the SNO cluster
# so the single master node doesn't hit pod/resource limits under load.
#
# What it does:
#   1. Add a worker node to the cluster (m6a.4xlarge, same region/AZ as master)
#   2. Generate htpasswd file with user01..userN (password: openshift)
#   3. Create or update the htpass-secret in openshift-config
#   4. Add htpasswd as an identity provider on the OAuth cluster resource
#      (preserves any existing IDPs such as RHBK/RHSSO)
#   5. Grant cluster-admin ClusterRoleBinding to each user
#   6. Add all users to the rhods-admins group (RHOAI admin access)
#   7. Wait for OAuth pods to roll out
#
# This script is idempotent -- safe to re-run at any time.
#
# Created: 2026-10-06
# Last modified: 2026-10-19
#
# Usage:
#   bash create_workshop_users.sh [--num-users=<N>]
#
# Options:
#   --num-users=<N>                Number of users to create (default: 20)
#   --skip-worker-node             Skip worker node addition
#   --worker-instance-type=<type>  EC2 instance type for worker (default: m6a.4xlarge)
#
# Examples:
#   bash create_workshop_users.sh                  # creates user01..user20 + worker node
#   bash create_workshop_users.sh --num-users=5    # creates user01..user05 + worker node
#   bash create_workshop_users.sh --skip-worker-node   # users only, no worker node
#   bash create_workshop_users.sh --worker-instance-type=m6a.8xlarge  # bigger worker
#
# Prerequisites:
#   - oc login completed with cluster-admin privileges
#   - htpasswd CLI available (macOS built-in, httpd-tools on RHEL)
#   - python3 available (for worker node MachineSet generation)
#   - Cluster running on AWS (for worker node addition)
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }

USER_PREFIX="user"
USER_COUNT=20
USER_PASSWORD="openshift"
SKIP_WORKER_NODE=false
WORKER_INSTANCE_TYPE="m6a.4xlarge"

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --num-users=*)
            USER_COUNT="${arg#*=}"
            if ! [[ "$USER_COUNT" =~ ^[0-9]+$ ]] || [ "$USER_COUNT" -lt 1 ]; then
                echo -e "${RED}[ERR]${NC}  --num-users must be a positive integer (got: ${arg#*=})"
                exit 1
            fi
            ;;
        --skip-worker-node)
            SKIP_WORKER_NODE=true
            ;;
        --worker-instance-type=*)
            WORKER_INSTANCE_TYPE="${arg#*=}"
            ;;
        -h|--help)
            echo "Usage: bash create_workshop_users.sh [--num-users=<N>] [--skip-worker-node] [--worker-instance-type=<type>]"
            echo "  --num-users=<N>                Number of users to create (default: 20)"
            echo "  --skip-worker-node             Skip worker node addition"
            echo "  --worker-instance-type=<type>  Worker instance type (default: m6a.4xlarge)"
            exit 0
            ;;
        *)
            echo -e "${RED}[ERR]${NC}  Unknown argument: $arg"
            echo "Usage: bash create_workshop_users.sh [--num-users=<N>] [--skip-worker-node]"
            exit 1
            ;;
    esac
done
GROUP_NAME="rhods-admins"
SECRET_NAME="htpass-secret"
SECRET_NS="openshift-config"
HTPASSWD_FILE="/tmp/htpasswd-workshop"

###############################################################################
# Prerequisite checks
###############################################################################
if ! oc whoami &>/dev/null; then
    error "Not logged in to an OpenShift cluster. Run 'oc login' first."
    exit 1
fi
info "Logged in as: $(oc whoami)"
info "User count: $USER_COUNT (${USER_PREFIX}01 .. ${USER_PREFIX}$(printf '%02d' "$USER_COUNT"))"

if ! command -v htpasswd &>/dev/null; then
    error "'htpasswd' not found. Install httpd-tools (RHEL) or apache2-utils (Debian)."
    exit 1
fi
echo ""

###############################################################################
# Step 1: Add worker node (SNO capacity expansion)
#   SNO master has a 250 pod limit per node. With 20 workshop users each
#   running a workbench + model serving, pod count easily exceeds this.
#   Worker node is added first because EC2 provisioning takes ~5 min and
#   can proceed in parallel while we set up users + OAuth.
#
#   Calls ../add-worker-node.sh which:
#   - Detects master node region/AZ from existing Machine object
#   - Creates a MachineSet (m6a.4xlarge) in the same region/AZ
#   - Starts provisioning (does not block until node is fully Ready)
###############################################################################
if [ "$SKIP_WORKER_NODE" = true ]; then
    info "=== Step 1/7: Worker node [SKIPPED] ==="
    echo ""
else
    info "=== Step 1/7: Worker node (capacity expansion) ==="

    # Calculate worker count: 1 per 20 users (minimum 1)
    WORKER_COUNT=$(( (USER_COUNT + 19) / 20 ))
    [ "$WORKER_COUNT" -lt 1 ] && WORKER_COUNT=1
    info "Users: $USER_COUNT → $WORKER_COUNT worker node(s) ($WORKER_INSTANCE_TYPE)"

    WORKER_SCRIPT="$SCRIPT_DIR/../add-worker-node.sh"
    if [ -f "$WORKER_SCRIPT" ]; then
        bash "$WORKER_SCRIPT" --instance-type "$WORKER_INSTANCE_TYPE" --replicas "$WORKER_COUNT"
        echo ""
    else
        warn "Worker node script not found: $WORKER_SCRIPT"
        warn "Run manually: bash scripts/add-worker-node.sh"
        echo ""
    fi
fi

###############################################################################
# Step 2/7: Generate htpasswd file
###############################################################################
info "=== Step 2/7: Generate htpasswd file ==="

rm -f "$HTPASSWD_FILE"

# If the secret already exists, extract the current file so we preserve
# any users that were added outside this script (e.g. 'admin').
if oc get secret "$SECRET_NAME" -n "$SECRET_NS" &>/dev/null; then
    info "Extracting existing htpasswd data from secret..."
    oc get secret "$SECRET_NAME" -n "$SECRET_NS" \
        -o jsonpath='{.data.htpasswd}' | base64 -d > "$HTPASSWD_FILE" 2>/dev/null || true
fi

# If we got a file with content, append; otherwise create fresh
if [ -s "$HTPASSWD_FILE" ]; then
    info "Existing htpasswd file has $(wc -l < "$HTPASSWD_FILE" | tr -d ' ') entries"
else
    info "Starting with a fresh htpasswd file"
    # Seed with a base 'admin' user
    htpasswd -c -B -b "$HTPASSWD_FILE" "admin" "$USER_PASSWORD" 2>/dev/null
fi

ADDED=0
SKIPPED=0
for i in $(seq -w 1 "$USER_COUNT"); do
    USERNAME="${USER_PREFIX}${i}"
    if grep -q "^${USERNAME}:" "$HTPASSWD_FILE" 2>/dev/null; then
        SKIPPED=$((SKIPPED + 1))
    else
        htpasswd -B -b "$HTPASSWD_FILE" "$USERNAME" "$USER_PASSWORD" 2>/dev/null
        ADDED=$((ADDED + 1))
    fi
done

success "htpasswd file ready: $ADDED added, $SKIPPED already present"
echo ""

###############################################################################
# Step 3/7: Create or update the htpasswd secret
###############################################################################
info "=== Step 3/7: Create/update htpasswd secret ==="

if oc get secret "$SECRET_NAME" -n "$SECRET_NS" &>/dev/null; then
    info "Updating existing secret $SECRET_NAME..."
    oc create secret generic "$SECRET_NAME" \
        --from-file=htpasswd="$HTPASSWD_FILE" \
        -n "$SECRET_NS" \
        --dry-run=client -o yaml | oc replace -f -
    success "Secret $SECRET_NAME updated"
else
    info "Creating secret $SECRET_NAME..."
    oc create secret generic "$SECRET_NAME" \
        --from-file=htpasswd="$HTPASSWD_FILE" \
        -n "$SECRET_NS"
    success "Secret $SECRET_NAME created"
fi
echo ""

###############################################################################
# Step 4/7: Add htpasswd identity provider to OAuth
###############################################################################
info "=== Step 4/7: Configure htpasswd identity provider ==="

EXISTING_IDP=$(oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}' 2>/dev/null || true)

if echo "$EXISTING_IDP" | grep -qw "htpasswd"; then
    success "htpasswd IDP already configured (existing IDPs: $EXISTING_IDP)"
else
    info "Adding htpasswd IDP to OAuth cluster resource..."
    oc get oauth cluster -o json | python3 -c "
import sys, json
oauth = json.load(sys.stdin)
providers = oauth.get('spec', {}).get('identityProviders', []) or []
htpasswd_provider = {
    'name': 'htpasswd',
    'mappingMethod': 'claim',
    'type': 'HTPasswd',
    'htpasswd': {
        'fileData': {
            'name': '${SECRET_NAME}'
        }
    }
}
providers.append(htpasswd_provider)
oauth.setdefault('spec', {})['identityProviders'] = providers
json.dump(oauth, sys.stdout)
" | oc apply -f -
    success "htpasswd IDP added (existing IDPs: $EXISTING_IDP)"
fi
echo ""

###############################################################################
# Step 5/7: Grant cluster-admin RBAC to each user
###############################################################################
info "=== Step 5/7: Grant cluster-admin RBAC ==="

BOUND=0
EXISTED=0
for i in $(seq -w 1 "$USER_COUNT"); do
    USERNAME="${USER_PREFIX}${i}"
    CRB_NAME="cluster-admin-${USERNAME}"
    if oc get clusterrolebinding "$CRB_NAME" &>/dev/null 2>&1; then
        EXISTED=$((EXISTED + 1))
    else
        oc create clusterrolebinding "$CRB_NAME" \
            --clusterrole=cluster-admin \
            --user="$USERNAME" &>/dev/null
        BOUND=$((BOUND + 1))
    fi
done

success "cluster-admin bindings: $BOUND created, $EXISTED already existed"
echo ""

###############################################################################
# Step 6/7: Add users to rhods-admins group
###############################################################################
info "=== Step 6/7: Add users to $GROUP_NAME group ==="

if ! oc get group "$GROUP_NAME" &>/dev/null 2>&1; then
    info "Creating group $GROUP_NAME..."
    oc adm groups new "$GROUP_NAME" &>/dev/null
fi

CURRENT_MEMBERS=$(oc get group "$GROUP_NAME" -o jsonpath='{.users}' 2>/dev/null || echo "[]")
GROUP_ADDED=0
GROUP_EXISTED=0
for i in $(seq -w 1 "$USER_COUNT"); do
    USERNAME="${USER_PREFIX}${i}"
    if echo "$CURRENT_MEMBERS" | grep -q "\"${USERNAME}\""; then
        GROUP_EXISTED=$((GROUP_EXISTED + 1))
    else
        oc adm groups add-users "$GROUP_NAME" "$USERNAME" &>/dev/null
        GROUP_ADDED=$((GROUP_ADDED + 1))
    fi
done

# Also add the original Keycloak admin user to the group
if echo "$CURRENT_MEMBERS" | grep -q '"admin"'; then
    info "admin already in $GROUP_NAME"
else
    oc adm groups add-users "$GROUP_NAME" "admin" &>/dev/null
    GROUP_ADDED=$((GROUP_ADDED + 1))
    info "Added Keycloak 'admin' user to $GROUP_NAME"
fi

success "$GROUP_NAME membership: $GROUP_ADDED added, $GROUP_EXISTED already members"
echo ""

###############################################################################
# Step 7/7: Wait for OAuth rollout
###############################################################################
info "=== Step 7/7: Wait for OAuth pods to roll out ==="

info "Waiting for authentication operator to reconcile (up to 60s)..."
TIMEOUT=60
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    READY=$(oc get pods -n openshift-authentication --no-headers 2>/dev/null \
        | grep -c "Running" || true)
    if [ "$READY" -ge 1 ]; then
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

OAUTH_PODS=$(oc get pods -n openshift-authentication --no-headers 2>/dev/null)
success "OAuth pods:"
echo "$OAUTH_PODS" | sed 's/^/  /'
echo ""

###############################################################################
# Cleanup and summary
###############################################################################
rm -f "$HTPASSWD_FILE"

echo "=============================================="
success "Workshop user setup complete."
echo ""
echo "  Users created : ${USER_PREFIX}01 .. ${USER_PREFIX}$(printf '%02d' $USER_COUNT)"
echo "  Password      : ${USER_PASSWORD}"
echo "  RBAC          : cluster-admin"
echo "  Group         : ${GROUP_NAME}"
if [ "$SKIP_WORKER_NODE" = false ]; then
echo "  Worker node   : $WORKER_INSTANCE_TYPE ($(( (USER_COUNT + 19) / 20 )) node(s))"
fi
echo ""
echo "  Login command:"
API_URL=$(oc whoami --show-server 2>/dev/null || echo "https://api.<cluster>:6443")
echo "    oc login -u ${USER_PREFIX}01 -p ${USER_PASSWORD} ${API_URL}"
echo ""
echo "  Console login : Use 'htpasswd' identity provider"
if [ "$SKIP_WORKER_NODE" = false ]; then
echo ""
echo "  Worker node management:"
echo "    oc get nodes -l node-role.kubernetes.io/worker"
echo "    oc get machines -n openshift-machine-api"
fi
echo "=============================================="
