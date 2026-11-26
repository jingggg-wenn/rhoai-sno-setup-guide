#!/bin/bash
###############################################################################
# sno-enable-all-features-35.sh
#
# Enable all RHOAI 3.5.2 DSC components, dashboard features, and supporting
# operators on a Single Node OpenShift (SNO) cluster provisioned from the
# RHDP "Red Hat OpenShift AI 3" catalog item (RHOAI pre-installed, GPU node
# provisioned).
#
# Ported from rhoai-field-source-setup-guide, where it was developed and
# tested. Operator installs and CR creation are skipped when already present.
#
# Target: RHOAI 3.5.2 on OpenShift 4.22+
#
# --------------------------------------------------------------------------
# Key design decisions
# --------------------------------------------------------------------------
#
# 1. Operators first, then configure.
#    The previous SNO script patched DSC early and installed operators late.
#    This caused the DSCI monitoring to get permanently stuck when COO was
#    not yet ready (the DSCI controller does not self-heal on missing
#    dependencies, unlike the DSC controller which retries per-component).
#    This script installs all operators first, confirms they are Succeeded,
#    then patches DSCI and DSC. This eliminates the stuck-DSCI bug entirely.
#
# 2. RHCL isolated last (network disruption).
#    RHCL triggers Service Mesh 3 installation, which can briefly disrupt
#    the OpenShift ingress layer. All configuration (DSCI, DSC, MLflow,
#    MaaS Gateway, dashboard flags, accelerator rules) is committed before
#    RHCL is installed, so the cluster state is saved even if the terminal
#    disconnects. RHCL is the only operator in a separate phase.
#
# 3. Full DSCI/DSC merge patch.
#    Instead of incremental patching (detect deltas), the script applies a
#    full merge patch of the reference DSCI and DSC specs. This is safe
#    because oc patch --type=merge is additive (does not remove fields not
#    in the patch) and the RHOAI operator reconciles declaratively.
#
# 4. NFD + GPU Operator included.
#    Both are installed early (non-disruptive) with their required CRs
#    (NodeFeatureDiscovery, ClusterPolicy). If the base environment already
#    has them (Succeeded CSV / existing ClusterPolicy), installs are skipped.
#
# 5. No Kueue, no Trainer.
#    Kueue is no longer installed by this script (the previous SNO version
#    installed it and created ResourceFlavors/ClusterQueue/LocalQueue). The
#    reference DSC has kueue set to Removed. Existing Kueue objects on a
#    cluster set up by the old script are left in place (not deleted). Trainer (Kubeflow Trainer v2) is also Removed: it needs
#    the JobSet operator, which this script does not install, and leaving it
#    Managed keeps the DSC Not Ready (PreConditionFailed). The dashboard
#    "trainingJobs" flag is set to false to match (Step 8).
#
# 6. Existing OperatorGroups are respected.
#    Some base environments pre-install operators (e.g. cert-manager with its
#    own cert-manager-operator-og). The install_operator function detects
#    existing OperatorGroups and skips creation to avoid the OLM
#    TooManyOperatorGroups failure. The Subscription is still applied
#    (idempotent) to ensure the desired channel is set.
#
# 7. Kuadrant operator sized for workshops (Step 9).
#    RHCL's default 300Mi memory limit OOMKills the Kuadrant operator once
#    ~30 users create MaaS subscriptions. Step 9 sets 1Gi/4Gi memory and
#    200m/1 CPU through the RHCL OLM Subscription, right after the CSV
#    succeeds and before the Kuadrant CR exists. Patched only when values
#    differ, so re-runs do not restart the operator. Override with
#    KUADRANT_{CPU,MEM}_{REQUEST,LIMIT} environment variables.
#
# 8. DCGM exporter ServiceMonitor (Step 3b).
#    ClusterPolicy sets dcgmExporter.serviceMonitor.enabled so cluster
#    Prometheus scrapes GPU metrics. Existing ClusterPolicies are patched.
#
# 9. Web Terminal operator (end of Step 3a, idempotent, non-blocking).
#    Skipped if the web-terminal CSV is Succeeded or a Subscription exists.
#    Otherwise subscribes in openshift-operators (redhat-operators, catalog
#    default channel). Web Terminal shares the DevWorkspace Operator with
#    DevSpaces: no DWO Subscription is created, DevSpaces is never touched,
#    and the install is deferred if DWO is mid-install or in another
#    namespace. Never aborts the script; status is reported in Step 11.
#
# --------------------------------------------------------------------------
# Execution order
# --------------------------------------------------------------------------
#
#   Step  | What                                          | Risk
#   ------|-----------------------------------------------|------------------
#    1    | Prerequisites check                           | None
#    2    | User Workload Monitoring                      | None
#    3a   | Install 8 non-disruptive operators            | None
#         | (NFD, GPU, cert-manager, LWS, OTel,          |
#         |  Tempo, COO, DevSpaces)                      |
#         | + Web Terminal (skipped if present)           |
#    3b   | Wait for operators + post-install CRs         | None
#         | (NodeFeatureDiscovery, ClusterPolicy,         |
#         |  LWS CR, UIPlugins, CheCluster)              |
#    4    | DSCI merge patch (monitoring config)          | None (COO ready)
#    5    | DSC merge patch (full component activation)   | None (cert-mgr ready)
#    6    | MLflow server + demo project + EvalHub        | None
#         | (+ shared tenant NetworkPolicy, MLflow probe) |
#    7    | MaaS Gateway CRs                              | None
#    8    | Dashboard menu + accelerator rules            | None
#    9    | Install RHCL + Kuadrant + Authorino TLS       | NETWORK DISRUPTION
#   10    | Dashboard restart                             | None
#   11    | Verification (flags NOT READY items)          | None
#
#   Post-install CRs in Step 3b are "create and fire" -- the operator
#   controller reconciles them in the background while Steps 4-8 run.
#   This works because the operator is already installed (CRDs exist,
#   controller is watching). No dependency is missing at creation time.
#   Verification at Step 11 checks final status and flags anything
#   that has not reached Ready.
#
# All steps are idempotent. Safe to re-run at any time.
# If the terminal disconnects during Step 9, operators continue installing
# via OLM in the background. Re-run the script to pick up where it left off.
#
# --------------------------------------------------------------------------
# Usage
# --------------------------------------------------------------------------
#
#   bash sno-enable-all-features-35.sh
#   bash sno-enable-all-features-35.sh --skip-install
#
#   # In Web Terminal, run with nohup to survive disconnections:
#   nohup bash sno-enable-all-features-35.sh > /tmp/sno.log 2>&1 &
#   tail -f /tmp/sno.log
#
# --------------------------------------------------------------------------
# Prerequisites
# --------------------------------------------------------------------------
#
#   - oc login completed with cluster-admin
#   - RHOAI 3.5.2 Operator installed (rhods-operator CSV Succeeded)
#   - DataScienceCluster 'default-dsc' exists
#   - RHDP "Red Hat OpenShift AI 3" SNO environment
#
# Created: 29 Sep 2026
# Last modified: 26 Nov 2026
###############################################################################
set -euo pipefail

SKIP_INSTALL=false
[[ "${1:-}" == "--skip-install" || "${1:-}" == "--skip" ]] && SKIP_INSTALL=true

