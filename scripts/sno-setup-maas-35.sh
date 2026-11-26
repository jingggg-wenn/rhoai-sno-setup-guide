#!/bin/bash
###############################################################################
# sno-setup-maas-35.sh
#
# Set up MaaS (Models-as-a-Service) infrastructure on an SNO cluster
# running RHOAI 3.5. Deploys a POC PostgreSQL, configures Authorino TLS
# via OpenShift service-ca, and optionally sets up Redis rate limiting.
#
# Key design decisions (RHOAI 3.5.1):
#   - Kuadrant CR MUST be in kuadrant-system namespace. The MaaS controller
#     (odh-model-controller) hardcodes kuadrant-system in the EnvoyFilter
#     that connects the gateway to Authorino. Wrong namespace = 500 errors.
#   - Authorino TLS is configured via OpenShift service-ca (service annotation
#     → cert secret → patch Authorino listener → SSL env vars)
#   - maas-db-config secret goes in redhat-ai-gateway-infra (where maas-api runs)
#   - PostgreSQL DB URL uses FQDN for cross-namespace DNS resolution
#   - Current user is added to rhods-admins group for subscription auth
#
# Workflow after this script:
#   1. Deploy a model via Dashboard → Gen AI Studio → Deploy (llm-d runtime)
#   2. Register Subscription + Auth Policy via Dashboard
#   3. Verify with:  curl /v1/models  (via MaaS endpoint)
#
# Known issue (RHOAI 3.5.1):
#   Non-streaming chat/completions via MaaS gateway may return empty (0-byte)
#   responses. This is caused by the payload-processing ext_proc filter's
#   FULL_DUPLEX_STREAMED response body mode conflicting with single-body
#   (non-streaming) responses. Streaming (stream:true) works correctly.
#   Playground uses streaming by default, so it is not affected.
#
# Usage:
#   bash sno-setup-maas-35.sh                                  # POC PostgreSQL
#   bash sno-setup-maas-35.sh --postgres-connection <url>      # External DB
#   bash sno-setup-maas-35.sh --skip-rate-limiting             # Skip Redis
#
# Prerequisites:
#   - oc login completed
#   - RHOAI 3.5+ installed with DSC 'default-dsc'
#   - RHCL operator installed
#   - aigateway + modelsAsAService enabled in DSC
#   - maas-default-gateway created
#
# Tip: Run sno-enable-all-features-35.sh first to ensure all prerequisites.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

POSTGRES_CONNECTION=""
SKIP_RATE_LIMITING=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --postgres-connection) POSTGRES_CONNECTION="$2"; shift 2 ;;
        --skip-rate-limiting)  SKIP_RATE_LIMITING=true; shift ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "  --postgres-connection <url>  External PostgreSQL connection URL"
            echo "                               e.g. postgresql://user:pass@host:5432/db?sslmode=require"
            echo "  --skip-rate-limiting         Skip Redis + EnvoyFilter setup"
            echo "  --help                       Show this help"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }

###############################################################################
# wait_for  --  visual progress bar with spinner
#   Usage:  wait_for <timeout_sec> "<label>" <check_command ...>
#   The check_command runs in a subprocess (bash -c) each iteration.
#   Returns 0 when check passes, or 1 if timeout is reached.
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

echo "=============================================="
echo " RHOAI 3.5.2 SNO — MaaS Setup"
echo "=============================================="
echo ""

# The namespace where maas-api and Authorino run in RHOAI 3.5.1
MAAS_INFRA_NS="redhat-ai-gateway-infra"

###############################################################################
# Pre-flight checks
###############################################################################
info "=== Pre-flight checks ==="

if ! oc whoami &>/dev/null; then
    error "oc login required"
    exit 1
fi
success "Logged in: $(oc whoami) @ $(oc whoami --show-server)"

# Clean up Completed/Error pods to free pod slots
STALE_PODS=$( (oc get pods -A --field-selector=status.phase==Succeeded --no-headers 2>/dev/null; \
              oc get pods -A --field-selector=status.phase==Failed --no-headers 2>/dev/null) | wc -l | tr -d ' ')
if [ "${STALE_PODS:-0}" -gt 0 ]; then
    info "Cleaning up $STALE_PODS Completed/Failed pods to free pod slots..."
    oc delete pods -A --field-selector=status.phase==Succeeded 2>/dev/null || true
    oc delete pods -A --field-selector=status.phase==Failed 2>/dev/null || true
    success "Stale pods cleaned up ✓"
fi

RHOAI_CSV=$(oc get csv -n redhat-ods-operator --no-headers 2>/dev/null | grep rhods | awk '{print $1}')
if [ -z "$RHOAI_CSV" ]; then
    error "RHOAI Operator not installed"
    exit 1
