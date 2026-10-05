#!/bin/bash
###############################################################################
# sno-enable-all-features.sh
#
# Enable all RHOAI 3.5 DSC components + dashboard features on an SNO cluster.
#
# Execution order is optimized for Web Terminal reliability:
#   Steps 1-5  — Core configuration (safe, no network disruption)
#   Step 5b    — Accelerator recording rules (GPU Operator prerequisite only)
#   Step 6     — Operator install (may briefly disrupt Web Terminal)
#   Step 7     — Post-operator setup (DSCI monitoring, UIPlugins, CRs)
#   Step 8     — Dashboard restart (picks up everything)
#   Step 9     — Verification (best effort)
#
# Steps 1-5b complete before any network disruption caused by RHCL/Service
# Mesh installation. If the terminal disconnects during Step 6, operators
# continue installing via OLM in the background. Re-run the script to
# pick up where it left off — all steps are idempotent.
#
# Usage:
#   bash sno-enable-all-features.sh                 # Full run (recommended)
#   bash sno-enable-all-features.sh --skip-install   # Skip operator install
#
# Tip: In Web Terminal, run with nohup to survive disconnections:
#   nohup bash sno-enable-all-features.sh > /tmp/sno.log 2>&1 &
#   # Reconnect later:  tail -f /tmp/sno.log
#
# Prerequisites:
#   - oc login completed
#   - RHOAI 3.5.x Operator installed
#   - DataScienceCluster 'default-dsc' exists
###############################################################################
set -euo pipefail

SKIP_INSTALL=false
[[ "${1:-}" == "--skip-install" || "${1:-}" == "--skip" ]] && SKIP_INSTALL=true

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }

# Operator definitions (used in Steps 6 and 7)
# Kueue, cert-manager, LWS are installed first (no network disruption).
# RHCL is installed last (triggers Service Mesh → may disrupt Web Terminal).
declare -a OP_NAMES=( "Kueue"              "cert-manager"                    "LWS (LeaderWorkerSet)"       "OpenTelemetry"                    "Tempo"                    "COO (Cluster Observability)"                      "RHCL (Red Hat Connectivity Link)" )
declare -a OP_NS=(    "openshift-operators" "cert-manager-operator"           "openshift-lws-operator"      "openshift-opentelemetry-operator" "openshift-tempo-operator" "openshift-cluster-observability-operator"          "redhat-connectivity-link-operator" )
declare -a OP_GREP=(  "kueue"              "cert-manager"                    "leader-worker-set"           "opentelemetry"                    "tempo"                    "cluster-observability-operator"                    "rhcl-operator" )
declare -a OP_SUB=(   "kueue-operator"     "openshift-cert-manager-operator" "leader-worker-set"           "opentelemetry-product"            "tempo-product"            "cluster-observability-operator"                    "rhcl-operator" )
declare -a OP_CH=(    "stable-v1.3"        "stable-v1"                       "stable-v1.0"                 "stable"                           "stable"                   "stable"                                            "auto" )
declare -a OP_MODE=(  "skip"               "own"                             "own"                         "all"                              "all"                      "all"                                               "all" )
declare -a OP_USE=(   "Workbenches / DW"   "KServe / Model Serving"          "llm-d distributed inference" "Metrics & trace collection"       "Distributed trace store"  "Observe & Monitor dashboard (Perses)"              "MaaS / AIGateway" )

echo "=============================================="
echo " RHOAI 3.5 SNO — Enable All Features"
echo "=============================================="
echo ""
info "Order: Config (1-5b) → Operators (6) → Post-op (7) → Restart (8) → Verify (9) → GPU (10-11)"
info "Steps 1-5b complete before any network disruption."
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

    # Auto-detect channel from packagemanifest when set to "auto"
    if [ "$CHANNEL" = "auto" ]; then
        CHANNEL=$(oc get packagemanifest "$SUB_NAME" -o jsonpath='{.status.defaultChannel}' 2>/dev/null)
        [ -z "$CHANNEL" ] && CHANNEL="stable"
        info "Auto-detected channel: ${CHANNEL} for ${SUB_NAME}"
    fi

    info "Installing ${DISPLAY_NAME} (ns=${NAMESPACE}, ch=${CHANNEL}, mode=${MODE})..."

    if [ "$MODE" = "skip" ]; then
        # openshift-operators: already has Namespace + OperatorGroup
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
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
    elif [ "$MODE" = "all" ]; then
        # AllNamespaces mode: OperatorGroup WITHOUT targetNamespaces (e.g. RHCL)
        oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${SUB_NAME}-group
  namespace: ${NAMESPACE}
spec:
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${SUB_NAME}
  namespace: ${NAMESPACE}
spec:
  channel: ${CHANNEL}
  installPlanApproval: Automatic
  name: ${SUB_NAME}
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
    else
        # OwnNamespace mode: OperatorGroup WITH targetNamespaces (e.g. LWS, cert-manager)
        oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${SUB_NAME}-group
  namespace: ${NAMESPACE}
spec:
  targetNamespaces:
  - ${NAMESPACE}
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${SUB_NAME}
  namespace: ${NAMESPACE}
spec:
  channel: ${CHANNEL}
  installPlanApproval: Automatic
  name: ${SUB_NAME}
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
    fi
}

###############################################################################
# Helper: check if an operator is installed
###############################################################################
check_operator_installed() {
    local idx="$1"
    if [ "${OP_SUB[$idx]}" = "rhcl-operator" ]; then
        oc get subscription -A --no-headers 2>/dev/null | grep -q "rhcl-operator"
    else
        oc get csv -n "${OP_NS[$idx]}" --no-headers 2>/dev/null | grep -q "${OP_GREP[$idx]}.*Succeeded"
    fi
}

###############################################################################
# Phase 1: Required prerequisites (abort if missing)
###############################################################################
info "=== Prerequisites ==="

if ! oc whoami &>/dev/null; then
    error "oc login required"
    exit 1
fi
success "Logged in: $(oc whoami) @ $(oc whoami --show-server)"

RHOAI_CSV=$(oc get csv -n redhat-ods-operator --no-headers 2>/dev/null | grep rhods | awk '{print $1}')
if [ -z "$RHOAI_CSV" ]; then
    error "RHOAI Operator not installed"
    echo "  → Install 'Red Hat OpenShift AI' from OperatorHub first"
    exit 1
fi
success "RHOAI: $(echo "$RHOAI_CSV" | sed 's/rhods-operator\.//')"

if ! oc get datasciencecluster default-dsc &>/dev/null; then
    error "DataScienceCluster 'default-dsc' not found"
    exit 1
fi
success "DSC: default-dsc"
echo ""