SCRIPT_START=$(date +%s)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
elapsed() { local now; now=$(date +%s); local e=$((now - SCRIPT_START)); printf '%dm%02ds' $((e/60)) $((e%60)); }
info()    { echo -e "${CYAN}[INFO]${NC} ($(elapsed)) $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }

###############################################################################
# Helper: wait_for -- run a check command in a loop with a progress bar
#
# Usage:
#   wait_for <timeout_sec> <label> <check_command>
#
# The check_command is eval'd each iteration. Returns 0 when the check
# passes, or 1 if the timeout is reached.
###############################################################################
wait_for() {
    local timeout="$1"
    local label="$2"
    shift 2
    local check_cmd="$*"

    local elapsed=0
    local interval=5
    local spin_chars='|/-\'
    local spin_idx=0
    local bar_width=30

    while [ $elapsed -lt "$timeout" ]; do
        if bash -c "$check_cmd" &>/dev/null; then
            printf '\r%-70s\r' " "
            success "$label"
            return 0
        fi

        local pct=$(( elapsed * 100 / timeout ))
        local filled=$(( pct * bar_width / 100 ))
        local empty=$(( bar_width - filled ))
        local spin_char="${spin_chars:$spin_idx:1}"
        spin_idx=$(( (spin_idx + 1) % 4 ))

        local bar=""
        for (( _b=0; _b<filled; _b++ )); do bar+="="; done
        if [ $filled -lt $bar_width ]; then bar+=">"; fi
        for (( _b=0; _b<empty-1; _b++ )); do bar+=" "; done

        printf '\r  %s [%-*s] %3d%% (%ds/%ds) %s' \
            "$spin_char" "$bar_width" "$bar" "$pct" "$elapsed" "$timeout" "$label"

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    printf '\r%-70s\r' " "
    warn "$label -- timeout after ${timeout}s"
    return 1
}

# Operator definitions (used in Step 3a)
# Source column: most use redhat-operators; GPU uses certified-operators.
# RHCL is NOT in this array -- installed separately in Step 9.
declare -a OP_NAMES=( "NFD"                "NVIDIA GPU Operator"             "cert-manager"                    "LWS (LeaderWorkerSet)"       "OpenTelemetry"                    "Tempo"                    "COO (Cluster Observability)"                      "DevSpaces" )
declare -a OP_NS=(    "openshift-nfd"      "nvidia-gpu-operator"             "cert-manager-operator"           "openshift-lws-operator"      "openshift-opentelemetry-operator" "openshift-tempo-operator" "openshift-cluster-observability-operator"          "openshift-operators" )
declare -a OP_GREP=(  "nfd"               "gpu-operator"                     "cert-manager"                    "leader-worker-set"           "opentelemetry"                    "tempo"                    "cluster-observability-operator"                    "devspacesoperator" )
declare -a OP_SUB=(   "nfd"               "gpu-operator-certified"           "openshift-cert-manager-operator" "leader-worker-set"           "opentelemetry-product"            "tempo-product"            "cluster-observability-operator"                    "devspaces" )
declare -a OP_SRC=(   "redhat-operators"  "certified-operators"              "redhat-operators"                "redhat-operators"            "redhat-operators"                 "redhat-operators"         "redhat-operators"                                  "redhat-operators" )
declare -a OP_CH=(    "auto"              "auto"                             "stable-v1"                       "stable-v1.0"                 "stable"                           "stable"                   "stable"                                            "stable" )
declare -a OP_MODE=(  "own"               "own"                              "own"                             "own"                         "all"                              "all"                      "all"                                               "skip" )
declare -a OP_USE=(   "GPU label detection" "GPU drivers + runtime"          "KServe / Model Serving"          "llm-d distributed inference" "Metrics & trace collection"       "Distributed trace store"  "Observe & Monitor dashboard (Perses)"              "Cloud IDE (CheCluster)" )

echo "=============================================="
echo " RHOAI 3.5.2 SNO -- Enable All Features"
echo "=============================================="
echo ""
echo -e "${BOLD}  Step  | What                                       | Risk${NC}"
echo -e "${BOLD}  ------|--------------------------------------------|-----------------${NC}"
echo "   1    | Prerequisites check                        | None"
echo "   2    | User Workload Monitoring                   | None"
echo "   3a   | Install 8 non-disruptive operators         | None"
echo "        | + Web Terminal (skipped if present)        | None"
echo "   3b   | Wait + post-install CRs                    | None"
echo "   4    | DSCI merge patch (monitoring config)       | None (COO ready)"
echo "   5    | DSC merge patch (all components)           | None (cert-mgr)"
echo "   6    | MLflow + demo project + EvalHub            | None"
echo "   7    | MaaS Gateway CRs                           | None"
echo "   8    | Dashboard menu + accelerator rules         | None"
echo -e "   9    | Install RHCL + Kuadrant + Authorino TLS   | ${RED}NETWORK DISRUPTION${NC}"
echo "  10    | Dashboard restart                          | None"
echo "  11    | Verification (flags NOT READY)             | None"
echo ""
info "Steps 1-8 complete before any network disruption (RHCL at Step 9)."
echo ""

###############################################################################
# Helper: install operator via Subscription
###############################################################################
install_operator() {
    local DISPLAY_NAME="$1"
    local NAMESPACE="$2"
    local SUB_NAME="$3"
    local CHANNEL="${4:-stable}"
    local MODE="${5:-own}"       # skip | own | all
    local SOURCE="${6:-redhat-operators}"

    if [ "$CHANNEL" = "auto" ]; then
        CHANNEL=$(oc get packagemanifest "$SUB_NAME" -o jsonpath='{.status.defaultChannel}' 2>/dev/null)
        [ -z "$CHANNEL" ] && CHANNEL="stable"
        info "Auto-detected channel: ${CHANNEL} for ${SUB_NAME}"
    fi

    info "Installing ${DISPLAY_NAME} (ns=${NAMESPACE}, ch=${CHANNEL}, src=${SOURCE}, mode=${MODE})..."

    if [ "$MODE" = "skip" ]; then
        oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${SUB_NAME}
  namespace: ${NAMESPACE}
spec:
  channel: ${CHANNEL}
  installPlanApproval: Automatic
  name: ${SUB_NAME}
  source: ${SOURCE}
  sourceNamespace: openshift-marketplace
EOF
    elif [ "$MODE" = "all" ]; then
        oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
EOF
        local EXISTING_OG
        EXISTING_OG=$(oc get operatorgroup -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [ "$EXISTING_OG" -eq 0 ]; then
            oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${SUB_NAME}-group
  namespace: ${NAMESPACE}
spec:
  upgradeStrategy: Default
EOF
        else
            info "OperatorGroup already exists in ${NAMESPACE} -- skipping creation"
        fi
        oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${SUB_NAME}
  namespace: ${NAMESPACE}
spec:
  channel: ${CHANNEL}
  installPlanApproval: Automatic
  name: ${SUB_NAME}
  source: ${SOURCE}
  sourceNamespace: openshift-marketplace
EOF
    else
        oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
EOF
        local EXISTING_OG
        EXISTING_OG=$(oc get operatorgroup -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [ "$EXISTING_OG" -eq 0 ]; then
            oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${SUB_NAME}-group
  namespace: ${NAMESPACE}
spec:
  targetNamespaces:
  - ${NAMESPACE}
  upgradeStrategy: Default
EOF
        else
            info "OperatorGroup already exists in ${NAMESPACE} -- skipping creation"
        fi
        oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${SUB_NAME}
  namespace: ${NAMESPACE}
spec:
  channel: ${CHANNEL}
  installPlanApproval: Automatic
  name: ${SUB_NAME}
  source: ${SOURCE}
  sourceNamespace: openshift-marketplace
EOF
    fi
}

###############################################################################
# Helper: check if an operator is installed
# Runs in subprocess to avoid SIGPIPE under set -o pipefail.
###############################################################################
check_operator_installed() {
    local idx="$1"
    local ns="${OP_NS[$idx]}"
    local pattern="${OP_GREP[$idx]}"
    if [ "${OP_SUB[$idx]}" = "rhcl-operator" ]; then
        bash -c 'oc get subscription -A --no-headers 2>/dev/null | grep -q "rhcl-operator"'
    else
        bash -c 'oc get csv -n "'"$ns"'" --no-headers 2>/dev/null | grep -q "'"$pattern"'.*Succeeded"'
    fi
}

###############################################################################
# Helper: install Web Terminal operator (idempotent, non-blocking)
#
# Mirrors the working install on a reference cluster:
#   Subscription web-terminal in openshift-operators (global-operators OG,
#   AllNamespaces), source redhat-operators, channel = catalog default (fast),
#   installPlanApproval Automatic, no startingCSV.
#
# DevSpaces safety: Web Terminal and DevSpaces both depend on the
# DevWorkspace Operator (DWO). This helper never creates a DWO Subscription
# and never touches the DevSpaces Subscription/CheCluster. Web Terminal is
# installed in the same namespace as DevSpaces (openshift-operators) so OLM
# reuses the single existing DWO instead of creating a second one. If DWO is
# mid-install/upgrade or lives in another namespace, the install is deferred.
#
# Every exit path returns 0 with a warn/info message, so a problem here never
# aborts the rest of the script. No wait -- status is reported in Step 11.
###############################################################################
install_web_terminal() {
    local WT_NS="openshift-operators"
    local WT_PKG="web-terminal"
    local WT_SRC="redhat-operators"

    # 1. Already installed (CSV Succeeded) -> nothing to do
    if bash -c 'oc get csv -n "'"$WT_NS"'" --no-headers 2>/dev/null | grep -q "^web-terminal\..*Succeeded"'; then
        success "Web Terminal -- already installed, skipping"
        return 0
    fi

    # 2. Subscription already exists (installing, or created by someone else) -> leave it alone
    local WT_SUB_NS
    WT_SUB_NS=$(oc get subscriptions.operators.coreos.com -A --no-headers 2>/dev/null \
        | awk -v p="$WT_PKG" '$3==p {print $1; exit}' || true)
    if [ -n "$WT_SUB_NS" ]; then
        info "Web Terminal -- Subscription already exists in ${WT_SUB_NS} (CSV not Succeeded yet), not modifying"
        return 0
    fi

    if [ "$SKIP_INSTALL" = true ]; then
        warn "Web Terminal -- not installed, skipping (--skip-install)"
        return 0
    fi

    # 3. Package must be available in the catalog
    local WT_CH
    WT_CH=$(oc get packagemanifest -n openshift-marketplace -l catalog="$WT_SRC" \
        -o jsonpath='{.items[?(@.metadata.name=="'"$WT_PKG"'")].status.defaultChannel}' 2>/dev/null || true)
    if [ -z "$WT_CH" ]; then
        warn "Web Terminal -- package not found in ${WT_SRC} catalog, skipping (install manually from OperatorHub)"
        return 0
    fi

    # 4. openshift-operators must have its AllNamespaces OperatorGroup (never create one there)
    local OG_COUNT
    OG_COUNT=$(oc get operatorgroup -n "$WT_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$OG_COUNT" -ne 1 ]; then
        warn "Web Terminal -- expected 1 OperatorGroup in ${WT_NS}, found ${OG_COUNT}; skipping"
        return 0
    fi

    # 5. DevWorkspace Operator safety (shared with DevSpaces)
    local DWO_SUB_NS
    DWO_SUB_NS=$(oc get subscriptions.operators.coreos.com -A --no-headers 2>/dev/null \
        | awk '$3=="devworkspace-operator" {print $1; exit}' || true)
    if [ -n "$DWO_SUB_NS" ] && [ "$DWO_SUB_NS" != "$WT_NS" ]; then
        warn "Web Terminal -- DevWorkspace Operator is subscribed in ${DWO_SUB_NS} (expected ${WT_NS}); skipping to avoid a duplicate DWO"
        return 0
    fi
    local DWO_PHASE
    DWO_PHASE=$(oc get csv -n "$WT_NS" --no-headers 2>/dev/null \
        | awk '$1 ~ /^devworkspace-operator\./ {print $NF; exit}' || true)
    if [ -n "$DWO_PHASE" ] && [ "$DWO_PHASE" != "Succeeded" ]; then
        warn "Web Terminal -- DevWorkspace Operator is ${DWO_PHASE} (shared with DevSpaces); deferring. Re-run the script later."
        return 0
    fi
    if [ -n "$DWO_PHASE" ]; then
        info "DevWorkspace Operator already present (shared with DevSpaces) -- OLM will reuse it"
    else
        info "DevWorkspace Operator not present -- OLM will resolve it as a Web Terminal dependency"
    fi

    # 6. Create the Subscription (create and fire)
    info "Installing Web Terminal (ns=${WT_NS}, ch=${WT_CH}, src=${WT_SRC}, mode=skip)..."
    if oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${WT_PKG}
  namespace: ${WT_NS}
spec:
  channel: ${WT_CH}
  installPlanApproval: Automatic
  name: ${WT_PKG}
  source: ${WT_SRC}
  sourceNamespace: openshift-marketplace
EOF
    then
        success "Web Terminal Subscription created (installing in background, verified in Step 11)"
    else
        warn "Web Terminal -- Subscription apply failed; continuing (install manually from OperatorHub)"
    fi
    return 0
}

###############################################################################
# Step 1: Prerequisites (abort if missing)
###############################################################################
info "=== Step 1/11: Prerequisites ==="

if ! oc whoami &>/dev/null; then
    error "oc login required"
    exit 1
fi
success "Logged in: $(oc whoami) @ $(oc whoami --show-server)"

RHOAI_CSV=$(oc get csv -n redhat-ods-operator --no-headers 2>/dev/null | grep rhods | awk '{print $1}' || true)
if [ -z "$RHOAI_CSV" ]; then
    error "RHOAI Operator not installed"
    echo "  Install it first: from OperatorHub (Software Catalog)"
    exit 1
fi
success "RHOAI: $(echo "$RHOAI_CSV" | sed 's/rhods-operator\.//')"

if ! oc get datasciencecluster default-dsc &>/dev/null; then
    error "DataScienceCluster 'default-dsc' not found"
    exit 1
fi
success "DSC: default-dsc"

if ! oc get dscinitialization default-dsci &>/dev/null; then
    error "DSCInitialization 'default-dsci' not found"
    exit 1
fi
success "DSCI: default-dsci"
echo ""

###############################################################################
# Step 2: User Workload Monitoring
###############################################################################
info "=== Step 2/11: User Workload Monitoring ==="

if oc get configmap cluster-monitoring-config -n openshift-monitoring &>/dev/null 2>&1; then
    EXISTING=$(oc get configmap cluster-monitoring-config -n openshift-monitoring \
      -o jsonpath='{.data.config\.yaml}' 2>/dev/null)
    if echo "$EXISTING" | grep -q "enableUserWorkload: true"; then
        success "User Workload Monitoring already enabled"
    else
        warn "cluster-monitoring-config exists but enableUserWorkload not set -- patching"
        oc apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
        success "User Workload Monitoring enabled"
    fi
else
    oc apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
    success "User Workload Monitoring enabled"
fi

wait_for 60 "User Workload Monitoring pods" \
    '[ "$(oc get pods -n openshift-user-workload-monitoring --no-headers 2>/dev/null | grep -c Running)" -ge 2 ]'
echo ""

###############################################################################
# Step 3a: Install 8 non-disruptive operators
###############################################################################
info "=== Step 3a/11: Install non-disruptive operators ==="

declare -a MISSING_NAMES=()
declare -a MISSING_NS=()
declare -a MISSING_GREP=()
declare -a MISSING_IDX=()

for i in "${!OP_NAMES[@]}"; do
    if check_operator_installed "$i"; then
        success "${OP_NAMES[$i]}"
    else
        warn "${OP_NAMES[$i]} -- not installed (needed for: ${OP_USE[$i]})"
        MISSING_NAMES+=("${OP_NAMES[$i]}")
        MISSING_NS+=("${OP_NS[$i]}")
        MISSING_GREP+=("${OP_GREP[$i]}")
        MISSING_IDX+=("$i")
    fi
done

echo ""

if [ ${#MISSING_NAMES[@]} -gt 0 ]; then
    echo -e "${BOLD}+-----------------------------------------------------------+${NC}"
    echo -e "${BOLD}|  ${#MISSING_NAMES[@]} operator(s) to install                               |${NC}"
    echo -e "${BOLD}+-----------------------------------------------------------+${NC}"
    for j in "${!MISSING_NAMES[@]}"; do
        printf "${BOLD}|${NC}  %-3s %-30s  %s\n" "$((j+1))." "${MISSING_NAMES[$j]}" "${OP_USE[${MISSING_IDX[$j]}]}"
    done
    echo -e "${BOLD}+-----------------------------------------------------------+${NC}"

    if [ "$SKIP_INSTALL" = true ]; then
        warn "Skipping operator install (--skip-install)"
        CONSOLE_URL=$(oc whoami --show-console 2>/dev/null || echo "")
        [ -n "$CONSOLE_URL" ] && echo -e "  Install manually: ${CYAN}${CONSOLE_URL}/operatorhub${NC}"
        echo ""
    else
        info "Auto-installing missing operators..."
        echo ""
        for j in "${!MISSING_IDX[@]}"; do
            idx=${MISSING_IDX[$j]}
            install_operator \
                "${OP_NAMES[$idx]}" "${OP_NS[$idx]}" "${OP_SUB[$idx]}" \
                "${OP_CH[$idx]}" "${OP_MODE[$idx]}" "${OP_SRC[$idx]}"
        done
        echo ""

        # Per-operator wait with individual progress bars
        info "Waiting for each operator to reach Succeeded..."
        for j in "${!MISSING_NAMES[@]}"; do
            wait_for 480 "${MISSING_NAMES[$j]}" \
                'oc get csv -n "'"${MISSING_NS[$j]}"'" --no-headers 2>/dev/null | grep -q "'"${MISSING_GREP[$j]}"'.*Succeeded"'
        done
    fi
else
    success "All non-disruptive operators already installed"
fi
echo ""

# Web Terminal -- after the loop so DevSpaces (and its DevWorkspace Operator)
# has settled first. Non-blocking: never aborts the script, no wait.
info "Web Terminal operator:"
install_web_terminal || warn "Web Terminal -- unexpected error, continuing"
echo ""

###############################################################################
# Step 3b: Post-install CRs (create and fire)
###############################################################################
info "=== Step 3b/11: Post-install CRs ==="

# --- NodeFeatureDiscovery (requires NFD operator) ---
if oc get crd nodefeaturediscoveries.nfd.openshift.io &>/dev/null 2>&1; then
    if oc get nodefeaturediscovery nfd-instance -n openshift-nfd &>/dev/null 2>&1; then
        success "NodeFeatureDiscovery CR already exists"
    else
        info "Creating NodeFeatureDiscovery CR..."
        oc apply -f - <<'EOF'
apiVersion: nfd.openshift.io/v1
kind: NodeFeatureDiscovery
metadata:
  name: nfd-instance
  namespace: openshift-nfd
spec:
  operand:
    image: registry.redhat.io/openshift4/ose-node-feature-discovery-rhel9:latest
    servicePort: 12000
  workerConfig:
    configData: |
      core:
        sleepInterval: 60s
      sources:
        pci:
          deviceClassWhitelist:
            - "0200"
            - "03"
            - "12"
          deviceLabelFields:
            - "vendor"
EOF
        success "NodeFeatureDiscovery CR created"
    fi
else
    warn "NFD CRD not ready yet -- NodeFeatureDiscovery CR deferred"
fi

# --- ClusterPolicy (requires NVIDIA GPU Operator) ---
if oc get crd clusterpolicies.nvidia.com &>/dev/null 2>&1; then
    if oc get clusterpolicy gpu-cluster-policy &>/dev/null 2>&1; then
        success "ClusterPolicy already exists"
        # Existing clusters may predate the serviceMonitor setting below.
        # Without it, cluster Prometheus never scrapes DCGM and the console
        # GPU dashboards stay empty. Merge patch is idempotent.
        oc patch clusterpolicy gpu-cluster-policy --type merge \
            -p '{"spec":{"dcgmExporter":{"serviceMonitor":{"enabled":true}}}}' >/dev/null \
            && success "ClusterPolicy dcgmExporter.serviceMonitor enabled" \
            || warn "Could not enable dcgmExporter.serviceMonitor on ClusterPolicy"
    else
        info "Creating ClusterPolicy (GPU Operator CR)..."
        oc apply -f - <<'EOF'
apiVersion: nvidia.com/v1
kind: ClusterPolicy
metadata:
  name: gpu-cluster-policy
spec:
  operator:
    defaultRuntime: crio
    use_ocp_driver_toolkit: true
  daemonsets: {}
  dcgm:
    enabled: true
  dcgmExporter:
    enabled: true
    config:
      name: ""
    # Creates the nvidia-dcgm-exporter ServiceMonitor so cluster Prometheus
    # scrapes GPU metrics (OpenShift console GPU dashboards).
    serviceMonitor:
      enabled: true
  devicePlugin:
    config:
      name: ""
  driver:
    enabled: true
    certConfig:
      name: ""
    kernelModuleConfig:
      name: ""
    licensingConfig:
      nlsEnabled: false
      name: ""
    repoConfig:
      name: ""
    upgradePolicy:
      autoUpgrade: true
      drain:
        deleteEmptyDir: false
        enable: false
        force: false
        timeoutSeconds: 300
      maxParallelUpgrades: 1
      maxUnavailable: 25%
    virtualTopology:
      config: ""
  gfd:
    enabled: true
  migManager:
    enabled: true
  mps: {}
  nodeStatusExporter:
    enabled: true
  sandboxDevicePlugin:
    enabled: true
  sandboxWorkloads:
    enabled: false
  toolkit:
    enabled: true
  validator:
    plugin:
      env:
        - name: WITH_WORKLOAD
          value: "false"
  vfioManager:
    enabled: true
  vgpuDeviceManager:
    enabled: true
  vgpuManager:
    enabled: false
EOF
        success "ClusterPolicy created"
    fi
else
    warn "GPU Operator CRD not ready yet -- ClusterPolicy deferred"
fi

# --- LeaderWorkerSetOperator CR (requires LWS operator) ---
if oc get crd leaderworkersetoperators.operator.openshift.io &>/dev/null 2>&1; then
    if oc get leaderworkersetoperator cluster -n openshift-lws-operator &>/dev/null 2>&1; then
        success "LeaderWorkerSetOperator CR already exists"
    else
        info "Creating LeaderWorkerSetOperator CR..."
        oc apply -f - <<'EOF'
apiVersion: operator.openshift.io/v1
kind: LeaderWorkerSetOperator
metadata:
  name: cluster
  namespace: openshift-lws-operator
spec:
  managementState: Managed
  logLevel: Normal
  operatorLogLevel: Normal
EOF
        success "LeaderWorkerSetOperator CR created"
    fi
else
    warn "LWS CRD not ready yet -- LeaderWorkerSetOperator CR deferred"
fi

# --- UIPlugins (requires COO) ---
if oc get crd uiplugins.observability.openshift.io &>/dev/null 2>&1; then
    info "Configuring UIPlugins..."
    oc apply -f - <<'EOF'
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: dashboards
spec:
  type: Dashboards
---
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: monitoring
spec:
  type: Monitoring
  monitoring:
    perses:
      enabled: true
EOF
    success "UIPlugins (dashboards + monitoring) configured"
else
    warn "COO CRD not ready yet -- UIPlugins deferred"
fi

# --- CheCluster (requires DevSpaces operator) ---
DEVSPACES_NS="openshift-devspaces"
if oc get crd checlusters.org.eclipse.che &>/dev/null 2>&1; then
    if ! oc get namespace "$DEVSPACES_NS" &>/dev/null; then
        info "Creating namespace $DEVSPACES_NS..."
        oc create namespace "$DEVSPACES_NS"
    fi
    if oc get checluster devspaces -n "$DEVSPACES_NS" &>/dev/null; then
        DS_PHASE=$(oc get checluster devspaces -n "$DEVSPACES_NS" \
            -o jsonpath='{.status.chePhase}' 2>/dev/null || echo "Unknown")
        success "CheCluster already exists (phase: $DS_PHASE)"
    else
        info "Creating CheCluster in $DEVSPACES_NS..."
        oc apply -f - <<'CHEEOF'
apiVersion: org.eclipse.che/v2
kind: CheCluster
metadata:
  name: devspaces
  namespace: openshift-devspaces
spec:
  components:
    cheServer:
      debug: false
      logLevel: INFO
    dashboard: {}
    devWorkspace: {}
    devfileRegistry: {}
    imagePuller:
      enable: false
    metrics:
      enable: true
    pluginRegistry: {}
  containerRegistry: {}
  devEnvironments:
    startTimeoutSeconds: 300
    secondsOfRunBeforeIdling: -1
    maxNumberOfWorkspacesPerUser: 5
    maxNumberOfRunningWorkspacesPerUser: 1
    containerBuildConfiguration:
      openShiftSecurityContextConstraint: container-build
    defaultEditor: che-incubator/che-code/latest
    defaultComponents:
    - name: dev-tools
      container:
        image: registry.redhat.io/devspaces/udi-rhel8:latest
        memoryLimit: 4Gi
        cpuLimit: "2"
    defaultNamespace:
      autoProvision: true
      template: <username>-devspaces
    security:
      containerSecurityContext:
        allowPrivilegeEscalation: true
        runAsUser: 1234
    storage:
      pvcStrategy: per-user
  gitServices: {}
  networking: {}
CHEEOF
        success "CheCluster CR created (reconciling in background)"
    fi
else
    warn "DevSpaces CRD not ready yet -- CheCluster deferred"
fi
echo ""

###############################################################################
# Step 4: DSCI merge patch
#   COO + Tempo + OTel MUST be installed BEFORE this step. Otherwise DSCI
#   sets Ready=Error and MonitoringStack/Perses are never provisioned.
###############################################################################
info "=== Step 4/11: DSCI merge patch ==="

# Verify COO is ready before patching monitoring
COO_OK=false
if bash -c 'oc get csv -n openshift-cluster-observability-operator --no-headers 2>/dev/null | grep -q "cluster-observability-operator.*Succeeded"'; then
    COO_OK=true
    success "COO is Succeeded -- safe to patch DSCI monitoring"
else
    warn "COO not yet Succeeded -- waiting up to 3 min before patching DSCI..."
    if wait_for 180 "COO Succeeded" \
        'oc get csv -n openshift-cluster-observability-operator --no-headers 2>/dev/null | grep -q "cluster-observability-operator.*Succeeded"'; then
        COO_OK=true
    else
        warn "COO still not ready -- patching DSCI anyway (monitoring may need re-trigger later)"
    fi
fi

# Check current DSCI error state
DSCI_READY=$(oc get dscinitialization default-dsci \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
DSCI_REASON=$(oc get dscinitialization default-dsci \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null)

NEED_RETRIGGER=false
if [ "$DSCI_READY" = "False" ] && [ "$DSCI_REASON" = "Error" ]; then
    warn "DSCI stuck in Error state -- will re-trigger reconciliation after patch"
    NEED_RETRIGGER=true
fi

info "Applying full DSCI merge patch (monitoring: Managed, metrics, traces)..."
oc patch dscinitialization default-dsci --type=merge -p '{
  "spec": {
    "applicationsNamespace": "redhat-ods-applications",
    "monitoring": {
      "managementState": "Managed",
      "namespace": "redhat-ods-monitoring",
      "alerting": {},
      "metrics": {
        "replicas": 1,
        "storage": {
          "size": "5Gi",
          "retention": "90d"
        }
      },
      "traces": {
        "sampleRatio": "0.1",
        "storage": {
          "backend": "pv",
          "retention": "2160h"
        }
      }
    },
    "trustedCABundle": {
      "customCABundle": "",
      "managementState": "Managed"
    }
  }
}'
success "DSCI patched"

if [ "$NEED_RETRIGGER" = true ]; then
    info "Re-triggering DSCI reconciliation..."
    oc annotate dscinitialization default-dsci \
        "opendatahub.io/retrigger=$(date +%s)" --overwrite 2>/dev/null || true
fi

# Wait for MonitoringStack + Perses
if $COO_OK; then
    wait_for 180 "MonitoringStack" \
        'oc get dscinitialization default-dsci -o jsonpath="{.status.conditions[?(@.type==\"MonitoringStackAvailable\")].status}" 2>/dev/null | grep -q True'

    # If DSCI still errored, restart RHOAI operator to re-trigger
    MON_STATUS=$(oc get dscinitialization default-dsci \
        -o jsonpath='{.status.conditions[?(@.type=="MonitoringStackAvailable")].status}' 2>/dev/null || true)
    if [ "${MON_STATUS:-}" != "True" ]; then
        DSCI_READY2=$(oc get dscinitialization default-dsci \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        if [ "$DSCI_READY2" = "False" ]; then
            warn "DSCI still not Ready -- restarting RHOAI operator..."
            oc delete pod -n redhat-ods-operator -l name=rhods-operator --force --grace-period=0 2>/dev/null || true
            wait_for 180 "MonitoringStack (after restart)" \
                'oc get dscinitialization default-dsci -o jsonpath="{.status.conditions[?(@.type==\"MonitoringStackAvailable\")].status}" 2>/dev/null | grep -q True'
        fi
    fi

    wait_for 120 "Perses" \
        'oc get dscinitialization default-dsci -o jsonpath="{.status.conditions[?(@.type==\"PersesAvailable\")].status}" 2>/dev/null | grep -q True'
fi
echo ""

###############################################################################
# Step 5: DSC merge patch
#   cert-manager must be Succeeded before this step (KServe depends on it).
###############################################################################
info "=== Step 5/11: DSC merge patch ==="

CERTMGR_OK=false
if bash -c 'oc get csv -n cert-manager-operator --no-headers 2>/dev/null | grep -q "cert-manager.*Succeeded"'; then
    CERTMGR_OK=true
else
    warn "cert-manager not yet Succeeded -- waiting up to 2 min..."
    if wait_for 120 "cert-manager Succeeded" \
        'oc get csv -n cert-manager-operator --no-headers 2>/dev/null | grep -q "cert-manager.*Succeeded"'; then
        CERTMGR_OK=true
    fi
fi

info "Applying full DSC merge patch (all components)..."
oc patch datasciencecluster default-dsc --type=merge -p '{
  "spec": {
    "components": {
      "aigateway": {
        "managementState": "Managed",
        "modelsAsAService": {
          "managementState": "Managed"
        }
      },
      "aipipelines": {
        "managementState": "Managed"
      },
      "dashboard": {
        "managementState": "Managed"
      },
      "feastoperator": {
        "managementState": "Managed"
      },
      "kserve": {
        "managementState": "Managed",
        "modelsAsService": {
          "managementState": "Removed"
        },
        "nim": {
          "airGapped": false,
          "managementState": "Managed"
        },
        "rawDeploymentServiceConfig": "Headless",
        "wva": {
          "managementState": "Removed"
        }
      },
      "kueue": {
        "autoCreateQueues": false,
        "defaultClusterQueueName": "default",
        "defaultLocalQueueName": "default",
        "managementState": "Removed"
      },
      "llamastackoperator": {
        "managementState": "Removed"
      },
      "mlflowoperator": {
        "managementState": "Managed"
      },
      "modelregistry": {
        "managementState": "Managed",
        "registriesNamespace": "rhoai-model-registries"
      },
      "ogx": {
        "managementState": "Managed"
      },
      "ray": {
        "managementState": "Managed"
      },
      "trainer": {
        "managementState": "Removed"
      },
      "trainingoperator": {
        "managementState": "Managed"
      },
      "trustyai": {
        "managementState": "Managed",
        "mcpGuardrailsMode": false
      },
      "workbenches": {
        "managementState": "Managed",
        "workbenchNamespace": "rhods-notebooks"
      }
    }
  }
}'
success "DSC patched (all components activated)"

wait_for 90 "OGX CRD" \
    'oc get crd ogxservers.ogx.io &>/dev/null 2>&1' || true
echo ""

###############################################################################
# Step 6: MLflow server + demo project + EvalHub
###############################################################################
info "=== Step 6/11: MLflow server + demo project + EvalHub ==="

MLFLOW_NS="redhat-ods-applications"

# Ensure demo namespace
if oc get ns demo &>/dev/null 2>&1; then
    success "Namespace 'demo' exists"
else
    info "Creating namespace 'demo'..."
    oc create namespace demo 2>/dev/null || true
fi
oc label namespace demo opendatahub.io/dashboard=true --overwrite 2>/dev/null || true
oc label namespace demo opendatahub.io/generated-namespace=true --overwrite 2>/dev/null || true
success "demo labeled as Data Science Project"

# Wait for MLflow CRD
wait_for 120 "MLflow CRD" \
    'oc get crd mlflows.mlflow.opendatahub.io &>/dev/null 2>&1' || true

if oc get crd mlflows.mlflow.opendatahub.io &>/dev/null 2>&1; then
    success "MLflow CRD registered"

    MLFLOW_BACKEND="sqlite"

    # PostgreSQL health check + mlflow-db-credentials secret
    if oc get deployment postgres -n "$MLFLOW_NS" &>/dev/null 2>&1; then
        PG_READY=$(oc get pods -n "$MLFLOW_NS" -l app=postgres \
            -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || true)

        if [ "$PG_READY" != "true" ]; then
            PG_WAITING=$(oc get pods -n "$MLFLOW_NS" -l app=postgres \
                -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)
            if [ "$PG_WAITING" = "CrashLoopBackOff" ]; then
                warn "PostgreSQL in CrashLoopBackOff -- recovering..."
                oc scale deployment postgres -n "$MLFLOW_NS" --replicas=0 2>/dev/null
                sleep 3
                oc delete pvc postgres-data -n "$MLFLOW_NS" 2>/dev/null || true
                oc apply -n "$MLFLOW_NS" -f - <<'PGPVC'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
  labels: { app: postgres, purpose: poc }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 20Gi } }
PGPVC
                oc scale deployment postgres -n "$MLFLOW_NS" --replicas=1 2>/dev/null
            fi
            wait_for 60 "PostgreSQL ready" \
                'oc get pods -n "'"$MLFLOW_NS"'" -l app=postgres -o jsonpath="{.items[0].status.containerStatuses[0].ready}" 2>/dev/null | grep -q true'
            PG_READY=$(oc get pods -n "$MLFLOW_NS" -l app=postgres \
                -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || true)
        fi

        if [ "$PG_READY" = "true" ]; then
            success "PostgreSQL running"
            MLFLOW_BACKEND="postgres"
            PG_FQDN="postgres.${MLFLOW_NS}.svc.cluster.local"
            PG_PASSWORD_ACTUAL=$(oc get deployment postgres -n "$MLFLOW_NS" \
                -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="POSTGRESQL_PASSWORD")].value}' 2>/dev/null)
            PG_USER=$(oc get deployment postgres -n "$MLFLOW_NS" \
                -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="POSTGRESQL_USER")].value}' 2>/dev/null)
            ENCODED_PW=""
            for (( _i=0; _i<${#PG_PASSWORD_ACTUAL}; _i++ )); do
                _c="${PG_PASSWORD_ACTUAL:$_i:1}"
                case "$_c" in
                    [a-zA-Z0-9.~_-]) ENCODED_PW+="$_c" ;;
                    *) ENCODED_PW+=$(printf '%%%02X' "'$_c") ;;
                esac
            done
            MLFLOW_DB_URL="postgresql://${PG_USER}:${ENCODED_PW}@${PG_FQDN}:5432/maas?sslmode=disable"
            if oc get secret mlflow-db-credentials -n "$MLFLOW_NS" &>/dev/null; then
                success "mlflow-db-credentials secret exists"
            else
                oc create secret generic mlflow-db-credentials \
                    --from-literal=database-url="$MLFLOW_DB_URL" \
                    -n "$MLFLOW_NS" --dry-run=client -o yaml | oc apply -f - 2>/dev/null
                success "mlflow-db-credentials secret created"
            fi
        else
            warn "PostgreSQL not ready -- falling back to SQLite"
        fi
    fi

    # MLflow CR: create or recover
    if oc get mlflow mlflow &>/dev/null 2>&1; then
        MLFLOW_AVAILABLE=$(oc get mlflow mlflow \
            -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
        if [ "$MLFLOW_AVAILABLE" = "True" ]; then
            success "MLflow server running"
        else
            STUCK_POD=$(oc get pods -n "$MLFLOW_NS" --no-headers 2>/dev/null \
                | grep -E "mlflow-mg.*(CreateContainerConfigError|Error|ImagePullBackOff)" \
                | awk '{print $1}' | head -1)
            if [ -n "$STUCK_POD" ]; then
                JOB_NAME=$(echo "$STUCK_POD" | rev | cut -d'-' -f2- | rev)
                warn "Stuck migration job ($JOB_NAME) -- deleting..."
                oc delete job "$JOB_NAME" -n "$MLFLOW_NS" 2>/dev/null || true
                wait_for 120 "MLflow recovery" \
                    'oc get mlflow mlflow -o jsonpath="{.status.conditions[?(@.type==\"Available\")].status}" 2>/dev/null | grep -q True'
            else
                warn "MLflow exists but not Available -- will reconcile in background"
            fi
        fi
    else
        if [ "$MLFLOW_BACKEND" = "postgres" ]; then
            oc apply -f - <<'EOF'
apiVersion: mlflow.opendatahub.io/v1
kind: MLflow
metadata:
  name: mlflow
spec:
  replicas: 1
  backendStoreUriFrom:
    name: mlflow-db-credentials
    key: database-url
  serveArtifacts: true
  artifactsDestination: "file:///mlflow/artifacts"
  storage:
    size: 10Gi
EOF
            success "MLflow created (PostgreSQL backend)"
        else
            info "No PostgreSQL available -- using SQLite with PVC..."
            oc apply -f - <<'EOF'
apiVersion: mlflow.opendatahub.io/v1
kind: MLflow
metadata:
  name: mlflow
spec:
  serveArtifacts: true
  artifactsDestination: "file:///mlflow/artifacts"
  backendStoreUri: "sqlite:////mlflow/mlflow.db"
  storage:
    size: 10Gi
EOF
            success "MLflow created (SQLite backend)"
        fi
        wait_for 120 "MLflow server" \
            'oc get mlflow mlflow -o jsonpath="{.status.conditions[?(@.type==\"Available\")].status}" 2>/dev/null | grep -q True'
    fi
else
    warn "MLflow CRD not available -- MLflow will be created on next run"
fi

# MLflow client ConfigMaps
info "Creating MLflow client ConfigMaps in demo..."
oc apply -f - <<'MLCEOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: mlflow-client-env
  namespace: demo
data:
  MLFLOW_TRACKING_URI: "https://mlflow.redhat-ods-applications.svc:8443/mlflow"
  MLFLOW_TRACKING_INSECURE_TLS: "true"
  VERIFY_SSL: "false"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: mlflow-autolog-init
  namespace: demo
data:
  sitecustomize.py: |
    import os
    if os.getenv("MLFLOW_TRACKING_URI"):
        try:
            import mlflow, ssl, urllib3
            urllib3.disable_warnings()
            os.environ.setdefault("REQUESTS_CA_BUNDLE", "")
            ssl._create_default_https_context = ssl._create_unverified_context
            mlflow.set_tracking_uri(os.environ["MLFLOW_TRACKING_URI"])
            mlflow.set_experiment(os.getenv("MLFLOW_EXPERIMENT_NAME", "default"))
            mlflow.openai.autolog()
            try:
                mlflow.langchain.autolog()
            except Exception:
                pass
        except ImportError:
            pass
MLCEOF
success "MLflow client ConfigMaps created"

if ! oc get secret mlflow-sa-token -n demo &>/dev/null 2>&1; then
    oc apply -n demo -f - <<'SATEOF'
apiVersion: v1
kind: Secret
metadata:
  name: mlflow-sa-token
  namespace: demo
  annotations:
    kubernetes.io/service-account.name: default
type: kubernetes.io/service-account-token
SATEOF
    success "MLflow SA token secret created"
else
    success "MLflow SA token secret exists"
fi

# --- EvalHub ---
EVALHUB_NS="redhat-ods-applications"
# TrustyAI registers the EvalHub CRD asynchronously after the DSC patch (Step 5).
# Without this wait, a fresh cluster can skip EvalHub creation entirely.
wait_for 180 "EvalHub CRD" \
    'oc get crd evalhubs.trustyai.opendatahub.io &>/dev/null 2>&1' || true
if oc get crd evalhubs.trustyai.opendatahub.io &>/dev/null 2>&1; then
    success "EvalHub CRD registered"
    if oc get evalhub evalhub -n "$EVALHUB_NS" &>/dev/null 2>&1; then
        success "EvalHub already exists in $EVALHUB_NS"
    else
        info "Creating EvalHub (SQLite backend)..."
        oc apply -f - <<EOF
apiVersion: trustyai.opendatahub.io/v1alpha1
kind: EvalHub
metadata:
  name: evalhub
  namespace: ${EVALHUB_NS}
spec:
  replicas: 1
  database:
    type: sqlite
  providers:
    - lm-evaluation-harness
    - garak
    - guidellm
    - lighteval
  collections:
    - leaderboard-v2
    - safety-and-fairness-v1
EOF
        success "EvalHub created"
        wait_for 120 "EvalHub ready" \
            'oc get evalhub evalhub -n "'"$EVALHUB_NS"'" -o jsonpath="{.status.phase}" 2>/dev/null | grep -q Ready'
    fi

    # MLFLOW_TRACKING_URI in EvalHub
    MLFLOW_URI="https://mlflow.${EVALHUB_NS}.svc:8443/mlflow"
    CURRENT_URI=$(oc get evalhub evalhub -n "$EVALHUB_NS" \
        -o jsonpath='{.spec.env[?(@.name=="MLFLOW_TRACKING_URI")].value}' 2>/dev/null || true)
    if [ "$CURRENT_URI" = "$MLFLOW_URI" ]; then
        success "EvalHub MLFLOW_TRACKING_URI already set"
    else
        info "Patching EvalHub with MLFLOW_TRACKING_URI..."
        oc patch evalhub evalhub -n "$EVALHUB_NS" --type=merge -p "
spec:
  env:
  - name: MLFLOW_TRACKING_URI
    value: ${MLFLOW_URI}
"
        success "EvalHub MLFLOW_TRACKING_URI set"
    fi

    # Shared (cluster-level) tenant prerequisites. These are the parts of
    # tenant setup that participants cannot apply from their own namespace.
    # Kept identical to setup_evalhub_tenants() in the field-source repo's
    # workshop-prep/setup_workbench_by_users.sh.
    #
    # The namespace-wide NetworkPolicy in EvalHub's namespace only admits traffic
    # from OpenShift AI generated namespaces. Workshop projects created by script
    # lack that label, so evaluation job sidecars cannot report status/results
    # and jobs stay "pending". Admit any namespace on the kube-rbac-proxy port only.
    info "Allowing tenant evaluation jobs to reach the EvalHub API..."
    if oc apply -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: evalhub-allow-tenant-jobs
  namespace: ${EVALHUB_NS}
  labels:
    app.kubernetes.io/part-of: evalhub-workshop
  annotations:
    description: Allow evaluation job sidecars in participant namespaces to report status and results to the EvalHub API.
spec:
  podSelector:
    matchLabels:
      app: eval-hub
      component: api
      instance: evalhub
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector: {}
    ports:
    - protocol: TCP
      port: 8443
EOF
    then
        success "NetworkPolicy evalhub-allow-tenant-jobs applied in ${EVALHUB_NS}"
    else
        warn "Could not apply NetworkPolicy evalhub-allow-tenant-jobs in ${EVALHUB_NS}"
    fi

    # EvalHub caches its MLflow workspace probe at startup. If it started before
    # MLflow was ready, tenant experiments fail until the API Pod is replaced.
    # Non-fatal: every failure path warns and continues.
    evalhub_refresh_mlflow_probe() {
        local probe_re='"MLflow workspace support probed".*"workspaces_enabled"[[:space:]]*:[[:space:]]*'
        local logs
        if ! oc rollout status deployment/evalhub -n "$EVALHUB_NS" --timeout=180s >/dev/null 2>&1; then
            warn "EvalHub deployment not rolled out -- skipping MLflow workspace probe check (re-run later)"
            return 0
        fi
        if ! logs=$(oc logs deployment/evalhub -c evalhub -n "$EVALHUB_NS" --request-timeout=10s 2>/dev/null); then
            warn "Could not read EvalHub logs -- skipping MLflow workspace probe check"
            return 0
        fi
        # Here-strings, not pipes: under pipefail, grep -q exiting early can make
        # the writer fail with SIGPIPE and turn a real match into "no match".
        if grep -Eq "${probe_re}true" <<<"$logs"; then
            success "EvalHub detected MLflow workspace support"
            return 0
        fi
        if ! grep -Eq "${probe_re}false" <<<"$logs"; then
            info "EvalHub MLflow workspace probe not found in logs -- leaving EvalHub running"
            return 0
        fi
        warn "EvalHub started before MLflow workspace support was available"
        if ! oc rollout status deployment/mlflow -n "$EVALHUB_NS" --timeout=120s >/dev/null 2>&1; then
            warn "MLflow not rolled out -- re-run this script once MLflow is ready"
            return 0
        fi
        if ! oc get --raw "/api/v1/namespaces/${EVALHUB_NS}/services/https:mlflow:8443/proxy/mlflow/api/3.0/mlflow/server-info" \
            --request-timeout=10s 2>/dev/null | grep -E '"workspaces_enabled"[[:space:]]*:[[:space:]]*true' >/dev/null; then
            warn "MLflow does not report workspace support yet -- re-run this script once MLflow is ready"
            return 0
        fi
        warn "Restarting EvalHub API Pod to refresh its MLflow workspace probe (SQLite: custom providers must be re-registered)"
        # The operator reverts Deployment restart annotations; replace the Pod directly.
        if ! oc delete pod -n "$EVALHUB_NS" -l app=eval-hub,component=api,instance=evalhub --wait=true >/dev/null 2>&1 \
            || ! oc rollout status deployment/evalhub -n "$EVALHUB_NS" --timeout=180s >/dev/null 2>&1; then
            warn "EvalHub restart did not complete -- check: oc get pods -n ${EVALHUB_NS} -l app=eval-hub"
            return 0
        fi
        if logs=$(oc logs deployment/evalhub -c evalhub -n "$EVALHUB_NS" --request-timeout=10s 2>/dev/null) \
            && grep -Eq "${probe_re}true" <<<"$logs"; then
            success "EvalHub now detects MLflow workspace support"
        else
            warn "EvalHub still does not report MLflow workspace support -- check the EvalHub startup logs"
        fi
    }
    evalhub_refresh_mlflow_probe

    # RBAC
    info "Configuring EvalHub RBAC for demo namespace..."
    oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: evalhub-central-mlflow-access
  namespace: demo
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: trustyai-service-operator-evalhub-mlflow-access
subjects:
- kind: ServiceAccount
  name: evalhub-service
  namespace: ${EVALHUB_NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: evalhub-central-jobs-writer
  namespace: demo
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: trustyai-service-operator-evalhub-jobs-writer
subjects:
- kind: ServiceAccount
  name: evalhub-service
  namespace: ${EVALHUB_NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: evalhub-central-job-config
  namespace: demo
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: trustyai-service-operator-evalhub-job-config
subjects:
- kind: ServiceAccount
  name: evalhub-service
  namespace: ${EVALHUB_NS}
EOF
    oc create sa "evalhub-${EVALHUB_NS}-job" -n demo 2>/dev/null || true
    oc adm policy add-role-to-user edit \
        "system:serviceaccount:demo:evalhub-${EVALHUB_NS}-job" -n demo 2>/dev/null || true

    if ! oc get rolebinding -n demo -o jsonpath='{.items[*].subjects[*].name}' 2>/dev/null \
        | tr ' ' '\n' | grep -x "evalhub"; then
        oc adm policy add-role-to-user edit \
            "system:serviceaccount:demo:evalhub" -n demo 2>/dev/null || true
        success "evalhub SA granted edit in demo"
    else
        success "evalhub SA already has edit in demo"
    fi

    if ! oc get role evalhub-secret-access -n demo &>/dev/null 2>&1; then
        oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: evalhub-secret-access
  namespace: demo
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: evalhub-secret-access
  namespace: demo
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: evalhub-secret-access
subjects:
- kind: ServiceAccount
  name: evalhub-service
  namespace: ${EVALHUB_NS}
EOF
        success "evalhub-service SA granted secret access in demo"
    else
        success "evalhub-service secret access already configured"
    fi

    if ! oc get configmap evalhub-service-ca -n demo &>/dev/null 2>&1; then
        if oc get configmap evalhub-service-ca -n "$EVALHUB_NS" &>/dev/null 2>&1; then
            CA_BUNDLE=$(oc get configmap evalhub-service-ca -n "$EVALHUB_NS" \
                -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null)
            if [ -n "$CA_BUNDLE" ]; then
                oc create configmap evalhub-service-ca -n demo \
                    --from-literal="service-ca.crt=$CA_BUNDLE" \
                    --dry-run=client -o yaml | oc apply -f -
            fi
            success "evalhub-service-ca ConfigMap copied to demo"
        else
            warn "evalhub-service-ca not found in $EVALHUB_NS"
        fi
    else
        success "evalhub-service-ca ConfigMap already in demo"
    fi
    success "EvalHub RBAC configured for demo namespace"
else
    warn "EvalHub CRD not available yet -- EvalHub will be created on next run"
fi
echo ""

###############################################################################
# Step 7: MaaS Gateway CRs
###############################################################################
info "=== Step 7/11: MaaS Gateway CRs ==="

CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
CERT_NAME=$(oc get secrets -n openshift-ingress --no-headers 2>/dev/null | \
  grep "cert-manager-ingress-cert\|router-certs-default" | awk '{print $1}' | head -1)
if [ -z "$CERT_NAME" ]; then
    warn "TLS cert not found -- using cert-manager-ingress-cert"
    CERT_NAME="cert-manager-ingress-cert"
fi
info "Domain: $CLUSTER_DOMAIN, TLS: $CERT_NAME"

oc apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: maas-gateway-class
spec:
  controllerName: openshift.io/gateway-controller/v1
EOF

if oc get gateway maas-default-gateway -n openshift-ingress &>/dev/null 2>&1; then
    success "maas-default-gateway already exists"
else
    oc apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: maas-default-gateway
  namespace: openshift-ingress
  labels:
    istio.io/rev: openshift-gateway
  annotations:
    opendatahub.io/managed: "false"
    security.opendatahub.io/authorino-tls-bootstrap: "true"
spec:
  gatewayClassName: maas-gateway-class
  listeners:
    - allowedRoutes:
        namespaces:
          from: All
      hostname: "maas.${CLUSTER_DOMAIN}"
      name: https
      port: 443
      protocol: HTTPS
      tls:
        certificateRefs:
          - group: ''
            kind: Secret
            name: ${CERT_NAME}
        mode: Terminate
EOF
    success "maas-default-gateway created"
fi
echo ""

###############################################################################
# Step 8: Dashboard menu + accelerator rules
###############################################################################
info "=== Step 8/11: Dashboard menu + accelerator rules ==="

WAIT=0
while ! oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications &>/dev/null; do
    [ $WAIT -ge 60 ] && { error "OdhDashboardConfig not found"; exit 1; }
    sleep 5; WAIT=$((WAIT + 5))
done

oc patch odhdashboardconfig odh-dashboard-config \
  -n redhat-ods-applications --type=merge -p '{
  "spec": {
    "dashboardConfig": {
      "disableModelRegistry": false,
      "disableModelCatalog": false,
      "disableKServeMetrics": false,
      "disableLMEval": false,
      "disableKueue": true,
      "disableTracking": false,
      "disablePerformanceMetrics": false,
      "disableDistributedWorkloads": false,
      "disableTrustyBiasMetrics": false,
      "genAiStudio": true,
      "modelAsService": true,
      "vLLMDeploymentOnMaaS": true,
      "observabilityDashboard": true,
      "mcpCatalog": true,
      "llmGatewayField": true,
      "deploymentWizardYAMLViewer": true,
      "aiAssetCustomEndpoints": true,
      "roleManagement": true,
      "gpuaas": true,
      "agentOps": true,
      "agentsCatalog": true,
      "agentConfigManagement": true,
      "automl": true,
      "autorag": true,
      "connectionTest": true,
      "externalModels": true,
      "externalVectorStores": true,
      "featureStoreAdmin": true,
      "genAiTracing": true,
      "globalProjectPrompts": true,
      "guardrails": true,
      "llmdTemplates": true,
      "mcpRegistry": true,
      "projectRBAC": true,
      "promptManagement": true,
      "toolCalling": true,
      "trainingJobs": false
    }
  }
}'
success "Dashboard menu patched"

# Accelerator metrics recording rules (cluster Prometheus)
if oc get prometheusrule nvidia-gpu-operator-metrics -n nvidia-gpu-operator &>/dev/null 2>&1; then
    info "Configuring accelerator metrics recording rules..."
    oc apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: accelerator-recording-rules
  namespace: nvidia-gpu-operator
  labels:
    app: nvidia-gpu-operator
spec:
  groups:
  - name: accelerator.rules
    interval: 30s
    rules:
    - record: accelerator_gpu_utilization
      expr: |
        label_replace(DCGM_FI_DEV_GPU_UTIL, "k8s_pod_name", "$1", "exported_pod", "(.*)")
    - record: accelerator_memory_used_bytes
      expr: |
        label_replace(DCGM_FI_DEV_FB_USED * 1024 * 1024, "k8s_pod_name", "$1", "exported_pod", "(.*)")
    - record: accelerator_memory_total_bytes
      expr: |
        label_replace((DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE) * 1024 * 1024, "k8s_pod_name", "$1", "exported_pod", "(.*)")
    - record: accelerator_power_usage_watts
      expr: |
        label_replace(DCGM_FI_DEV_POWER_USAGE, "k8s_pod_name", "$1", "exported_pod", "(.*)")
    - record: accelerator_temperature_celsius
      expr: |
        label_replace(DCGM_FI_DEV_GPU_TEMP, "k8s_pod_name", "$1", "exported_pod", "(.*)")
EOF
    success "Accelerator metrics recording rules created"
else
    info "GPU Operator PrometheusRule not found -- accelerator rules skipped"
fi

# DCGM metrics for RHOAI MonitoringStack Prometheus
if oc get prometheusrule nvidia-gpu-operator-metrics -n nvidia-gpu-operator &>/dev/null 2>&1; then
    if oc get namespace redhat-ods-monitoring &>/dev/null 2>&1; then
        info "Configuring DCGM metrics for RHOAI MonitoringStack..."
        oc apply -f - <<'DCGMEOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: nvidia-dcgm-exporter
  namespace: redhat-ods-monitoring
  labels:
    app: nvidia-dcgm-exporter
spec:
  endpoints:
  - path: /metrics
    port: gpu-metrics
  jobLabel: app
  namespaceSelector:
    matchNames:
    - nvidia-gpu-operator
  selector:
    matchLabels:
      app: nvidia-dcgm-exporter
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: accelerator-recording-rules
  namespace: redhat-ods-monitoring
  labels:
    app: nvidia-gpu-operator
spec:
  groups:
  - name: accelerator.rules
    interval: 30s
    rules:
    - record: accelerator_gpu_utilization
      expr: |
        label_replace(DCGM_FI_DEV_GPU_UTIL, "k8s_pod_name", "$1", "exported_pod", "(.*)")
    - record: accelerator_memory_used_bytes
      expr: |
        label_replace(DCGM_FI_DEV_FB_USED * 1024 * 1024, "k8s_pod_name", "$1", "exported_pod", "(.*)")
    - record: accelerator_memory_total_bytes
      expr: |
        label_replace((DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE) * 1024 * 1024, "k8s_pod_name", "$1", "exported_pod", "(.*)")
    - record: accelerator_power_usage_watts
      expr: |
        label_replace(DCGM_FI_DEV_POWER_USAGE, "k8s_pod_name", "$1", "exported_pod", "(.*)")
    - record: accelerator_temperature_celsius
      expr: |
        label_replace(DCGM_FI_DEV_GPU_TEMP, "k8s_pod_name", "$1", "exported_pod", "(.*)")
DCGMEOF
        success "DCGM ServiceMonitor + recording rules in redhat-ods-monitoring"
    fi
fi
echo ""

echo "================================================================"
success "Steps 1-8 complete ($(elapsed)). All configuration committed."
warn "Step 9 (RHCL) may briefly disrupt ingress/Web Terminal."
warn "If disconnected, re-run this script -- completed steps are skipped."
echo "================================================================"
echo ""

###############################################################################
# Step 9: Install RHCL + Kuadrant + Authorino TLS
###############################################################################
info "=== Step 9/11: RHCL + Kuadrant + Authorino TLS ==="

RHCL_NS="redhat-connectivity-link-operator"
KUADRANT_NS="kuadrant-system"

# RHCL Operator
if bash -c 'oc get subscription -A --no-headers 2>/dev/null | grep -q "rhcl-operator"'; then
    success "RHCL operator subscription exists"
else
    if [ "$SKIP_INSTALL" = true ]; then
        warn "Skipping RHCL install (--skip-install)"
    else
        info "Installing RHCL operator (this triggers Service Mesh 3)..."
        install_operator "RHCL (Connectivity Link)" "$RHCL_NS" "rhcl-operator" "stable" "all" "redhat-operators"
    fi
fi

if [ "$SKIP_INSTALL" != true ]; then
    wait_for 480 "RHCL operator Succeeded" \
        'oc get csv -n "'"$RHCL_NS"'" --no-headers 2>/dev/null | grep -q "rhcl-operator.*Succeeded"'
fi

# Kuadrant operator resources (OOMKill fix)
# RHCL 1.4.3 ships kuadrant-operator-controller-manager with a 300Mi memory
# limit. With ~30 workshop users creating MaaS subscriptions, the operator
# exceeds it, is OOMKilled in a loop, and new TokenRateLimitPolicies never
# get a status (MaaS subscriptions Degraded, auth policies Pending).
# Observed usage: ~530Mi at ~30 users x 1 model x 2 tiers.
#
# Set through the OLM Subscription (spec.config.resources); OLM reverts
# direct Deployment edits. Idempotent: the Subscription is patched only when
# its values differ from the targets below, so re-runs do not trigger an
# operator restart. A changed value makes OLM roll the operator pod
# (~3-5 min, policy reconciliation pauses), so the script waits for the
# rollout before creating the Kuadrant CR. Override via environment, e.g.
#   KUADRANT_MEM_LIMIT=8Gi bash sno-enable-all-features-35.sh
KUADRANT_CPU_REQUEST="${KUADRANT_CPU_REQUEST:-200m}"
KUADRANT_MEM_REQUEST="${KUADRANT_MEM_REQUEST:-1Gi}"
KUADRANT_CPU_LIMIT="${KUADRANT_CPU_LIMIT:-1}"
KUADRANT_MEM_LIMIT="${KUADRANT_MEM_LIMIT:-4Gi}"
KUADRANT_DEPLOY="kuadrant-operator-controller-manager"

RHCL_SUB_REF=$(oc get subscriptions.operators.coreos.com -A \
    -o jsonpath='{range .items[?(@.spec.name=="rhcl-operator")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
    2>/dev/null | head -1 || true)
if [ -n "$RHCL_SUB_REF" ]; then
    RHCL_SUB_NS="${RHCL_SUB_REF%% *}"
    RHCL_SUB_NAME="${RHCL_SUB_REF##* }"
    CUR_RES=$(oc get subscriptions.operators.coreos.com "$RHCL_SUB_NAME" -n "$RHCL_SUB_NS" \
        -o jsonpath='{.spec.config.resources.requests.cpu}|{.spec.config.resources.requests.memory}|{.spec.config.resources.limits.cpu}|{.spec.config.resources.limits.memory}' \
        2>/dev/null || true)
    WANT_RES="${KUADRANT_CPU_REQUEST}|${KUADRANT_MEM_REQUEST}|${KUADRANT_CPU_LIMIT}|${KUADRANT_MEM_LIMIT}"

    if [ "$CUR_RES" = "$WANT_RES" ]; then
        success "Kuadrant operator resources already set (mem ${KUADRANT_MEM_REQUEST}/${KUADRANT_MEM_LIMIT}, cpu ${KUADRANT_CPU_REQUEST}/${KUADRANT_CPU_LIMIT})"
    else
        info "Setting Kuadrant operator resources via Subscription ${RHCL_SUB_NS}/${RHCL_SUB_NAME} (current: ${CUR_RES:-default})..."
        if oc patch subscriptions.operators.coreos.com "$RHCL_SUB_NAME" -n "$RHCL_SUB_NS" --type=merge -p "{
          \"spec\": { \"config\": { \"resources\": {
            \"requests\": { \"cpu\": \"${KUADRANT_CPU_REQUEST}\", \"memory\": \"${KUADRANT_MEM_REQUEST}\" },
            \"limits\":   { \"cpu\": \"${KUADRANT_CPU_LIMIT}\",   \"memory\": \"${KUADRANT_MEM_LIMIT}\" }
          } } }
        }" >/dev/null 2>&1; then
            success "Kuadrant operator Subscription patched (mem ${KUADRANT_MEM_REQUEST}/${KUADRANT_MEM_LIMIT}, cpu ${KUADRANT_CPU_REQUEST}/${KUADRANT_CPU_LIMIT})"
            wait_for 360 "Kuadrant operator rolled out with ${KUADRANT_MEM_LIMIT} memory limit" \
                '[ "$(oc get deploy '"$KUADRANT_DEPLOY"' -n '"$RHCL_SUB_NS"' -o jsonpath="{.spec.template.spec.containers[0].resources.limits.memory}" 2>/dev/null)" = "'"$KUADRANT_MEM_LIMIT"'" ] && oc rollout status deploy/'"$KUADRANT_DEPLOY"' -n '"$RHCL_SUB_NS"' --timeout=5s' \
                || warn "Kuadrant operator rollout not finished yet -- OLM applies it in the background; verify in Step 11"
        else
            warn "Could not patch Kuadrant operator resources on ${RHCL_SUB_NS}/${RHCL_SUB_NAME}"
        fi
    fi