fi
success "RHOAI: $(echo "$RHOAI_CSV" | sed 's/rhods-operator\.//')"

# Check RHCL
if bash -c 'oc get subscription -A --no-headers 2>/dev/null | grep -q "rhcl-operator"'; then
    success "RHCL operator ✓"
else
    error "RHCL operator not installed"
    echo "  Run: bash sno-enable-all-features-35.sh first"
    exit 1
fi

# Check aigateway in DSC
AIGATEWAY=$(oc get datasciencecluster default-dsc \
  -o jsonpath='{.spec.components.aigateway.managementState}' 2>/dev/null)
if [ "$AIGATEWAY" != "Managed" ]; then
    error "AIGateway not enabled in DSC (current: ${AIGATEWAY:-unset})"
    echo "  Run: bash sno-enable-all-features-35.sh first"
    exit 1
fi
success "AIGateway: Managed ✓"

# Check maas-default-gateway
if oc get gateway maas-default-gateway -n openshift-ingress &>/dev/null 2>&1; then
    success "maas-default-gateway ✓"
else
    error "maas-default-gateway not found in openshift-ingress"
    echo "  Run: bash sno-enable-all-features-35.sh first"
    exit 1
fi

# Ensure MaaS infra namespace exists
if ! oc get ns "$MAAS_INFRA_NS" &>/dev/null 2>&1; then
    warn "$MAAS_INFRA_NS namespace not found — will be created by operator"
    if ! wait_for 120 "Namespace: $MAAS_INFRA_NS" \
        "oc get ns $MAAS_INFRA_NS"; then
        error "$MAAS_INFRA_NS namespace not created. Ensure aigateway is Managed in DSC."
        exit 1
    fi
else
    success "Namespace: $MAAS_INFRA_NS ✓"
fi

###############################################################################
# Patch openshift-ai-inference Gateway
#   KServe creates this gateway with a hard-coded namespace list (snapshot at
#   creation time) and never updates it. New DS projects get "NotAllowedByListeners"
#   on HTTPRoutes. Fix: use opendatahub.io/dashboard label selector so any DS
#   project created via dashboard is automatically allowed.
#   Needed for both vLLM InferenceService and llm-d LLMInferenceService.
###############################################################################
if oc get gateway openshift-ai-inference -n openshift-ingress &>/dev/null; then
    info "Patching openshift-ai-inference gateway for DS project access..."
    oc label ns openshift-ingress opendatahub.io/dashboard=true --overwrite 2>/dev/null || true
    oc label ns redhat-ods-applications opendatahub.io/dashboard=true --overwrite 2>/dev/null || true
    oc patch gateway openshift-ai-inference -n openshift-ingress --type='json' -p='[
      {"op":"replace","path":"/spec/listeners/0/allowedRoutes/namespaces","value":{
        "from":"Selector",
        "selector":{
          "matchLabels":{
            "opendatahub.io/dashboard":"true"
          }
        }
      }}
    ]' 2>/dev/null && success "Inference gateway: all DS projects allowed" \
                   || warn "Could not patch inference gateway"

    # Fix TLS cert reference — KServe creates the gateway with a non-existent
    # "default-gateway-tls" secret. Use cert-manager-ingress-cert instead.
    TLS_REF=$(oc get gateway openshift-ai-inference -n openshift-ingress \
        -o jsonpath='{.spec.listeners[0].tls.certificateRefs[0].name}' 2>/dev/null)
    if [ "$TLS_REF" = "default-gateway-tls" ] && \
       ! oc get secret default-gateway-tls -n openshift-ingress &>/dev/null 2>&1; then
        info "Fixing inference gateway TLS cert reference..."
        oc patch gateway openshift-ai-inference -n openshift-ingress --type='json' -p='[
          {"op":"replace","path":"/spec/listeners/0/tls/certificateRefs","value":[
            {"group":"","kind":"Secret","name":"cert-manager-ingress-cert"}
          ]}
        ]' 2>/dev/null && success "Inference gateway TLS fixed (cert-manager-ingress-cert)" \
                       || warn "Could not fix inference gateway TLS"
    fi
fi
echo ""

# Add current user to rhods-admins group (required for MaaS subscription auth)
CURRENT_USER=$(oc whoami)
if oc get group rhods-admins &>/dev/null 2>&1; then
    if oc get group rhods-admins -o jsonpath='{.users}' 2>/dev/null | grep -q "\"${CURRENT_USER}\""; then
        success "${CURRENT_USER} already in rhods-admins ✓"
    else
        info "Adding ${CURRENT_USER} to rhods-admins group..."
        oc adm groups add-users rhods-admins "$CURRENT_USER" 2>/dev/null || true
        success "${CURRENT_USER} added to rhods-admins"
    fi
