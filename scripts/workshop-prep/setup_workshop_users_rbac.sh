#!/bin/bash
###############################################################################
# setup_workshop_rbac.sh
#
# Discover environment-provisioned Keycloak users and grant them
# cluster-admin RBAC + rhods-admins group membership.
#
# What it does:
#   1. Detect Keycloak users from KeycloakRealmImport CR
#   2. Grant cluster-admin ClusterRoleBinding to each user
#   3. Add all users to the rhods-admins group
#
# This script is idempotent -- safe to re-run at any time.
#
# Created: 2026-10-30
# Last modified: 2026-10-30
#
# Usage:
#   bash setup_workshop_rbac.sh
#
# Prerequisites:
#   - oc login completed with cluster-admin privileges
#   - Keycloak deployed with a KeycloakRealmImport CR containing users
###############################################################################
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }

GROUP_NAME="rhods-admins"
KC_NAMESPACE="keycloak"
KC_REALM_IMPORT_NAME="sso"

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
# Step 1/3: Discover Keycloak users from KeycloakRealmImport
###############################################################################
info "=== Step 1/3: Discover Keycloak users ==="

KC_USERS=()
if oc get keycloakrealmimport "$KC_REALM_IMPORT_NAME" -n "$KC_NAMESPACE" &>/dev/null; then
    KC_RAW=$(oc get keycloakrealmimport "$KC_REALM_IMPORT_NAME" -n "$KC_NAMESPACE" \
        -o jsonpath='{.spec.realm.users[*].username}' 2>/dev/null || true)
    for u in $KC_RAW; do
        KC_USERS+=("$u")
    done
    success "Found ${#KC_USERS[@]} Keycloak user(s): ${KC_USERS[*]}"
else
    error "No KeycloakRealmImport '$KC_REALM_IMPORT_NAME' found in namespace '$KC_NAMESPACE'"
    exit 1
fi
echo ""

###############################################################################
# Step 2/3: Grant cluster-admin RBAC to all users
###############################################################################
info "=== Step 2/3: Grant cluster-admin RBAC ==="

BOUND=0
EXISTED=0
for USERNAME in "${KC_USERS[@]}"; do
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
# Step 3/3: Add all users to rhods-admins group
###############################################################################
info "=== Step 3/3: Add users to $GROUP_NAME group ==="

if ! oc get group "$GROUP_NAME" &>/dev/null 2>&1; then
    info "Creating group $GROUP_NAME..."
    oc adm groups new "$GROUP_NAME" &>/dev/null
fi

CURRENT_MEMBERS=$(oc get group "$GROUP_NAME" -o jsonpath='{.users}' 2>/dev/null || echo "[]")
GROUP_ADDED=0
GROUP_EXISTED=0
for USERNAME in "${KC_USERS[@]}"; do
    if echo "$CURRENT_MEMBERS" | grep -q "\"${USERNAME}\""; then
        GROUP_EXISTED=$((GROUP_EXISTED + 1))
    else
        oc adm groups add-users "$GROUP_NAME" "$USERNAME" &>/dev/null
        GROUP_ADDED=$((GROUP_ADDED + 1))
    fi
done

success "$GROUP_NAME: $GROUP_ADDED added, $GROUP_EXISTED already members"
echo ""

###############################################################################
# Summary
###############################################################################
echo "=============================================="
success "Workshop RBAC setup complete."
echo ""
echo "  Users          : ${KC_USERS[*]}"
echo "  RBAC           : cluster-admin (all users)"
echo "  Group          : ${GROUP_NAME} (all users)"
echo "  IDP            : rhbk (Keycloak -- environment-provisioned)"
echo "=============================================="