else
    warn "RHCL Subscription not found -- Kuadrant operator resources not set (re-run after RHCL installs)"
fi

# Kuadrant CR
if oc get crd kuadrants.kuadrant.io &>/dev/null 2>&1; then
    if oc get kuadrant kuadrant -n "$RHCL_NS" &>/dev/null 2>&1; then
        warn "Kuadrant CR in wrong namespace ($RHCL_NS) -- migrating to $KUADRANT_NS"
        oc delete kuadrant kuadrant -n "$RHCL_NS" --wait=false 2>/dev/null || true
        sleep 5
    fi

    if ! oc get kuadrant kuadrant -n "$KUADRANT_NS" &>/dev/null 2>&1; then
        info "Waiting for RHCL sub-operators (Authorino, Limitador)..."
        wait_for 120 "RHCL sub-operators" \
            'oc get csv -n "'"$RHCL_NS"'" --no-headers 2>/dev/null | grep -q "authorino-operator.*Succeeded" && oc get csv -n "'"$RHCL_NS"'" --no-headers 2>/dev/null | grep -q "limitador-operator.*Succeeded"'
    fi

    if oc get kuadrant kuadrant -n "$KUADRANT_NS" &>/dev/null 2>&1; then
        success "Kuadrant CR already exists in $KUADRANT_NS"
    else
        info "Creating Kuadrant CR in $KUADRANT_NS..."
        oc create namespace "$KUADRANT_NS" 2>/dev/null || true
        oc apply -f - <<EOF
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
  namespace: ${KUADRANT_NS}