else
    warn "rhods-admins group not found — will be created when RHOAI reconciles"
fi

echo ""

# Determine the namespace where PostgreSQL is deployed
PG_DEPLOY_NS="redhat-ods-applications"

###############################################################################
# Step 1. PostgreSQL database
#   PostgreSQL deploys in redhat-ods-applications.
#   maas-db-config secret goes in redhat-ai-gateway-infra (where maas-api runs).
#   DB URL must use FQDN for cross-namespace DNS resolution.
###############################################################################
info "=== Step 1/5: PostgreSQL database ==="

if oc get secret maas-db-config -n "$MAAS_INFRA_NS" &>/dev/null; then
    success "maas-db-config secret already exists in $MAAS_INFRA_NS [SKIP]"
elif [ -n "$POSTGRES_CONNECTION" ]; then
    info "Creating maas-db-config from provided connection string..."
    printf '%s' "$POSTGRES_CONNECTION" | \
        oc create secret generic maas-db-config \
            --from-file=DB_CONNECTION_URL=/dev/stdin \
            --dry-run=client -o yaml | \
        oc label --local -f - app=maas-api --dry-run=client -o yaml | \
        oc apply -n "$MAAS_INFRA_NS" -f -
    success "maas-db-config created in $MAAS_INFRA_NS (external DB)"
else
    warn "No --postgres-connection provided. Deploying POC PostgreSQL (NOT for production)."
    info "For production: AWS RDS, Crunchy Operator, or Azure Database for PostgreSQL"
    echo ""

    PG_USER="maas"
    PG_DB="maas"
    PG_PASSWORD="$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)"

    # Resolve PostgreSQL image from RHOAI operator CSV
    PG_IMAGE=$(oc get csv -l 'olm.copiedFrom=redhat-ods-operator' \
        -o jsonpath='{.items[0].spec.relatedImages[?(@.name=="postgresql_16_image")].image}' 2>/dev/null) || true
    if [ -z "$PG_IMAGE" ]; then
        PG_IMAGE="registry.redhat.io/rhel9/postgresql-16:latest"
    fi
    info "PostgreSQL image: $PG_IMAGE"

    # Deploy PostgreSQL in redhat-ods-applications
    if [ -f "$ROOT_DIR/lib/manifests/maas/postgres-pvc.yaml" ]; then
        oc apply -n "$PG_DEPLOY_NS" -f "$ROOT_DIR/lib/manifests/maas/postgres-pvc.yaml"
        oc apply -n "$PG_DEPLOY_NS" -f "$ROOT_DIR/lib/manifests/maas/postgres-service.yaml"
        export PG_IMAGE PG_USER PG_PASSWORD PG_DB
        envsubst '${PG_IMAGE} ${PG_USER} ${PG_PASSWORD} ${PG_DB}' \
            < "$ROOT_DIR/lib/manifests/maas/postgres-deployment.yaml" | oc apply -n "$PG_DEPLOY_NS" -f -
    else
        info "Deploying PostgreSQL inline..."
        oc apply -n "$PG_DEPLOY_NS" -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
  labels: { app: postgres, purpose: poc }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 20Gi } }
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  labels: { app: postgres }
spec:
  selector: { app: postgres }
  ports: [{ port: 5432, targetPort: 5432 }]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  labels: { app: postgres, purpose: poc }
spec:
  replicas: 1
  selector: { matchLabels: { app: postgres } }
  template:
    metadata: { labels: { app: postgres } }
    spec:
      containers:
      - name: postgres
        image: ${PG_IMAGE}
        ports: [{ containerPort: 5432 }]
        env:
        - { name: POSTGRESQL_USER, value: "${PG_USER}" }
        - { name: POSTGRESQL_PASSWORD, value: "${PG_PASSWORD}" }
        - { name: POSTGRESQL_DATABASE, value: "${PG_DB}" }
        volumeMounts: [{ name: data, mountPath: /var/lib/pgsql/data }]
        resources:
          requests: { cpu: 250m, memory: 512Mi }
          limits: { cpu: "1", memory: 1Gi }
        readinessProbe:
          exec: { command: ["pg_isready", "-U", "${PG_USER}", "-d", "${PG_DB}"] }
          initialDelaySeconds: 5
          periodSeconds: 5
      volumes:
      - name: data
        persistentVolumeClaim: { claimName: postgres-data }