###############################################################################
# Step 1/9: User Workload Monitoring
#   Prerequisite for Observe & Monitor.  DSCI monitoring (metrics/traces)
#   is configured later in Step 7 after COO + Tempo are installed.
###############################################################################
info "=== Step 1/9: User Workload Monitoring ==="

if oc get configmap cluster-monitoring-config -n openshift-monitoring &>/dev/null 2>&1; then
    EXISTING=$(oc get configmap cluster-monitoring-config -n openshift-monitoring \
      -o jsonpath='{.data.config\.yaml}' 2>/dev/null)
    if echo "$EXISTING" | grep -q "enableUserWorkload: true"; then
        success "User Workload Monitoring already enabled ✓"
    else
        warn "cluster-monitoring-config exists but enableUserWorkload not set — patching"
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

# Brief wait for monitoring pods
WAIT=0
while [ "$(oc get pods -n openshift-user-workload-monitoring --no-headers 2>/dev/null | grep -c Running)" -lt 2 ]; do
    [ $WAIT -ge 60 ] && { warn "Monitoring pods wait timeout (continuing)"; break; }
    sleep 5; WAIT=$((WAIT + 5))
done
echo ""

###############################################################################
# Step 2/9: DSC component activation
###############################################################################
info "=== Step 2/9: DSC component activation ==="

oc patch datasciencecluster default-dsc --type=merge -p '{
  "spec": {
    "components": {
      "mlflowoperator": {
        "managementState": "Managed"
      },
      "llamastackoperator": {
        "managementState": "Removed"
      },
      "ogx": {
        "managementState": "Managed"
      },
      "aigateway": {
        "managementState": "Managed",
        "modelsAsAService": {
          "managementState": "Managed"
        }
      }
    }
  }
}' 2>&1

success "DSC patched"

# Wait for OGX CRD
info "Waiting for OGX provisioning..."
WAIT=0
while ! oc get crd ogxservers.ogx.io &>/dev/null 2>&1; do
    [ $WAIT -ge 90 ] && { warn "OGX CRD wait timeout (continuing)"; break; }
    sleep 5; WAIT=$((WAIT + 5))
done
oc get crd ogxservers.ogx.io &>/dev/null 2>&1 && success "OGX CRD registered ✓"
echo ""

###############################################################################
# Step 3/8: MLflow server + demo project
#   Creates the demo Data Science Project and a cluster-scoped MLflow CR.
#   The MLflow operator (enabled in Step 2) creates HTTPRoute + tracking UI.
#
#   Idempotency scenarios handled:
#   - PostgreSQL in CrashLoopBackOff → recovers with fresh PVC
#   - mlflow-db-credentials secret missing → (re)created every run
#   - MLflow CR exists but migration stuck → deletes stuck job for retry
#   - MLflow CR exists and healthy → skips
#   - No PostgreSQL at all → falls back to SQLite
#
#   Note: Uses the existing 'maas' database for MLflow (the maas user does
#   not have CREATEDB privilege). MLflow creates its own tables within it.
###############################################################################
info "=== Step 3/9: MLflow server + demo project ==="

MLFLOW_NS="redhat-ods-applications"

# Ensure demo namespace exists as a Data Science Project
if oc get ns demo &>/dev/null 2>&1; then
    success "Namespace 'demo' exists ✓"
else
    info "Creating namespace 'demo'..."
    oc create namespace demo 2>/dev/null || true
fi
# Label as Data Science Project (idempotent)
oc label namespace demo opendatahub.io/dashboard=true --overwrite 2>/dev/null || true
success "demo labeled as Data Science Project"

# Wait for MLflow CRD (registered after mlflowoperator becomes Managed)
info "Waiting for MLflow CRD..."
WAIT=0
while ! oc get crd mlflows.mlflow.opendatahub.io &>/dev/null 2>&1; do
    [ $WAIT -ge 120 ] && { warn "MLflow CRD not ready yet (continuing)"; break; }
    sleep 5; WAIT=$((WAIT + 5))
done