spec: {}
EOF
    fi

    # Wait with recovery for MissingDependency
    info "Waiting for Kuadrant to become Ready..."
    WAIT=0; KREADY=""
    while [ $WAIT -lt 90 ]; do
        KREADY=$(oc get kuadrant kuadrant -n "$KUADRANT_NS" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
        [ "$KREADY" = "True" ] && break
        if [ $WAIT -eq 30 ] && [ "$KREADY" != "True" ]; then
            KREASON=$(oc get kuadrant kuadrant -n "$KUADRANT_NS" \
                -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || true)
            if [ "$KREASON" = "MissingDependency" ]; then
                warn "MissingDependency -- full recovery (delete CR -> kill pod -> recreate)..."
                oc delete kuadrant kuadrant -n "$KUADRANT_NS" --timeout=30s 2>/dev/null || true
                sleep 5
                KPOD=$(oc get pod -n "$RHCL_NS" --no-headers 2>/dev/null \
                    | grep kuadrant-operator-controller-manager | awk '{print $1}')
                [ -n "$KPOD" ] && oc delete pod "$KPOD" -n "$RHCL_NS" 2>/dev/null || true
                sleep 20
                oc apply -f - <<EOFRECOVERY
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
  namespace: ${KUADRANT_NS}
spec: {}
EOFRECOVERY
            fi
        fi
        sleep 5; WAIT=$((WAIT + 5))
    done
    [ "$KREADY" = "True" ] && success "Kuadrant CR Ready in $KUADRANT_NS" || \
        warn "Kuadrant not Ready yet -- MaaS setup script will handle it"

    # Authorino TLS
    AUTHORINO_TLS=$(oc get authorino authorino -n "$KUADRANT_NS" \
        -o jsonpath='{.spec.listener.tls.enabled}' 2>/dev/null || true)
    if [ "$AUTHORINO_TLS" = "true" ]; then
        success "Authorino TLS already enabled in $KUADRANT_NS"
    elif oc get authorino authorino -n "$KUADRANT_NS" &>/dev/null 2>&1; then
        info "Configuring Authorino TLS in $KUADRANT_NS..."
        oc annotate service authorino-authorino-authorization \
            -n "$KUADRANT_NS" \
            service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert \
            --overwrite 2>/dev/null || true
        wait_for 30 "Authorino server cert" \
            'oc get secret authorino-server-cert -n "'"$KUADRANT_NS"'" &>/dev/null 2>&1'
        oc patch authorino authorino -n "$KUADRANT_NS" --type=merge -p '{
          "spec": { "listener": { "tls": { "enabled": true, "certSecretRef": { "name": "authorino-server-cert" } } } }
        }' 2>/dev/null || true
        oc -n "$KUADRANT_NS" set env deployment/authorino \
            SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
            REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt 2>/dev/null || true
        success "Authorino TLS configured in $KUADRANT_NS"
    fi