EOF
    fi
    unset PG_PASSWORD

    wait_for 120 "PostgreSQL ready" \
        "oc rollout status deployment/postgres -n $PG_DEPLOY_NS --timeout=5s"

    # Build DB URL with FQDN (cross-namespace resolution)
    PG_PASSWORD_ACTUAL=$(oc get deployment postgres -n "$PG_DEPLOY_NS" \
        -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="POSTGRESQL_PASSWORD")].value}' 2>/dev/null)
    ENCODED_PW=$(printf '%s' "$PG_PASSWORD_ACTUAL" | od -An -tx1 | tr -d ' \n' | sed 's/../%&/g')
    PG_FQDN="postgres.${PG_DEPLOY_NS}.svc.cluster.local"
    DB_URL="postgresql://${PG_USER}:${ENCODED_PW}@${PG_FQDN}:5432/${PG_DB}?sslmode=disable"

    # Create maas-db-config in the MaaS infra namespace (where maas-api reads it)
    printf '%s' "$DB_URL" | \
        oc create secret generic maas-db-config \
            --from-file=DB_CONNECTION_URL=/dev/stdin \
            --dry-run=client -o yaml | \
        oc label --local -f - app=maas-api --dry-run=client -o yaml | \
        oc apply -n "$MAAS_INFRA_NS" -f -

    # Also keep a copy in redhat-ods-applications for reference
    printf '%s' "$DB_URL" | \
        oc create secret generic maas-db-config \
            --from-file=DB_CONNECTION_URL=/dev/stdin \
            --dry-run=client -o yaml | \
        oc label --local -f - app=maas-api --dry-run=client -o yaml | \
        oc apply -n "$PG_DEPLOY_NS" -f -

    oc create secret generic postgres-creds \
        --from-literal=user="$PG_USER" \
        --from-literal=password="$PG_PASSWORD_ACTUAL" \
        --from-literal=database="$PG_DB" \
        -n "$PG_DEPLOY_NS" --dry-run=client -o yaml | \
        oc apply -n "$PG_DEPLOY_NS" -f -

    success "maas-db-config created in $MAAS_INFRA_NS (FQDN: $PG_FQDN)"
fi
echo ""

###############################################################################
# Step 2. Kuadrant CR + Authorino TLS in kuadrant-system
#
#   IMPORTANT: The MaaS controller (odh-model-controller) hardcodes
#   kuadrant-system in the maas-default-gateway-authn-ssl EnvoyFilter.
#   The Kuadrant-managed Authorino MUST be in kuadrant-system.
#
#   Race condition prevention:
#   RHCL installs sub-operators (Authorino, Limitador, DNS) asynchronously.
#   If the Kuadrant CR is created before all sub-operators are ready, it
#   gets stuck with "MissingDependency" and never creates Limitador CR.
#   Solution: wait for all 3 sub-operator CSVs to succeed BEFORE creating
#   the Kuadrant CR, then verify Kuadrant becomes Ready (both Authorino
#   AND Limitador created). If stuck, restart the Kuadrant operator pod.
#
#   After Kuadrant is Ready, configure Authorino TLS via service-ca.
###############################################################################
info "=== Step 2/5: Kuadrant + Authorino TLS (kuadrant-system) ==="

KUADRANT_NS="kuadrant-system"

# --- 2a. Wait for all RHCL sub-operator CSVs to be Succeeded ---
wait_for 180 "RHCL sub-operators ready (Authorino, Limitador)" \
    'oc get csv -n redhat-connectivity-link-operator --no-headers 2>/dev/null | grep "authorino-operator" | grep -q Succeeded && oc get csv -n redhat-connectivity-link-operator --no-headers 2>/dev/null | grep "limitador-operator" | grep -q Succeeded' \
    || true

# --- 2b. Create Kuadrant CR in kuadrant-system ---
oc create namespace "$KUADRANT_NS" 2>/dev/null || true
if ! oc get kuadrant kuadrant -n "$KUADRANT_NS" &>/dev/null 2>&1; then
    info "Creating Kuadrant CR in $KUADRANT_NS..."
    oc apply -f - <<EOF
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
  namespace: ${KUADRANT_NS}
spec: {}
EOF
fi

# --- 2c. Wait for Kuadrant Ready (Authorino + Limitador both created) ---
# NOTE: Kuadrant operator checks dependencies at startup and caches the result.
# OLM-managed deployments ignore rollout restart (OLM reverts the change).
# Recovery requires: delete CR → delete pod directly → recreate CR.
#
# First attempt: simple wait with progress bar
if ! wait_for 30 "Kuadrant Ready in $KUADRANT_NS" \
    'oc get kuadrant kuadrant -n '"$KUADRANT_NS"' -o jsonpath='"'"'{.status.conditions[?(@.type=="Ready")].status}'"'"' 2>/dev/null | grep -q True'; then

    # Check if stuck on MissingDependency -- full recovery cycle
    KREASON=$(oc get kuadrant kuadrant -n "$KUADRANT_NS" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || true)
    if [ "$KREASON" = "MissingDependency" ]; then
        warn "Kuadrant stuck on MissingDependency -- recovery cycle..."
        oc delete kuadrant kuadrant -n "$KUADRANT_NS" --timeout=30s 2>/dev/null || true
        sleep 5
        KPOD=$(oc get pod -n redhat-connectivity-link-operator --no-headers 2>/dev/null \
            | grep kuadrant-operator-controller-manager | awk '{print $1}')
        if [ -n "$KPOD" ]; then
            oc delete pod "$KPOD" -n redhat-connectivity-link-operator 2>/dev/null || true
            wait_for 60 "Kuadrant operator pod restarted" \
                'oc get deployment kuadrant-operator-controller-manager -n redhat-connectivity-link-operator -o jsonpath='"'"'{.status.readyReplicas}'"'"' 2>/dev/null | grep -q 1' \
                || true
        fi
        oc apply -f - <<EOFRECOVERY
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
  namespace: ${KUADRANT_NS}