if oc get crd mlflows.mlflow.opendatahub.io &>/dev/null 2>&1; then
    success "MLflow CRD registered ✓"

    MLFLOW_BACKEND="sqlite"

    # --- PostgreSQL health check + mlflow-db-credentials secret ---
    # This block runs every time (not just on first MLflow CR creation)
    # to recover from missing secrets or PostgreSQL CrashLoopBackOff.
    if oc get deployment postgres -n "$MLFLOW_NS" &>/dev/null 2>&1; then

        # Check if PostgreSQL pod is healthy
        PG_READY=$(oc get pods -n "$MLFLOW_NS" -l app=postgres \
            -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || true)

        if [ "$PG_READY" != "true" ]; then
            # Check for CrashLoopBackOff (common: set_passwords.sh race condition)
            PG_WAITING=$(oc get pods -n "$MLFLOW_NS" -l app=postgres \
                -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)
            if [ "$PG_WAITING" = "CrashLoopBackOff" ]; then
                warn "PostgreSQL in CrashLoopBackOff — recovering with fresh PVC..."
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

            info "Waiting for PostgreSQL to become ready (up to 60s)..."
            WAIT=0
            while [ $WAIT -lt 60 ]; do
                PG_READY=$(oc get pods -n "$MLFLOW_NS" -l app=postgres \
                    -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || true)
                [ "$PG_READY" = "true" ] && break
                sleep 5; WAIT=$((WAIT + 5))
            done
        fi

        if [ "$PG_READY" = "true" ]; then
            success "PostgreSQL running ✓"
            MLFLOW_BACKEND="postgres"

            # Build DB URL using the 'maas' database (maas user cannot CREATE DATABASE)
            PG_FQDN="postgres.${MLFLOW_NS}.svc.cluster.local"
            PG_PASSWORD_ACTUAL=$(oc get deployment postgres -n "$MLFLOW_NS" \
                -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="POSTGRESQL_PASSWORD")].value}' 2>/dev/null)
            PG_USER=$(oc get deployment postgres -n "$MLFLOW_NS" \
                -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="POSTGRESQL_USER")].value}' 2>/dev/null)
            # URL-encode password (pure bash — no python3 in Web Terminal)
            ENCODED_PW=""
            for (( _i=0; _i<${#PG_PASSWORD_ACTUAL}; _i++ )); do
                _c="${PG_PASSWORD_ACTUAL:$_i:1}"
                case "$_c" in
                    [a-zA-Z0-9.~_-]) ENCODED_PW+="$_c" ;;
                    *) ENCODED_PW+=$(printf '%%%02X' "'$_c") ;;
                esac
            done
            MLFLOW_DB_URL="postgresql://${PG_USER}:${ENCODED_PW}@${PG_FQDN}:5432/maas?sslmode=disable"

            # Ensure mlflow-db-credentials secret exists (idempotent)
            if oc get secret mlflow-db-credentials -n "$MLFLOW_NS" &>/dev/null; then
                success "mlflow-db-credentials secret ✓"
            else
                oc create secret generic mlflow-db-credentials \
                    --from-literal=database-url="$MLFLOW_DB_URL" \
                    -n "$MLFLOW_NS" --dry-run=client -o yaml | oc apply -f - 2>/dev/null
                success "mlflow-db-credentials secret created"
            fi
        else
            warn "PostgreSQL not ready after 60s — falling back to SQLite for MLflow"
        fi
    fi

    # --- MLflow CR: create or recover ---
    if oc get mlflow mlflow &>/dev/null 2>&1; then
        MLFLOW_AVAILABLE=$(oc get mlflow mlflow \
            -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)

        if [ "$MLFLOW_AVAILABLE" = "True" ]; then
            success "MLflow server running ✓"
        else
            # Detect stuck migration job (CreateContainerConfigError / Error)
            STUCK_POD=$(oc get pods -n "$MLFLOW_NS" --no-headers 2>/dev/null \
                | grep -E "mlflow-mg.*(CreateContainerConfigError|Error|ImagePullBackOff)" \
                | awk '{print $1}' | head -1)
            if [ -n "$STUCK_POD" ]; then
                # Extract job name from pod name (strip trailing pod hash)
                JOB_NAME=$(echo "$STUCK_POD" | rev | cut -d'-' -f2- | rev)
                warn "Stuck migration job detected ($JOB_NAME) — deleting for retry..."
                oc delete job "$JOB_NAME" -n "$MLFLOW_NS" 2>/dev/null || true
                info "Waiting for MLflow to reconcile (up to 120s)..."
                WAIT=0
                while [ $WAIT -lt 120 ]; do
                    MLFLOW_AVAILABLE=$(oc get mlflow mlflow \
                        -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
                    [ "$MLFLOW_AVAILABLE" = "True" ] && break
                    sleep 10; WAIT=$((WAIT + 10))
                done
                [ "$MLFLOW_AVAILABLE" = "True" ] && success "MLflow server recovered ✓" || \
                    warn "MLflow not ready yet (will reconcile in background)"
            else
                warn "MLflow exists but not Available — will reconcile in background"
            fi
        fi
    else
        # First-time MLflow CR creation
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
            info "No PostgreSQL available — using SQLite with PVC..."
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

        # Wait for MLflow to become available
        info "Waiting for MLflow server..."
        WAIT=0
        while [ $WAIT -lt 120 ]; do
            MLFLOW_READY=$(oc get mlflow mlflow \
                -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
            [ "$MLFLOW_READY" = "True" ] && { success "MLflow server ready ✓"; break; }
            sleep 10; WAIT=$((WAIT + 10))
        done
        [ "${MLFLOW_READY:-}" != "True" ] && warn "MLflow not ready yet (will reconcile in background)"
    fi
else
    warn "MLflow CRD not available — MLflow will be created on next run"
fi
echo ""

# --- EvalHub (TrustyAI Operator CR) ---
# EvalHub is deployed centrally in redhat-ods-applications.
# RBAC grants are created per project namespace (demo).
EVALHUB_NS="redhat-ods-applications"

if oc get crd evalhubs.trustyai.opendatahub.io &>/dev/null 2>&1; then
    success "EvalHub CRD registered ✓"

    if oc get evalhub evalhub -n "$EVALHUB_NS" &>/dev/null 2>&1; then
        success "EvalHub already exists in $EVALHUB_NS ✓"
    else
        # SQLite is sufficient for demo SNO — no DB secrets or RBAC to PostgreSQL needed.
        # PostgreSQL is deployed later by sno-setup-maas-35.sh, so it won't exist here anyway.
        info "Creating EvalHub (SQLite backend — lightweight for demo)..."
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
        success "EvalHub created (SQLite backend)"

        # Wait for EvalHub
        info "Waiting for EvalHub..."
        WAIT=0
        while [ $WAIT -lt 120 ]; do
            EVALHUB_PHASE=$(oc get evalhub evalhub -n "$EVALHUB_NS" \
                -o jsonpath='{.status.phase}' 2>/dev/null || true)
            [ "$EVALHUB_PHASE" = "Ready" ] && { success "EvalHub ready ✓"; break; }
            sleep 10; WAIT=$((WAIT + 10))
        done
        [ "${EVALHUB_PHASE:-}" != "Ready" ] && warn "EvalHub not ready yet (will reconcile in background)"
    fi

    # Ensure MLFLOW_TRACKING_URI is set in EvalHub CR spec.env
    # (eval job pods inherit env from the CR; without this, MLflow logging fails server-side)
    MLFLOW_URI="https://mlflow.${EVALHUB_NS}.svc:8443/mlflow"
    CURRENT_URI=$(oc get evalhub evalhub -n "$EVALHUB_NS" \
        -o jsonpath='{.spec.env[?(@.name=="MLFLOW_TRACKING_URI")].value}' 2>/dev/null || true)
    if [ "$CURRENT_URI" = "$MLFLOW_URI" ]; then
        success "EvalHub MLFLOW_TRACKING_URI already set ✓"
    else
        info "Patching EvalHub with MLFLOW_TRACKING_URI..."
        oc patch evalhub evalhub -n "$EVALHUB_NS" --type=merge -p "
spec:
  env:
  - name: MLFLOW_TRACKING_URI
    value: ${MLFLOW_URI}
"
        success "EvalHub MLFLOW_TRACKING_URI set to ${MLFLOW_URI}"
    fi

    # RBAC: grant EvalHub access to demo project
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

    # Create eval job ServiceAccount for demo namespace
    oc create sa "evalhub-${EVALHUB_NS}-job" -n demo 2>/dev/null || true
    oc adm policy add-role-to-user edit \
        "system:serviceaccount:demo:evalhub-${EVALHUB_NS}-job" -n demo 2>/dev/null || true

    # Grant edit to the evalhub SA in demo (needed for adapter image builds:
    # ImageStreams, BuildConfigs created during benchmark adapter builds)
    if ! oc get rolebinding -n demo -o jsonpath='{.items[*].subjects[*].name}' 2>/dev/null \
        | tr ' ' '\n' | grep -qx "evalhub"; then
        oc adm policy add-role-to-user edit \
            "system:serviceaccount:demo:evalhub" -n demo 2>/dev/null || true
        success "evalhub SA granted edit in demo"
    else
        success "evalhub SA already has edit in demo ✓"
    fi

    # Grant evalhub-service SA secret CRUD in demo (the sidecar running as
    # evalhub-service from redhat-ods-applications needs to read/create secrets
    # like model-api-key in the target namespace)
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
        success "evalhub-service secret access already configured ✓"
    fi

    # Copy evalhub-service-ca ConfigMap to demo namespace (eval job pods mount
    # this volume for TLS trust back to the EvalHub API)
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
            warn "evalhub-service-ca ConfigMap not found in $EVALHUB_NS — eval jobs may fail to mount TLS volume"
        fi
    else
        success "evalhub-service-ca ConfigMap already in demo ✓"
    fi

    success "EvalHub RBAC configured for demo namespace"
else
    warn "EvalHub CRD not available yet — EvalHub will be created on next run"
fi
echo ""

###############################################################################
# Step 4/8: MaaS Gateway
#   Creates GatewayClass + Gateway CRs. These are just API objects — they
#   don't require RHCL to be running yet. The gateway controller will
#   reconcile them once RHCL/Service Mesh is ready.
###############################################################################
info "=== Step 4/9: MaaS Gateway ==="

CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')

CERT_NAME=$(oc get secrets -n openshift-ingress --no-headers 2>/dev/null | \
  grep "cert-manager-ingress-cert\|router-certs-default" | awk '{print $1}' | head -1)
if [ -z "$CERT_NAME" ]; then
    warn "TLS cert not found — using cert-manager-ingress-cert"
    CERT_NAME="cert-manager-ingress-cert"
fi
info "Domain: $CLUSTER_DOMAIN, TLS: $CERT_NAME"

# GatewayClass (idempotent)
oc apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: maas-gateway-class
spec:
  controllerName: openshift.io/gateway-controller/v1
EOF

# Gateway
if oc get gateway maas-default-gateway -n openshift-ingress &>/dev/null 2>&1; then
    success "maas-default-gateway already exists ✓"
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
# Step 5/8: Dashboard menu activation
###############################################################################
info "=== Step 5/9: Dashboard menu activation ==="

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
      "disableKueue": false,
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
      "trainingJobs": true
    }
  }
}'