else
    warn "Kuadrant CRD not ready yet -- will be created on next run"
fi

# RHCL Console Plugin
if oc get consoleplugin kuadrant-console-plugin &>/dev/null 2>&1; then
    if bash -c 'oc get pods -n "'"$RHCL_NS"'" --no-headers 2>/dev/null | grep -q "kuadrant-console-plugin.*Running"'; then
        ENABLED_PLUGINS=$(oc get console.operator.openshift.io cluster \
            -o jsonpath='{.spec.plugins}' 2>/dev/null || echo "[]")
        if echo "$ENABLED_PLUGINS" | grep -q "kuadrant-console-plugin"; then
            success "RHCL console plugin already enabled"
        else
            info "Enabling RHCL console plugin..."
            if oc patch console.operator.openshift.io cluster --type=json \
                -p '[{"op":"add","path":"/spec/plugins/-","value":"kuadrant-console-plugin"}]' 2>/dev/null; then
                success "RHCL console plugin enabled"
            else
                warn "Could not enable RHCL console plugin"
            fi
        fi
    else
        warn "kuadrant-console-plugin pod not running yet"
    fi
else
    warn "RHCL console plugin CR not found -- operator may still be installing"
fi
echo ""

###############################################################################
# Step 10: Dashboard restart
###############################################################################
info "=== Step 10/11: Dashboard restart ==="
oc rollout restart deployment/rhods-dashboard -n redhat-ods-applications 2>/dev/null || true
info "Restarting (1-2 min)..."
sleep 10
oc rollout status deployment/rhods-dashboard -n redhat-ods-applications --timeout=120s 2>/dev/null || \
    warn "Rollout timeout -- will complete shortly"