spec: {}
EOFRECOVERY
        info "Kuadrant CR recreated"
    fi

    # Second attempt after recovery
    wait_for 90 "Kuadrant Ready in $KUADRANT_NS" \
        'oc get kuadrant kuadrant -n '"$KUADRANT_NS"' -o jsonpath='"'"'{.status.conditions[?(@.type=="Ready")].status}'"'"' 2>/dev/null | grep -q True' \
        || warn "Kuadrant not Ready yet -- check: oc get kuadrant -n $KUADRANT_NS -o yaml"
fi

# Verify both Authorino and Limitador were created
oc get authorino -n "$KUADRANT_NS" --no-headers &>/dev/null && \
    success "Authorino created in $KUADRANT_NS ✓" || warn "Authorino not found in $KUADRANT_NS"
oc get limitador -n "$KUADRANT_NS" --no-headers &>/dev/null && \
    success "Limitador created in $KUADRANT_NS ✓" || warn "Limitador not found in $KUADRANT_NS"

# --- 2d. Authorino TLS configuration ---
AUTHORINO_TLS=$(oc get authorino authorino -n "$KUADRANT_NS" \
    -o jsonpath='{.spec.listener.tls.enabled}' 2>/dev/null || true)

if [ "$AUTHORINO_TLS" = "true" ]; then
    success "Authorino TLS already enabled ✓"
else
    if oc get svc authorino-authorino-authorization -n "$KUADRANT_NS" &>/dev/null 2>&1; then
        info "Configuring Authorino TLS..."

        # Annotate service for service-ca cert generation
        oc annotate service authorino-authorino-authorization \
            -n "$KUADRANT_NS" \
            service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert \
            --overwrite

        # Wait for cert
        wait_for 60 "Authorino TLS cert generated" \
            "oc get secret authorino-server-cert -n $KUADRANT_NS" || true

        if oc get secret authorino-server-cert -n "$KUADRANT_NS" &>/dev/null 2>&1; then
            # Enable TLS on Authorino listener
            oc patch authorino authorino -n "$KUADRANT_NS" --type=merge -p '{
              "spec": { "listener": { "tls": { "enabled": true, "certSecretRef": { "name": "authorino-server-cert" } } } }
            }'

            # SSL env vars for outbound TLS
            oc -n "$KUADRANT_NS" set env deployment/authorino \
                SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
                REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt 2>/dev/null || true

            # Wait for Authorino Ready
            wait_for 60 "Authorino TLS enabled" \
                'oc get authorino authorino -n '"$KUADRANT_NS"' -o jsonpath='"'"'{.status.conditions[?(@.type=="Ready")].status}'"'"' 2>/dev/null | grep -q True' \
                || warn "Authorino not fully ready yet (will reconcile in background)"
        else
            warn "TLS cert not generated after 60s — Authorino running without TLS"
        fi
    else
        warn "Authorino service not found in $KUADRANT_NS — TLS not configured"
    fi
fi

# Annotate MaaS gateway for Authorino TLS bootstrap
oc annotate gateway maas-default-gateway \
    -n openshift-ingress \
    security.opendatahub.io/authorino-tls-bootstrap="true" \
    --overwrite 2>/dev/null || warn "Could not annotate maas-default-gateway"

success "Kuadrant + Authorino TLS configuration complete"
echo ""

###############################################################################
# Step 3. Rate limiting (Redis + EnvoyFilters)
###############################################################################
if [ "$SKIP_RATE_LIMITING" = true ]; then
    info "=== Step 3/5: Rate limiting [SKIPPED] ==="
    echo ""
else
    info "=== Step 3/5: Rate limiting (Redis + EnvoyFilters) ==="

    # Redis for rate limiting
    if oc get deployment limitador-redis -n "$MAAS_INFRA_NS" &>/dev/null; then
        success "Redis already deployed ✓"
    else
        info "Deploying Redis..."
        oc apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: limitador-redis
  namespace: ${MAAS_INFRA_NS}
  labels: { app: limitador-redis }
