#!/bin/bash
###############################################################################
# create_workshop_users.sh
#
# Create workshop users (user01-user20) with htpasswd IDP,
# cluster-admin RBAC, and rhods-admins group membership.
#
# What it does:
#   1. Generate htpasswd file with user01..userN (password: openshift)
#   2. Create or update the htpass-secret in openshift-config
#   3. Add htpasswd as an identity provider on the OAuth cluster resource
#      (preserves any existing IDPs such as RHBK/RHSSO)
#   4. Grant cluster-admin ClusterRoleBinding to each user
#   5. Add all users to the rhods-admins group (RHOAI admin access)
#   6. Wait for OAuth pods to roll out
#
# This script is idempotent -- safe to re-run at any time.
#
# Created: 2026-10-06
# Last modified: 2026-10-06
#
# Usage:
#   bash create_workshop_users.sh [--num-users=<N>]
#
# Options:
#   --num-users=<N>   Number of users to create (default: 20)
#
# Examples:
#   bash create_workshop_users.sh                  # creates user01..user20
#   bash create_workshop_users.sh --num-users=5    # creates user01..user05
#   bash create_workshop_users.sh --num-users=50   # creates user01..user50
#
# Prerequisites:
#   - oc login completed with cluster-admin privileges
#   - htpasswd CLI available (macOS built-in, httpd-tools on RHEL)
###############################################################################
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }

USER_PREFIX="user"
USER_COUNT=20
USER_PASSWORD="openshift"

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
        -h|--help)
            echo "Usage: bash create_workshop_users.sh [--num-users=<N>]"
            echo "  --num-users=<N>   Number of users to create (default: 20)"
            exit 0
            ;;
        *)
            echo -e "${RED}[ERR]${NC}  Unknown argument: $arg"
            echo "Usage: bash create_workshop_users.sh [--num-users=<N>]"
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
# Step 1: Generate htpasswd file
###############################################################################
info "=== Step 1: Generate htpasswd file ==="

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
# Step 2: Create or update the htpasswd secret
###############################################################################
info "=== Step 2: Create/update htpasswd secret ==="

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
# Step 3: Add htpasswd identity provider to OAuth
###############################################################################
info "=== Step 3: Configure htpasswd identity provider ==="

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
# Step 4: Grant cluster-admin RBAC to each user
###############################################################################
info "=== Step 4: Grant cluster-admin RBAC ==="

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
# Step 5: Add users to rhods-admins group
###############################################################################
info "=== Step 5: Add users to $GROUP_NAME group ==="

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

success "$GROUP_NAME membership: $GROUP_ADDED added, $GROUP_EXISTED already members"
echo ""

###############################################################################
# Step 6: Wait for OAuth rollout
###############################################################################
info "=== Step 6: Wait for OAuth pods to roll out ==="

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
echo ""
echo "  Login command:"
API_URL=$(oc whoami --show-server 2>/dev/null || echo "https://api.<cluster>:6443")
echo "    oc login -u ${USER_PREFIX}01 -p ${USER_PASSWORD} ${API_URL}"
echo ""
echo "  Console login : Use 'htpasswd' identity provider"
echo "=============================================="