success "Dashboard restarted"
echo ""

###############################################################################
# Step 11: Verification
###############################################################################
info "=== Step 11/11: Verification ==="
NOT_READY_COUNT=0
NOT_READY_ITEMS=()

# DSC components
info "DSC components:"
for comp in MLflowOperatorReady OGXReady AIGatewayReady KserveReady TrustyAIReady AIPipelinesReady DashboardReady WorkbenchesReady ModelsAsAServiceReady ModelRegistryReady FeastOperatorReady; do
    STATUS=$(oc get datasciencecluster default-dsc -o jsonpath="{.status.conditions[?(@.type==\"${comp}\")].status}" 2>/dev/null)
    REASON=$(oc get datasciencecluster default-dsc -o jsonpath="{.status.conditions[?(@.type==\"${comp}\")].reason}" 2>/dev/null)
    if [ "$STATUS" = "True" ]; then
        echo -e "  ${GREEN}[OK]${NC} ${comp}"
    elif [ "$comp" = "ModelsAsAServiceReady" ]; then
        echo -e "  ${YELLOW}[--]${NC} ${comp} (expected -- becomes Ready after MaaS setup: sno-setup-maas-35.sh)"
    else
        echo -e "  ${RED}[!!]${NC} ${comp} (${REASON:-pending})"
        NOT_READY_COUNT=$((NOT_READY_COUNT + 1))
        NOT_READY_ITEMS+=("$comp")
    fi