spec:
  replicas: 1
  selector: { matchLabels: { app: limitador-redis } }
  template:
    metadata: { labels: { app: limitador-redis } }
    spec:
      containers:
      - name: redis
        image: registry.redhat.io/rhel9/redis-7:latest
        ports: [{ containerPort: 6379 }]
        resources:
          requests: { cpu: 100m, memory: 128Mi }
          limits: { cpu: 500m, memory: 256Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: limitador-redis
  namespace: ${MAAS_INFRA_NS}
spec:
  selector: { app: limitador-redis }
  ports: [{ port: 6379, targetPort: 6379 }]
EOF
        oc rollout status deployment/limitador-redis -n "$MAAS_INFRA_NS" --timeout=60s 2>/dev/null || true
        success "Redis deployed"
    fi

    # Redis connection secret (in kuadrant-system where Limitador runs)
    if ! oc get secret limitador-redis-config -n "$KUADRANT_NS" &>/dev/null; then
        oc create secret generic limitador-redis-config \
            --from-literal=URL="redis://limitador-redis.${MAAS_INFRA_NS}.svc.cluster.local:6379" \
            -n "$KUADRANT_NS"
    fi

    # Patch Limitador for redis-cached storage (Limitador is in kuadrant-system)
    if oc get crd limitadors.limitador.kuadrant.io &>/dev/null 2>&1; then
        CURRENT_STORAGE=$(oc get limitador limitador -n "$KUADRANT_NS" \
            -o jsonpath='{.spec.storage.redis-cached}' 2>/dev/null || true)
        if [ -z "$CURRENT_STORAGE" ]; then
            info "Configuring Limitador with redis-cached storage..."
            if oc patch limitador limitador -n "$KUADRANT_NS" --type=merge -p '{
                "spec": {
                    "storage": {
                        "redis-cached": {
                            "configSecretRef": { "name": "limitador-redis-config" },
                            "options": {
                                "flush-period": 500,
                                "max-cached": 10000,
                                "batch-size": 100,
                                "response-timeout": 500
                            }
                        }
                    }
                }
            }' 2>/dev/null; then
                success "Limitador configured with Redis"
            else
                warn "Could not patch Limitador — rate limiting may use in-memory storage"
            fi
        else
            success "Limitador already using redis-cached ✓"
        fi
    else
        warn "Limitador CRD not found — skipping redis-cached config"
        warn "Rate limiting may be managed differently in this RHOAI version"
    fi

    # Health check interceptor EnvoyFilter
    if ! oc get envoyfilter healthcheck-filter -n openshift-ingress &>/dev/null; then
        info "Applying health check EnvoyFilter..."
        oc apply -f - <<'EOF'
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: healthcheck-filter
  namespace: openshift-ingress
spec:
  workloadSelector:
    labels:
      gateway.networking.k8s.io/gateway-name: maas-default-gateway
  configPatches:
    - applyTo: HTTP_FILTER
      match:
        context: GATEWAY
        listener:
          filterChain:
            filter:
              name: envoy.filters.network.http_connection_manager
      patch:
        operation: INSERT_FIRST
        value:
          name: envoy.filters.http.health_check
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.http.health_check.v3.HealthCheck
            pass_through_mode: false
            headers:
              - name: ":path"
                string_match: { exact: "/healthz" }
              - name: ":path"
                string_match: { exact: "/ready" }
EOF
        success "Health check filter applied"
    fi

    # Ratelimit cluster timeout
    if ! oc get envoyfilter increase-ratelimit-cluster-timeout -n openshift-ingress &>/dev/null; then
        info "Applying ratelimit timeout EnvoyFilter..."
        oc apply -f - <<'EOF'
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: increase-ratelimit-cluster-timeout
  namespace: openshift-ingress
spec:
  workloadSelector:
    labels:
      gateway.networking.k8s.io/gateway-name: maas-default-gateway
  configPatches:
    - applyTo: CLUSTER
      match:
        context: GATEWAY
        cluster: { name: kuadrant-ratelimit-service }
      patch:
        operation: MERGE
        value: { connect_timeout: 2s }
EOF
        success "Ratelimit timeout (2s) applied"
    fi

    # Restart MaaS gateway to pick up EnvoyFilter changes
    MAAS_DEPLOY=$(oc get deployment -n openshift-ingress \
        -l "gateway.networking.k8s.io/gateway-name=maas-default-gateway" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "$MAAS_DEPLOY" ]; then
        oc rollout restart deployment/"$MAAS_DEPLOY" -n openshift-ingress 2>/dev/null || true
    fi

    success "Rate limiting configured"
    echo ""
fi