success "Dashboard menu patched"
echo ""

###############################################################################
# Step 5b: Accelerator metrics recording rules
#   GPU Operator is a prerequisite (already installed). This step creates
#   PrometheusRules that convert DCGM_FI_* metrics into accelerator_*
#   format expected by RHOAI Observe & Monitor dashboards.
#   Without these, GPU utilization panels show "No data".
#   Safe to run here — no dependency on Step 6 operators.
###############################################################################
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
        label_replace(
          DCGM_FI_DEV_GPU_UTIL,
          "k8s_pod_name", "$1", "exported_pod", "(.*)"
        )
    - record: accelerator_memory_used_bytes
      expr: |
        label_replace(
          DCGM_FI_DEV_FB_USED * 1024 * 1024,
          "k8s_pod_name", "$1", "exported_pod", "(.*)"
        )
    - record: accelerator_memory_total_bytes
      expr: |
        label_replace(
          (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE) * 1024 * 1024,
          "k8s_pod_name", "$1", "exported_pod", "(.*)"
        )
    - record: accelerator_memory_clock_hertz
      expr: |
        label_replace(
          DCGM_FI_DEV_MEM_CLOCK * 1e6,
          "k8s_pod_name", "$1", "exported_pod", "(.*)"
        )
    - record: accelerator_sm_clock_hertz
      expr: |
        label_replace(
          DCGM_FI_DEV_SM_CLOCK * 1e6,
          "k8s_pod_name", "$1", "exported_pod", "(.*)"
        )
    - record: accelerator_power_usage_watts
      expr: |
        label_replace(
          DCGM_FI_DEV_POWER_USAGE,
          "k8s_pod_name", "$1", "exported_pod", "(.*)"
        )
    - record: accelerator_temperature_celsius
      expr: |
        label_replace(
          DCGM_FI_DEV_GPU_TEMP,
          "k8s_pod_name", "$1", "exported_pod", "(.*)"
        )
EOF
    success "Accelerator metrics recording rules created"
else
    info "GPU Operator not installed — accelerator recording rules skipped"
fi
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
success "Core configuration complete (Steps 1-5b)."
info "Next: operator install (Step 6) may briefly disrupt Web Terminal."
info "If disconnected, re-run this script — completed steps are skipped."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

###############################################################################
# Step 6/9: Operator scan & install
#   RHCL installation triggers Service Mesh 3, which may briefly disrupt
#   the OpenShift ingress layer and Web Terminal connections.
#   Even if the terminal disconnects, OLM continues the installation.
###############################################################################
info "=== Step 6/9: Operator scan & install ==="

declare -a MISSING_NAMES=()
declare -a MISSING_NS=()
declare -a MISSING_GREP=()
declare -a MISSING_IDX=()

for i in "${!OP_NAMES[@]}"; do
    if check_operator_installed "$i"; then
        success "${OP_NAMES[$i]} ✓"
    else
        warn "${OP_NAMES[$i]} — not installed  (needed for: ${OP_USE[$i]})"
        MISSING_NAMES+=("${OP_NAMES[$i]}")
        MISSING_NS+=("${OP_NS[$i]}")
        MISSING_GREP+=("${OP_GREP[$i]}")
        MISSING_IDX+=("$i")
    fi
done

echo ""