done

echo ""
info "Operators (non-disruptive):"
for i in "${!OP_NAMES[@]}"; do
    if check_operator_installed "$i"; then
        echo -e "  ${GREEN}[OK]${NC} ${OP_NAMES[$i]}"
    else
        echo -e "  ${RED}[!!]${NC} ${OP_NAMES[$i]}"
        NOT_READY_COUNT=$((NOT_READY_COUNT + 1))
        NOT_READY_ITEMS+=("${OP_NAMES[$i]}")
    fi
done
# RHCL (separate check)
if bash -c 'oc get csv -n redhat-connectivity-link-operator --no-headers 2>/dev/null | grep -q "rhcl-operator.*Succeeded"'; then
    echo -e "  ${GREEN}[OK]${NC} RHCL (Connectivity Link)"
else
    if bash -c 'oc get subscription -A --no-headers 2>/dev/null | grep -q "rhcl-operator"'; then
        echo -e "  ${YELLOW}[..]${NC} RHCL (installing)"
    else
        echo -e "  ${RED}[!!]${NC} RHCL (not installed)"
    fi
    NOT_READY_COUNT=$((NOT_READY_COUNT + 1))
    NOT_READY_ITEMS+=("RHCL")
fi
# Web Terminal (separate check)
if bash -c 'oc get csv -n openshift-operators --no-headers 2>/dev/null | grep -q "^web-terminal\..*Succeeded"'; then
    echo -e "  ${GREEN}[OK]${NC} Web Terminal"