###############################################################################
# Restart maas-api to pick up new secrets
###############################################################################
info "Restarting maas-api to pick up configuration..."
oc rollout restart deployment/maas-api -n "$MAAS_INFRA_NS" 2>/dev/null || true
wait_for 60 "maas-api running" \
    'oc get pods -n "'"$MAAS_INFRA_NS"'" --no-headers 2>/dev/null | grep "maas-api" | grep -q "1/1.*Running"' \
    || warn "maas-api not fully ready yet -- check: oc logs deployment/maas-api -n $MAAS_INFRA_NS"
echo ""

###############################################################################
# Step 4. Wait for Kuadrant AuthPolicy reconciliation
#   The Kuadrant operator must successfully reconcile the gateway AuthPolicy
#   and create the kuadrant-auth EnvoyFilter. If the EnvoyFilter is stale
#   from a previous run, delete the operator pod to force a fresh reconcile.
###############################################################################
info "=== Step 4/5: Kuadrant AuthPolicy reconciliation ==="

# Ensure Kuadrant operator is running (serves wasm binary for gateway)
KUADRANT_REPLICAS=$(oc get deployment kuadrant-operator-controller-manager \
    -n redhat-connectivity-link-operator -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
if [ "$KUADRANT_REPLICAS" = "0" ]; then
    info "Kuadrant operator scaled to 0 — scaling up (required for wasm binary)..."
    oc scale deployment kuadrant-operator-controller-manager \
        -n redhat-connectivity-link-operator --replicas=1 2>/dev/null
    oc wait --for=condition=Available \
        deployment/kuadrant-operator-controller-manager \
        -n redhat-connectivity-link-operator --timeout=60s 2>/dev/null || true
fi

# Wait for gateway AuthPolicy to be enforced (first attempt: 30s)
if ! wait_for 30 "Gateway AuthPolicy enforced" \
    'oc get authpolicy maas-gateway-auth -n openshift-ingress -o jsonpath='"'"'{.status.conditions[?(@.type=="Enforced")].status}'"'"' 2>/dev/null | grep -q True'; then

    # If stuck on EnvoyFilter sync, delete operator pod to force fresh cache
    ENFORCED_MSG=$(oc get authpolicy maas-gateway-auth -n openshift-ingress \
        -o jsonpath='{.status.conditions[?(@.type=="Enforced")].message}' 2>/dev/null || true)
    if echo "$ENFORCED_MSG" | grep -q "EnvoyFilter" 2>/dev/null; then
        warn "EnvoyFilter sync stuck -- restarting Kuadrant operator pod..."
        oc delete pod -n redhat-connectivity-link-operator \
            -l control-plane=kuadrant-operator --force --grace-period=0 2>/dev/null || true
        wait_for 60 "Kuadrant operator restarted" \
            'oc wait --for=condition=Available deployment/kuadrant-operator-controller-manager -n redhat-connectivity-link-operator --timeout=5s' \
            || true
    fi

    # Second attempt after recovery
    wait_for 60 "Gateway AuthPolicy enforced" \
        'oc get authpolicy maas-gateway-auth -n openshift-ingress -o jsonpath='"'"'{.status.conditions[?(@.type=="Enforced")].status}'"'"' 2>/dev/null | grep -q True' \
        || warn "Gateway AuthPolicy not enforced yet -- it may take a few minutes for the operator to reconcile"
fi
echo ""

###############################################################################
# Step 5. Verification
###############################################################################
info "=== Step 5/5: Verification ==="

# maas-db-config
if oc get secret maas-db-config -n "$MAAS_INFRA_NS" &>/dev/null; then
    HAS_URL=$(oc get secret maas-db-config -n "$MAAS_INFRA_NS" \
        -o jsonpath='{.data.DB_CONNECTION_URL}' 2>/dev/null)
    if [ -n "$HAS_URL" ]; then
        echo -e "  ${GREEN}[OK]${NC} maas-db-config in $MAAS_INFRA_NS"
    else
        echo -e "  ${YELLOW}[--]${NC} maas-db-config (missing URL key)"
    fi
else
    echo -e "  ${YELLOW}[--]${NC} maas-db-config NOT FOUND in $MAAS_INFRA_NS"
fi

# Authorino TLS (in kuadrant-system)
TLS_ENABLED=$(oc get authorino authorino -n "$KUADRANT_NS" \
    -o jsonpath='{.spec.listener.tls.enabled}' 2>/dev/null || true)
AUTHORINO_READY=$(oc get authorino authorino -n "$KUADRANT_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
if [ "$TLS_ENABLED" = "true" ] && [ "$AUTHORINO_READY" = "True" ]; then
    echo -e "  ${GREEN}[OK]${NC} Authorino TLS enabled & ready ($KUADRANT_NS)"
elif [ "$TLS_ENABLED" = "true" ]; then
    echo -e "  ${YELLOW}[--]${NC} Authorino TLS enabled but not ready yet ($KUADRANT_NS)"
else
    echo -e "  ${YELLOW}[--]${NC} Authorino TLS not enabled ($KUADRANT_NS)"
fi

# Kuadrant operator
KUADRANT_READY=$(oc get deployment kuadrant-operator-controller-manager \
    -n redhat-connectivity-link-operator -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [ "${KUADRANT_READY:-0}" -ge 1 ]; then
    echo -e "  ${GREEN}[OK]${NC} Kuadrant operator running"
else
    echo -e "  ${YELLOW}[--]${NC} Kuadrant operator not ready"
fi

# Gateway AuthPolicy
ENFORCED=$(oc get authpolicy maas-gateway-auth -n openshift-ingress \
    -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}' 2>/dev/null || true)
if [ "$ENFORCED" = "True" ]; then
    echo -e "  ${GREEN}[OK]${NC} Gateway AuthPolicy enforced"
else
    echo -e "  ${YELLOW}[--]${NC} Gateway AuthPolicy not enforced"
fi

# maas-api
MAAS_API_RUNNING=$(oc get pods -n "$MAAS_INFRA_NS" --no-headers 2>/dev/null | grep "maas-api" | grep -c "1/1.*Running" || true)
if [ "$MAAS_API_RUNNING" -ge 1 ]; then
    echo -e "  ${GREEN}[OK]${NC} maas-api running"
else
    echo -e "  ${YELLOW}[--]${NC} maas-api not running"
fi

# rhods-admins group
CURRENT_USER=$(oc whoami)
if bash -c 'oc get group rhods-admins -o jsonpath='"'"'{.users}'"'"' 2>/dev/null | grep -q "\"'"${CURRENT_USER}"'\""'; then
    echo -e "  ${GREEN}[OK]${NC} ${CURRENT_USER} in rhods-admins group"
else
    echo -e "  ${YELLOW}[--]${NC} ${CURRENT_USER} NOT in rhods-admins group"
fi

# MaaS Tenant (created when first Subscription is registered via Dashboard)
TENANT_READY=$(oc get tenant default-tenant -n models-as-a-service \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
if [ "$TENANT_READY" = "True" ]; then
    echo -e "  ${GREEN}[OK]${NC} MaaS Tenant ready"
else
    echo -e "  ${YELLOW}[--]${NC} MaaS Tenant (expected -- created after first Subscription via Dashboard)"
fi

# ModelsAsAServiceReady -- becomes Ready after MaaS setup completes
if bash -c 'oc get datasciencecluster default-dsc -o jsonpath='"'"'{.status.conditions[?(@.type=="ModelsAsAServiceReady")].status}'"'"' 2>/dev/null | grep -q True'; then
    echo -e "  ${GREEN}[OK]${NC} ModelsAsAServiceReady"
else
    echo -e "  ${YELLOW}[--]${NC} ModelsAsAServiceReady -- waiting for reconciliation..."
    wait_for 300 "ModelsAsAServiceReady" \
        'oc get datasciencecluster default-dsc -o jsonpath='"'"'{.status.conditions[?(@.type=="ModelsAsAServiceReady")].status}'"'"' 2>/dev/null | grep -q True' \
        || warn "ModelsAsAServiceReady still not True after 5 min -- check DSC status"
fi

CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
MAAS_ENDPOINT="https://maas.${CLUSTER_DOMAIN}"
DASHBOARD_URL=$(oc get route data-science-gateway -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || \
               oc get route rh-ai -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || \
               echo "data-science-gateway.${CLUSTER_DOMAIN}")

echo ""
echo "=============================================="
success "MaaS setup complete!"
echo ""
echo "  MaaS endpoint:  ${MAAS_ENDPOINT}"
echo "  Dashboard:      https://${DASHBOARD_URL}"
echo ""
echo "  Next steps:"
echo "  ────────────────────────────────────────────"
echo "  1. Deploy model:  Dashboard → Gen AI Studio → Deploy (llm-d runtime)"
echo "  2. Register subscription + auth policy via Dashboard"
echo "  3. Verify:"
echo "     TOKEN=\$(oc whoami -t)"
echo "     curl -sk ${MAAS_ENDPOINT}/v1/models -H \"Authorization: Bearer \$TOKEN\""
echo ""
echo "  ⚠ Known issue (RHOAI 3.5.1):"
echo "    Non-streaming chat/completions via MaaS gateway may return empty body."
echo "    Caused by ext_proc (FULL_DUPLEX_STREAMED) response body processing."
echo "    Streaming (stream:true) works correctly — Playground uses streaming."
echo "=============================================="