if [ ${#MISSING_NAMES[@]} -gt 0 ]; then
    echo -e "${BOLD}┌─────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}│  ${#MISSING_NAMES[@]} operator(s) not installed                          │${NC}"
    echo -e "${BOLD}├─────────────────────────────────────────────────────────┤${NC}"
    for j in "${!MISSING_NAMES[@]}"; do
        printf "${BOLD}│${NC}  %-3s %-30s → %s\n" "$((j+1))." "${MISSING_NAMES[$j]}" "${OP_USE[${MISSING_IDX[$j]}]}"
    done
    echo -e "${BOLD}└─────────────────────────────────────────────────────────┘${NC}"

    if [ "$SKIP_INSTALL" = true ]; then
        warn "Skipping operator install (--skip-install)"
        warn "Some features may not work without these operators"
        echo -e "  Install manually: Console → Operators → OperatorHub"
        CONSOLE_URL=$(oc whoami --show-console 2>/dev/null || echo "")
        [ -n "$CONSOLE_URL" ] && echo -e "  ${CYAN}${CONSOLE_URL}/operatorhub${NC}"
        echo ""
    else
        info "Auto-installing missing operators..."
        info "RHCL triggers Service Mesh — Web Terminal may briefly disconnect."
        echo ""
        for j in "${!MISSING_IDX[@]}"; do
            idx=${MISSING_IDX[$j]}
            install_operator "${OP_NAMES[$idx]}" "${OP_NS[$idx]}" "${OP_SUB[$idx]}" "${OP_CH[$idx]}" "${OP_MODE[$idx]}"
        done
        echo ""

        # Wait for operators (best effort — OLM handles it regardless)
        info "Waiting for operators (up to 4min)..."
        TIMEOUT=240; WAIT=0
        while [ $WAIT -lt "$TIMEOUT" ]; do
            ALL_READY=true
            for i in "${!MISSING_NS[@]}"; do
                if ! oc get csv -n "${MISSING_NS[$i]}" 2>/dev/null | grep -q "${MISSING_GREP[$i]}.*Succeeded"; then
                    ALL_READY=false
                fi
            done
            $ALL_READY && break
            sleep 10; WAIT=$((WAIT + 10))
        done
        for i in "${!MISSING_NAMES[@]}"; do
            if oc get csv -n "${MISSING_NS[$i]}" 2>/dev/null | grep -q "${MISSING_GREP[$i]}.*Succeeded"; then
                success "${MISSING_NAMES[$i]} ✓"
            else
                warn "${MISSING_NAMES[$i]} — still installing (continues in background)"
            fi
        done
    fi
else
    success "All additional operators installed ✓"
fi

# LWS operator CR (requires LWS operator)
if oc get crd leaderworkersetoperators.operator.openshift.io &>/dev/null 2>&1; then
    if ! oc get leaderworkersetoperator cluster -n openshift-lws-operator &>/dev/null 2>&1; then
        info "Creating LeaderWorkerSet operator CR..."
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
    else
        success "LeaderWorkerSetOperator CR already exists ✓"
    fi
else
    warn "LWS CRD not ready yet — LeaderWorkerSetOperator CR will be created on next run"
fi

# Kueue Resource Queues (requires Kueue operator)
# Creates ResourceFlavors, ClusterQueue, and LocalQueue to enable hardware
# profile selection and workload scheduling for workbenches / model serving.
# Without these, the dashboard shows "No enabled or valid hardware profiles".
if oc get crd clusterqueues.kueue.x-k8s.io &>/dev/null 2>&1; then
    info "Configuring Kueue resource queues..."

    # ResourceFlavor: default (CPU workloads — schedules on any untainted node)
    if oc get resourceflavor default-flavor &>/dev/null 2>&1; then
        success "ResourceFlavor default-flavor ✓"
    else
        oc apply -f - <<'EOF'
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata:
  name: default-flavor
spec: {}
EOF
        success "ResourceFlavor default-flavor created"
    fi

    # ResourceFlavor: gpu (GPU workloads — nodes with nvidia.com/gpu, tolerates taint)
    if oc get resourceflavor gpu-flavor &>/dev/null 2>&1; then
        success "ResourceFlavor gpu-flavor ✓"
    else
        oc apply -f - <<'EOF'
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata:
  name: gpu-flavor
spec:
  nodeLabels:
    nvidia.com/gpu.present: "true"
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
EOF
        success "ResourceFlavor gpu-flavor created"
    fi

    # ClusterQueue: default (quotas for CPU + GPU workloads)
    if oc get clusterqueue default &>/dev/null 2>&1; then
        success "ClusterQueue default ✓"
    else
        oc apply -f - <<'EOF'
apiVersion: kueue.x-k8s.io/v1beta1
kind: ClusterQueue
metadata:
  name: default
spec:
  namespaceSelector: {}
  resourceGroups:
    - coveredResources: ["cpu", "memory"]
      flavors:
        - name: default-flavor
          resources:
            - name: cpu
              nominalQuota: 32
            - name: memory
              nominalQuota: 128Gi
    - coveredResources: ["nvidia.com/gpu"]
      flavors:
        - name: gpu-flavor
          resources:
            - name: nvidia.com/gpu
              nominalQuota: 4
EOF
        success "ClusterQueue default created"
    fi

    # LocalQueue in demo namespace (namespace created in Step 3)
    # The default-queue annotation makes it auto-selected for new workloads.
    if oc get ns demo &>/dev/null 2>&1; then
        if oc get localqueue default -n demo &>/dev/null 2>&1; then
            success "LocalQueue default in demo ✓"
        else
            oc apply -f - <<'EOF'
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata:
  name: default
  namespace: demo
  annotations:
    kueue.x-k8s.io/default-queue: "true"
spec:
  clusterQueue: default
EOF
            success "LocalQueue default created in demo"
        fi
    else
        warn "demo namespace not found — create it first, then re-run to add LocalQueue"
    fi
else
    warn "Kueue CRDs not ready yet — resource queues will be configured on next run"
fi

# UIPlugins (requires COO)
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
    warn "COO not ready yet — UIPlugins will be configured on next run"
fi

# Kuadrant CR (requires RHCL operator)
# The Kuadrant CR activates RHCL features: AuthPolicy, RateLimitPolicy,
# TokenRateLimitPolicy, DNSPolicy, and TLSPolicy. Without it, RHCL is
# installed but inactive — the Connectivity Link menu shows no resources.
#
# IMPORTANT: Kuadrant CR MUST be in kuadrant-system namespace.
# The MaaS controller (odh-model-controller) hardcodes kuadrant-system
# in the maas-default-gateway-authn-ssl EnvoyFilter. Placing Kuadrant
# elsewhere causes the gateway auth cluster to target the wrong service.
KUADRANT_NS="kuadrant-system"
if oc get crd kuadrants.kuadrant.io &>/dev/null 2>&1; then
    # Migrate from old location if needed
    if oc get kuadrant kuadrant -n redhat-connectivity-link-operator &>/dev/null 2>&1; then
        warn "Kuadrant CR in wrong namespace (redhat-connectivity-link-operator) — migrating to $KUADRANT_NS"
        oc delete kuadrant kuadrant -n redhat-connectivity-link-operator --wait=false 2>/dev/null || true
        sleep 5
    fi

    # Wait for RHCL sub-operators before creating Kuadrant CR
    # Without this, Kuadrant gets stuck on MissingDependency (race condition)
    if ! oc get kuadrant kuadrant -n "$KUADRANT_NS" &>/dev/null 2>&1; then
        info "Waiting for RHCL sub-operators (Authorino, Limitador)..."
        WAIT=0
        while [ $WAIT -lt 120 ]; do
            ALL_READY=true
            for SUB_OP in authorino-operator limitador-operator; do
                CSV_PHASE=$(oc get csv -n redhat-connectivity-link-operator --no-headers 2>/dev/null \
                    | grep "$SUB_OP" | awk '{print $NF}')
                [ "$CSV_PHASE" = "Succeeded" ] || { ALL_READY=false; break; }
            done
            [ "$ALL_READY" = true ] && break
            sleep 10; WAIT=$((WAIT + 10))
        done
        [ "$ALL_READY" = true ] && success "Sub-operators ready ✓" || \
            warn "Sub-operators not all ready — proceeding"
    fi

    if oc get kuadrant kuadrant -n "$KUADRANT_NS" &>/dev/null 2>&1; then
        success "Kuadrant CR already exists in $KUADRANT_NS ✓"
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

    # Wait for Kuadrant Ready; full recovery if stuck on MissingDependency
    # NOTE: Kuadrant operator checks dependencies at startup and caches result.
    # OLM reverts rollout restart, so recovery = delete CR → kill pod → recreate CR.
    info "Waiting for Kuadrant to become Ready..."
    WAIT=0
    while [ $WAIT -lt 90 ]; do
        KREADY=$(oc get kuadrant kuadrant -n "$KUADRANT_NS" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
        [ "$KREADY" = "True" ] && break
        if [ $WAIT -eq 30 ] && [ "$KREADY" != "True" ]; then
            KREASON=$(oc get kuadrant kuadrant -n "$KUADRANT_NS" \
                -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || true)
            if [ "$KREASON" = "MissingDependency" ]; then
                warn "MissingDependency — full recovery (delete CR → kill pod → recreate)..."
                oc delete kuadrant kuadrant -n "$KUADRANT_NS" --timeout=30s 2>/dev/null || true
                sleep 5
                KPOD=$(oc get pod -n redhat-connectivity-link-operator --no-headers 2>/dev/null \
                    | grep kuadrant-operator-controller-manager | awk '{print $1}')
                [ -n "$KPOD" ] && oc delete pod "$KPOD" -n redhat-connectivity-link-operator 2>/dev/null || true
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
    [ "$KREADY" = "True" ] && success "Kuadrant CR Ready in $KUADRANT_NS ✓" || \
        warn "Kuadrant not Ready yet — MaaS setup script will handle it"

    # Configure Authorino TLS in kuadrant-system (required for MaaS gateway auth)
    AUTHORINO_TLS=$(oc get authorino authorino -n "$KUADRANT_NS" \
        -o jsonpath='{.spec.listener.tls.enabled}' 2>/dev/null || true)
    if [ "$AUTHORINO_TLS" = "true" ]; then
        success "Authorino TLS already enabled in $KUADRANT_NS ✓"
    elif oc get authorino authorino -n "$KUADRANT_NS" &>/dev/null 2>&1; then
        info "Configuring Authorino TLS in $KUADRANT_NS..."
        oc annotate service authorino-authorino-authorization \
            -n "$KUADRANT_NS" \
            service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert \
            --overwrite 2>/dev/null || true
        WAIT=0
        while [ $WAIT -lt 30 ]; do
            oc get secret authorino-server-cert -n "$KUADRANT_NS" &>/dev/null 2>&1 && break
            sleep 3; WAIT=$((WAIT + 3))
        done
        oc patch authorino authorino -n "$KUADRANT_NS" --type=merge -p '{
          "spec": { "listener": { "tls": { "enabled": true, "certSecretRef": { "name": "authorino-server-cert" } } } }
        }' 2>/dev/null || true
        oc -n "$KUADRANT_NS" set env deployment/authorino \
            SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
            REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt 2>/dev/null || true
        success "Authorino TLS configured in $KUADRANT_NS"
    fi
else
    warn "Kuadrant CRD not ready yet — Kuadrant CR will be created on next run"
fi

# RHCL Console Plugin (requires RHCL operator)
# The kuadrant-console-plugin provides RHCL / Kuadrant UI for managing
# API policies, rate limiting, and gateway configuration in the console.
if oc get consoleplugin kuadrant-console-plugin &>/dev/null 2>&1; then
    # ConsolePlugin CR exists — check if the backing pod is running
    if oc get pods -n redhat-connectivity-link-operator --no-headers 2>/dev/null \
        | grep -q "kuadrant-console-plugin.*Running"; then

        # Check if already enabled in console operator
        ENABLED_PLUGINS=$(oc get console.operator.openshift.io cluster \
            -o jsonpath='{.spec.plugins}' 2>/dev/null || echo "[]")
        if echo "$ENABLED_PLUGINS" | grep -q "kuadrant-console-plugin"; then
            success "RHCL console plugin already enabled ✓"
        else
            info "Enabling RHCL console plugin..."
            if oc patch console.operator.openshift.io cluster --type=json \
                -p '[{"op":"add","path":"/spec/plugins/-","value":"kuadrant-console-plugin"}]' 2>/dev/null; then
                success "RHCL console plugin enabled"
            else
                warn "Could not enable RHCL console plugin — enable manually via Console → Operators → Installed Operators → RHCL"
            fi
        fi
    else
        warn "kuadrant-console-plugin pod not running yet — plugin will be enabled on next run"
    fi
else
    warn "RHCL console plugin CR not found — RHCL operator may still be installing"
fi
echo ""

###############################################################################
# Step 7/9: DSCI Observability + Post-operator setup
#   COO + Tempo must be installed BEFORE configuring DSCI metrics/traces.
#   Otherwise DSCI reconciler sets Ready=Error and MonitoringStack/Perses
#   are never created.  This step (re-)triggers DSCI reconciliation.
###############################################################################
info "=== Step 7/9: DSCI Observability + Post-operator setup ==="

# Check whether COO and Tempo are available
COO_OK=false; TEMPO_OK=false
oc get csv -n openshift-cluster-observability-operator --no-headers 2>/dev/null \
    | grep -q "cluster-observability-operator.*Succeeded" && COO_OK=true
oc get csv -n openshift-tempo-operator --no-headers 2>/dev/null \
    | grep -q "tempo.*Succeeded" && TEMPO_OK=true

if $COO_OK; then
    success "COO installed ✓"
else
    warn "COO not installed — Observe & Monitor will not work"
fi
if $TEMPO_OK; then
    success "Tempo installed ✓"
else
    warn "Tempo not installed — traces will not work"
fi

if $COO_OK; then
    # --- DSCI monitoring: metrics + traces ---
    # This MUST run after COO is installed. If run before, DSCI sets
    # Ready=Error("ClusterObservability operator must be installed")
    # and MonitoringStack/Perses are never provisioned.
    info "Configuring DSCI observability (metrics + traces)..."

    # Check current DSCI error state
    DSCI_READY=$(oc get dscinitialization default-dsci \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    DSCI_REASON=$(oc get dscinitialization default-dsci \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null)

    NEED_RETRIGGER=false
    if [ "$DSCI_READY" = "False" ] && [ "$DSCI_REASON" = "Error" ]; then
        warn "DSCI stuck in Error state — will re-trigger reconciliation"
        NEED_RETRIGGER=true
    fi

    METRICS_CONFIGURED=$(oc get dscinitialization default-dsci \
        -o jsonpath='{.spec.monitoring.metrics.storage.size}' 2>/dev/null)
    if [ -n "$METRICS_CONFIGURED" ] && [ "$NEED_RETRIGGER" = false ]; then
        success "DSCI metrics already configured (storage: $METRICS_CONFIGURED) ✓"
    else
        # Apply or re-apply monitoring config
        oc patch dscinitialization default-dsci --type=merge -p '{
          "spec": {
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
            }
          }
        }'
        success "DSCI metrics/traces configured"

        if [ "$NEED_RETRIGGER" = true ]; then
            # Force DSCI re-reconciliation by toggling an annotation
            info "Re-triggering DSCI reconciliation..."
            oc annotate dscinitialization default-dsci \
                "opendatahub.io/retrigger=$(date +%s)" --overwrite 2>/dev/null || true
        fi
    fi

    # Wait for MonitoringStack
    info "Waiting for MonitoringStack (up to 3 min)..."
    MON_STATUS=""
    WAIT=0
    while [ $WAIT -lt 180 ]; do
        MON_STATUS=$(oc get dscinitialization default-dsci \
            -o jsonpath='{.status.conditions[?(@.type=="MonitoringStackAvailable")].status}' 2>/dev/null)
        [ "$MON_STATUS" = "True" ] && { success "MonitoringStack ✓"; break; }
        # Check if DSCI still errored (operator might need restart)
        if [ $WAIT -eq 60 ]; then
            DSCI_READY2=$(oc get dscinitialization default-dsci \
                -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
            if [ "$DSCI_READY2" = "False" ]; then
                warn "DSCI still not Ready after 60s — restarting RHOAI operator to re-trigger..."
                oc delete pod -n redhat-ods-operator -l name=rhods-operator --force --grace-period=0 2>/dev/null || true
            fi
        fi
        sleep 10; WAIT=$((WAIT + 10))
    done
    [ "${MON_STATUS:-}" != "True" ] && warn "MonitoringStack not ready yet (will reconcile in background)"

    # DCGM metrics for RHOAI MonitoringStack Prometheus
    # The RHOAI MonitoringStack Prometheus only scrapes its own namespace by
    # default. Without this ServiceMonitor, the "LLM Utilization" tab in
    # Observe & Monitor shows no GPU data (it uses data-science-prometheus-
    # datasource, NOT the cluster Prometheus).
    # The recording rule converts DCGM_FI_* → accelerator_* within this Prometheus.
    if oc get prometheusrule nvidia-gpu-operator-metrics -n nvidia-gpu-operator &>/dev/null 2>&1; then
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
        label_replace(
          DCGM_FI_DEV_GPU_UTIL,
          "k8s_pod_name", "$1", "exported_pod", "(.*)"
        )
    - record: accelerator_memory_used_bytes
      expr: |
        label_replace(
          DCGM_FI_DEV_FB_USED * 1024 * 1024,
          "k8s_pod_name", "$1", "exported_pod", "(.*)"
        )
    - record: accelerator_memory_total_bytes
      expr: |
        label_replace(
          (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE) * 1024 * 1024,
          "k8s_pod_name", "$1", "exported_pod", "(.*)"
        )
    - record: accelerator_memory_clock_hertz
      expr: |
        label_replace(
          DCGM_FI_DEV_MEM_CLOCK * 1e6,
          "k8s_pod_name", "$1", "exported_pod", "(.*)"
        )
    - record: accelerator_sm_clock_hertz
      expr: |
        label_replace(
          DCGM_FI_DEV_SM_CLOCK * 1e6,
          "k8s_pod_name", "$1", "exported_pod", "(.*)"
        )
    - record: accelerator_power_usage_watts
      expr: |
        label_replace(
          DCGM_FI_DEV_POWER_USAGE,
          "k8s_pod_name", "$1", "exported_pod", "(.*)"
        )
    - record: accelerator_temperature_celsius
      expr: |
        label_replace(
          DCGM_FI_DEV_GPU_TEMP,
          "k8s_pod_name", "$1", "exported_pod", "(.*)"
        )
DCGMEOF
        success "DCGM ServiceMonitor + recording rules created in redhat-ods-monitoring"
    else
        info "GPU Operator not installed — DCGM metrics for RHOAI monitoring skipped"
    fi

    # Wait for Perses
    info "Waiting for Perses..."
    PERSES_STATUS=""
    WAIT=0
    while [ $WAIT -lt 120 ]; do
        PERSES_STATUS=$(oc get dscinitialization default-dsci \
            -o jsonpath='{.status.conditions[?(@.type=="PersesAvailable")].status}' 2>/dev/null)
        [ "$PERSES_STATUS" = "True" ] && { success "Perses ✓"; break; }
        sleep 10; WAIT=$((WAIT + 10))
    done
    [ "${PERSES_STATUS:-}" != "True" ] && warn "Perses not ready yet (will reconcile in background)"
fi

echo ""

###############################################################################
# Step 8/9: Dashboard restart
#   Restart AFTER all config + operators + post-operator resources are in
#   place. This ensures the dashboard picks up UIPlugins, Perses, and all
#   dashboard feature flags in a single restart.
###############################################################################
info "=== Step 8/9: Dashboard restart ==="
oc rollout restart deployment/rhods-dashboard -n redhat-ods-applications 2>/dev/null || true
info "Restarting (1-2 min)..."
sleep 10
oc rollout status deployment/rhods-dashboard -n redhat-ods-applications --timeout=120s 2>/dev/null || \
    warn "Rollout timeout — will complete shortly"
success "Dashboard restarted"
echo ""

###############################################################################
# Step 9/9: Verification
###############################################################################
info "=== Step 9/9: Verification ==="
info "DSC components:"
for comp in MLflowOperatorReady OGXReady AIGatewayReady KserveReady TrustyAIReady AIPipelinesReady DashboardReady WorkbenchesReady ModelsAsAServiceReady; do
    STATUS=$(oc get datasciencecluster default-dsc -o jsonpath="{.status.conditions[?(@.type==\"${comp}\")].status}" 2>/dev/null)
    REASON=$(oc get datasciencecluster default-dsc -o jsonpath="{.status.conditions[?(@.type==\"${comp}\")].reason}" 2>/dev/null)
    if [ "$STATUS" = "True" ]; then
        echo "  ✅ ${comp}"
    else
        echo "  ⬚  ${comp} (${REASON:-pending})"
    fi
done

echo ""
info "Operators:"
for i in "${!OP_NAMES[@]}"; do
    if check_operator_installed "$i"; then
        echo "  ✅ ${OP_NAMES[$i]}"
    else
        echo "  ⬚  ${OP_NAMES[$i]}"
    fi
done

echo ""
info "Observability:"
MON_STATUS=$(oc get dscinitialization default-dsci \
  -o jsonpath='{.status.conditions[?(@.type=="MonitoringStackAvailable")].status}' 2>/dev/null)
PERSES_STATUS=$(oc get dscinitialization default-dsci \
  -o jsonpath='{.status.conditions[?(@.type=="PersesAvailable")].status}' 2>/dev/null)
[ "${MON_STATUS:-}" = "True" ] && echo "  ✅ MonitoringStack" || echo "  ⬚  MonitoringStack"
[ "${PERSES_STATUS:-}" = "True" ] && echo "  ✅ Perses" || echo "  ⬚  Perses"

echo ""
info "Kueue:"
CQ_ACTIVE=$(oc get clusterqueue default \
    -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' 2>/dev/null || true)
[ "$CQ_ACTIVE" = "True" ] && echo "  ✅ ClusterQueue default (Active)" || echo "  ⬚  ClusterQueue default"
RF_COUNT=$(oc get resourceflavor --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo "  ✅ ResourceFlavors: $RF_COUNT"
for NS in demo; do
    LQ_ACTIVE=$(oc get localqueue default -n "$NS" \
        -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' 2>/dev/null || true)
    [ "$LQ_ACTIVE" = "True" ] && echo "  ✅ LocalQueue default in $NS (Active)" || echo "  ⬚  LocalQueue default in $NS"
done

echo ""
info "Console Plugins:"
for PLUGIN_NAME in kuadrant-console-plugin console-dashboards-plugin monitoring-console-plugin; do
    ENABLED_PLUGINS=$(oc get console.operator.openshift.io cluster \
        -o jsonpath='{.spec.plugins}' 2>/dev/null || echo "[]")
    if echo "$ENABLED_PLUGINS" | grep -q "$PLUGIN_NAME"; then
        echo "  ✅ ${PLUGIN_NAME}"
    else
        echo "  ⬚  ${PLUGIN_NAME}"
    fi
done

echo ""
info "Operator CRs:"
# Kuadrant CR (must be in kuadrant-system)
KUADRANT_READY=$(oc get kuadrant kuadrant -n kuadrant-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
[ "$KUADRANT_READY" = "True" ] && echo "  ✅ Kuadrant CR (Ready in kuadrant-system)" || echo "  ⬚  Kuadrant CR (${KUADRANT_READY:-not found})"
# Authorino TLS in kuadrant-system
AUTHORINO_TLS=$(oc get authorino authorino -n kuadrant-system \
    -o jsonpath='{.spec.listener.tls.enabled}' 2>/dev/null || true)
[ "$AUTHORINO_TLS" = "true" ] && echo "  ✅ Authorino TLS (enabled)" || echo "  ⬚  Authorino TLS (${AUTHORINO_TLS:-not configured})"
# LWS operator CR
LWS_AVAILABLE=$(oc get leaderworkersetoperator cluster -n openshift-lws-operator \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
[ "$LWS_AVAILABLE" = "True" ] && echo "  ✅ LeaderWorkerSetOperator CR" || echo "  ⬚  LeaderWorkerSetOperator CR (${LWS_AVAILABLE:-not found})"

echo ""
info "Services:"
MLFLOW_READY=$(oc get mlflow mlflow -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
[ "$MLFLOW_READY" = "True" ] && echo "  ✅ MLflow server" || echo "  ⬚  MLflow server"
EVALHUB_PHASE=$(oc get evalhub evalhub -n redhat-ods-applications -o jsonpath='{.status.phase}' 2>/dev/null || true)
[ "$EVALHUB_PHASE" = "Ready" ] && echo "  ✅ EvalHub" || echo "  ⬚  EvalHub (${EVALHUB_PHASE:-not deployed})"

echo ""
info "Gateway:"
oc get gateway -n openshift-ingress --no-headers 2>/dev/null | while read name class addr rest; do
    echo "  $name → $addr"
done

echo ""
info "Dashboard URL:"
echo "  https://$(oc get route data-science-gateway -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || echo '(check manually)')"

###############################################################################
# Step 10: GPU MachineSet (g6.2xlarge / NVIDIA L4)
#   Creates the MachineSet definition only (replicas=0). Scale up manually:
#     oc scale machineset <name> -n openshift-machine-api --replicas=1
#   Requires: AWS credentials, existing worker subnet/SG in the cluster.
###############################################################################
info "=== Step 10: GPU MachineSet (g6.2xlarge) ==="

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

        if oc get machineset "$GPU_MS_NAME" -n openshift-machine-api &>/dev/null 2>&1; then
            success "GPU MachineSet $GPU_MS_NAME already exists"
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
# Step 11: GPU Hardware Profile scheduling
#   Ensures the gpu-profile HardwareProfile has the correct toleration and
#   nodeSelector so workloads schedule onto tainted GPU worker nodes.
###############################################################################
info "=== Step 11: GPU Hardware Profile scheduling ==="

if oc get hardwareprofile gpu-profile -n redhat-ods-applications &>/dev/null 2>&1; then
    # Check if scheduling is already configured
    SCHED_TYPE=$(oc get hardwareprofile gpu-profile -n redhat-ods-applications \
        -o jsonpath='{.spec.scheduling.type}' 2>/dev/null || true)
    NODE_SEL=$(oc get hardwareprofile gpu-profile -n redhat-ods-applications \
        -o jsonpath='{.spec.scheduling.node.nodeSelector}' 2>/dev/null || true)
    TOL_KEY=$(oc get hardwareprofile gpu-profile -n redhat-ods-applications \
        -o jsonpath='{.spec.scheduling.node.tolerations[0].key}' 2>/dev/null || true)

    if [ "$SCHED_TYPE" = "Node" ] && [ -n "$NODE_SEL" ] && [ "$TOL_KEY" = "nvidia.com/gpu" ]; then
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

echo ""
echo "=============================================="
success "Done! Refresh the dashboard."
echo ""
echo "  Next steps:"
echo "  • Deploy a model: Dashboard → Gen AI Studio → Deploy"
echo "    - llm-d: LLMInferenceService (MaaS gateway, subscription/auth)"
echo ""
echo "  • MaaS setup: bash scripts/sno-setup-maas-35.sh"
echo ""
echo "  • Scale up GPU node: oc scale machineset <gpu-ms-name> -n openshift-machine-api --replicas=1"
echo ""
echo "  • If some operators show ⬚, re-run this script."
echo "    Operators installed by OLM continue in the background."
echo "=============================================="