else
    if bash -c 'oc get subscriptions.operators.coreos.com -A --no-headers 2>/dev/null | awk '"'"'$3=="web-terminal"'"'"' | grep -q .'; then
        echo -e "  ${YELLOW}[..]${NC} Web Terminal (installing)"
    else
        echo -e "  ${RED}[!!]${NC} Web Terminal (not installed)"
    fi
    NOT_READY_COUNT=$((NOT_READY_COUNT + 1))
    NOT_READY_ITEMS+=("Web Terminal")
fi
KUADRANT_LIVE_LIMIT=$(oc get deploy kuadrant-operator-controller-manager -n redhat-connectivity-link-operator \
    -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null || true)
if [ -n "$KUADRANT_LIVE_LIMIT" ]; then
    if [ "$KUADRANT_LIVE_LIMIT" = "${KUADRANT_MEM_LIMIT:-4Gi}" ]; then
        echo -e "  ${GREEN}[OK]${NC} Kuadrant operator memory limit (${KUADRANT_LIVE_LIMIT})"
    else
        echo -e "  ${YELLOW}[..]${NC} Kuadrant operator memory limit (${KUADRANT_LIVE_LIMIT}, target ${KUADRANT_MEM_LIMIT:-4Gi}; OOMKill risk at default 300Mi)"
    fi
fi

echo ""
info "Observability:"
MON_STATUS=$(oc get dscinitialization default-dsci \
  -o jsonpath='{.status.conditions[?(@.type=="MonitoringStackAvailable")].status}' 2>/dev/null)
PERSES_STATUS=$(oc get dscinitialization default-dsci \
  -o jsonpath='{.status.conditions[?(@.type=="PersesAvailable")].status}' 2>/dev/null)
if [ "${MON_STATUS:-}" = "True" ]; then
    echo -e "  ${GREEN}[OK]${NC} MonitoringStack"
else
    echo -e "  ${RED}[!!]${NC} MonitoringStack"
    NOT_READY_COUNT=$((NOT_READY_COUNT + 1))
    NOT_READY_ITEMS+=("MonitoringStack")
fi
if [ "${PERSES_STATUS:-}" = "True" ]; then
    echo -e "  ${GREEN}[OK]${NC} Perses"
else
    echo -e "  ${RED}[!!]${NC} Perses"
    NOT_READY_COUNT=$((NOT_READY_COUNT + 1))
    NOT_READY_ITEMS+=("Perses")
fi

echo ""
info "Operator CRs:"
if oc get nodefeaturediscovery nfd-instance -n openshift-nfd &>/dev/null 2>&1; then
    echo -e "  ${GREEN}[OK]${NC} NodeFeatureDiscovery"
else
    echo -e "  ${RED}[!!]${NC} NodeFeatureDiscovery"
    NOT_READY_COUNT=$((NOT_READY_COUNT + 1))
    NOT_READY_ITEMS+=("NodeFeatureDiscovery")
fi
CP_STATE=$(oc get clusterpolicy gpu-cluster-policy -o jsonpath='{.status.state}' 2>/dev/null || true)
if [ "$CP_STATE" = "ready" ]; then
    echo -e "  ${GREEN}[OK]${NC} ClusterPolicy (ready)"
elif [ -n "$CP_STATE" ]; then
    echo -e "  ${YELLOW}[..]${NC} ClusterPolicy ($CP_STATE)"
else
    echo -e "  ${RED}[!!]${NC} ClusterPolicy (not found)"
    NOT_READY_COUNT=$((NOT_READY_COUNT + 1))
    NOT_READY_ITEMS+=("ClusterPolicy")
fi
if [ -n "$CP_STATE" ]; then
    if oc get servicemonitor nvidia-dcgm-exporter -n nvidia-gpu-operator &>/dev/null 2>&1; then
        echo -e "  ${GREEN}[OK]${NC} DCGM exporter ServiceMonitor (cluster Prometheus)"
    else
        echo -e "  ${YELLOW}[..]${NC} DCGM exporter ServiceMonitor (not created yet)"
    fi
fi
LWS_AVAILABLE=$(oc get leaderworkersetoperator cluster -n openshift-lws-operator \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
if [ "$LWS_AVAILABLE" = "True" ]; then
    echo -e "  ${GREEN}[OK]${NC} LeaderWorkerSetOperator CR"
else
    echo -e "  ${RED}[!!]${NC} LeaderWorkerSetOperator CR"
    NOT_READY_COUNT=$((NOT_READY_COUNT + 1))
    NOT_READY_ITEMS+=("LeaderWorkerSetOperator CR")
fi
KUADRANT_READY=$(oc get kuadrant kuadrant -n kuadrant-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
if [ "$KUADRANT_READY" = "True" ]; then
    echo -e "  ${GREEN}[OK]${NC} Kuadrant CR (Ready)"
else
    echo -e "  ${RED}[!!]${NC} Kuadrant CR (${KUADRANT_READY:-not found})"
    NOT_READY_COUNT=$((NOT_READY_COUNT + 1))
    NOT_READY_ITEMS+=("Kuadrant CR")
fi
AUTHORINO_TLS=$(oc get authorino authorino -n kuadrant-system \
    -o jsonpath='{.spec.listener.tls.enabled}' 2>/dev/null || true)
if [ "$AUTHORINO_TLS" = "true" ]; then
    echo -e "  ${GREEN}[OK]${NC} Authorino TLS (enabled)"
else
    echo -e "  ${RED}[!!]${NC} Authorino TLS"
    NOT_READY_COUNT=$((NOT_READY_COUNT + 1))
    NOT_READY_ITEMS+=("Authorino TLS")
fi

echo ""
info "Console Plugins:"
for PLUGIN_NAME in kuadrant-console-plugin console-dashboards-plugin monitoring-console-plugin; do
    ENABLED_PLUGINS=$(oc get console.operator.openshift.io cluster \
        -o jsonpath='{.spec.plugins}' 2>/dev/null || echo "[]")
    if echo "$ENABLED_PLUGINS" | grep -q "$PLUGIN_NAME"; then
        echo -e "  ${GREEN}[OK]${NC} ${PLUGIN_NAME}"
    else
        echo -e "  ${YELLOW}[..]${NC} ${PLUGIN_NAME} (not enabled)"
    fi
done

echo ""
info "Services:"
MLFLOW_READY=$(oc get mlflow mlflow -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
if [ "$MLFLOW_READY" = "True" ]; then
    echo -e "  ${GREEN}[OK]${NC} MLflow server"
else
    echo -e "  ${RED}[!!]${NC} MLflow server"
    NOT_READY_COUNT=$((NOT_READY_COUNT + 1))
    NOT_READY_ITEMS+=("MLflow server")
fi
EVALHUB_PHASE=$(oc get evalhub evalhub -n redhat-ods-applications -o jsonpath='{.status.phase}' 2>/dev/null || true)
if [ "$EVALHUB_PHASE" = "Ready" ]; then
    echo -e "  ${GREEN}[OK]${NC} EvalHub"
else
    echo -e "  ${RED}[!!]${NC} EvalHub (${EVALHUB_PHASE:-not deployed})"
    NOT_READY_COUNT=$((NOT_READY_COUNT + 1))
    NOT_READY_ITEMS+=("EvalHub")
fi
if oc get networkpolicy evalhub-allow-tenant-jobs -n redhat-ods-applications &>/dev/null; then
    echo -e "  ${GREEN}[OK]${NC} EvalHub tenant NetworkPolicy"
else
    echo -e "  ${RED}[!!]${NC} EvalHub tenant NetworkPolicy (evalhub-allow-tenant-jobs)"
    NOT_READY_COUNT=$((NOT_READY_COUNT + 1))
    NOT_READY_ITEMS+=("EvalHub tenant NetworkPolicy")
fi
DS_PHASE=$(oc get checluster devspaces -n openshift-devspaces \
    -o jsonpath='{.status.chePhase}' 2>/dev/null || true)
if [ "$DS_PHASE" = "Active" ]; then
    echo -e "  ${GREEN}[OK]${NC} CheCluster (Active)"
else
    echo -e "  ${YELLOW}[..]${NC} CheCluster (${DS_PHASE:-not found})"
fi

echo ""
info "Gateway:"
oc get gateway -n openshift-ingress --no-headers 2>/dev/null | while read name class addr rest; do
    echo "  $name -> $addr"
done

echo ""
info "Dashboard URL:"
echo "  https://$(oc get route data-science-gateway -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || echo '(check manually)')"

# Total elapsed time
SCRIPT_END=$(date +%s)
TOTAL_SEC=$((SCRIPT_END - SCRIPT_START))
TOTAL_MIN=$((TOTAL_SEC / 60))
TOTAL_REMAINDER=$((TOTAL_SEC % 60))

echo ""
echo "=============================================="
if [ $NOT_READY_COUNT -eq 0 ]; then
    success "All checks passed. Total time: ${TOTAL_MIN}m${TOTAL_REMAINDER}s"
else
    warn "${NOT_READY_COUNT} item(s) NOT READY. Total time: ${TOTAL_MIN}m${TOTAL_REMAINDER}s"
    for item in "${NOT_READY_ITEMS[@]}"; do
        echo -e "  ${RED}[!!]${NC} ${item}"
    done
    echo "  Re-run this script to pick up where it left off."
fi
echo ""
echo "  Next steps:"
echo "  - MaaS setup: bash scripts/sno-setup-maas-35.sh"
echo ""
echo "  - Workshop prep: see scripts/workshop-prep/"
echo "    create_workshop_users.sh      (htpasswd users + RBAC)"
echo "    gpu_machineset_hardwareprofiles.sh (MachineSet + HardwareProfile)"
echo ""
echo "  - DevSpaces: oc get checluster devspaces -n openshift-devspaces -o jsonpath='{.status.cheURL}'"
echo "=============================================="
