#!/bin/bash
###############################################################################
# deploy_demo_apps.sh
#
# Deploy Inference Design Planner into the demo namespace
# with MLflow tracing pre-configured.
#
# Reuses the existing PostgreSQL in redhat-ods-applications (deployed by
# sno-setup-maas-35.sh). No additional database is installed.
#
# Prerequisites:
#   - oc login completed with cluster-admin privileges
#   - sno-enable-all-features-35.sh already run (MLflow server + ConfigMaps)
#   - sno-setup-maas-35.sh already run (PostgreSQL in redhat-ods-applications)
#   - Container images already pushed to registry
#
# Usage:
#   bash deploy_demo_apps.sh <LLM_BASE_URL> <LLM_API_KEY> <LLM_MODEL>
#
# Example:
#   bash deploy_demo_apps.sh \
#     https://qwen3-direct.apps.cluster.example.com/v1 \
#     not-needed \
#     qwen3-235b-a22b
#
# Options:
#   --namespace=<NS>    Target namespace (default: demo)
#
# Environment overrides:
#   PLANNER_BACKEND_IMAGE   (default: quay.io/hyogrin/inference-planner-backend:latest)
#   PLANNER_FRONTEND_IMAGE  (default: quay.io/hyogrin/inference-planner-frontend:latest)
###############################################################################
set -euo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }

###############################################################################
# Defaults
###############################################################################
NS="demo"
PG_NS="redhat-ods-applications"
PLANNER_BACKEND_IMAGE="${PLANNER_BACKEND_IMAGE:-quay.io/hyogrin/inference-planner-backend:latest}"
PLANNER_FRONTEND_IMAGE="${PLANNER_FRONTEND_IMAGE:-quay.io/hyogrin/inference-planner-frontend:latest}"

###############################################################################
# Parse arguments
###############################################################################
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --namespace=*) NS="${arg#*=}" ;;
        -h|--help)
            echo "Usage: $0 <LLM_BASE_URL> <LLM_API_KEY> <LLM_MODEL> [--namespace=<NS>]"
            exit 0 ;;
        --*) error "Unknown option: $arg"; exit 1 ;;
        *)   POSITIONAL+=("$arg") ;;
    esac
done

if [ ${#POSITIONAL[@]} -ne 3 ]; then
    echo "Usage: $0 <LLM_BASE_URL> <LLM_API_KEY> <LLM_MODEL>"
    exit 1
fi

LLM_BASE_URL="${POSITIONAL[0]}"
LLM_API_KEY="${POSITIONAL[1]}"
LLM_MODEL="${POSITIONAL[2]}"

echo "=============================================="
echo " Deploy Inference Design Planner"
echo "   with MLflow Tracing"
echo "=============================================="
info "Namespace : $NS"
info "LLM URL   : $LLM_BASE_URL"
info "LLM Model : $LLM_MODEL"
echo ""

# Prerequisites
oc whoami &>/dev/null || { error "oc login required"; exit 1; }

CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null)
[ -z "$CLUSTER_DOMAIN" ] && { error "Cannot detect cluster domain"; exit 1; }
info "Cluster   : $CLUSTER_DOMAIN"

# Ensure namespace exists
if ! oc get ns "$NS" &>/dev/null 2>&1; then
    info "Creating namespace $NS..."
    oc new-project "$NS" --skip-config-write 2>/dev/null || oc create namespace "$NS"
fi

# Verify MLflow client ConfigMaps exist (created by sno-enable-all-features Step 3b)
MLFLOW_AVAILABLE=false
if oc get configmap mlflow-client-env -n "$NS" &>/dev/null 2>&1; then
    success "MLflow client ConfigMap found ✓"
    MLFLOW_AVAILABLE=true
else
    warn "ConfigMap mlflow-client-env not found in $NS"
    warn "Run sno-enable-all-features-35.sh first, or MLflow tracing will be disabled"
fi
echo ""

###############################################################################
# Step 1: Reuse existing PostgreSQL
#   The POC PostgreSQL lives in redhat-ods-applications (deployed by
#   sno-setup-maas-35.sh). We create an 'inference_planner' database
#   on it and build a cross-namespace FQDN connection URL.
###############################################################################
info "=== Step 1/4: PostgreSQL (reuse existing) ==="

if ! oc get deployment postgres -n "$PG_NS" &>/dev/null 2>&1; then
    error "PostgreSQL not found in $PG_NS"
    error "Run sno-setup-maas-35.sh first to deploy PostgreSQL"
    exit 1
fi

# Check PostgreSQL is healthy
PG_READY=$(oc get pods -n "$PG_NS" -l app=postgres \
    -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || true)
if [ "$PG_READY" != "true" ]; then
    warn "PostgreSQL pod not ready — waiting up to 60s..."
    WAIT=0
    while [ $WAIT -lt 60 ]; do
        PG_READY=$(oc get pods -n "$PG_NS" -l app=postgres \
            -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || true)
        [ "$PG_READY" = "true" ] && break
        sleep 5; WAIT=$((WAIT + 5))
    done
    [ "$PG_READY" != "true" ] && { error "PostgreSQL not ready"; exit 1; }
fi
success "PostgreSQL running in $PG_NS ✓"

# Read credentials from the existing deployment
PG_USER=$(oc get deployment postgres -n "$PG_NS" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="POSTGRESQL_USER")].value}' 2>/dev/null)
PG_PASSWORD=$(oc get deployment postgres -n "$PG_NS" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="POSTGRESQL_PASSWORD")].value}' 2>/dev/null)

[ -z "$PG_USER" ] && { error "Cannot read PostgreSQL user from deployment"; exit 1; }
[ -z "$PG_PASSWORD" ] && { error "Cannot read PostgreSQL password from deployment"; exit 1; }

# Create inference_planner database (idempotent)
PLANNER_DB="inference_planner"
PG_POD=$(oc get pods -n "$PG_NS" -l app=postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
info "Creating database '$PLANNER_DB' on existing PostgreSQL..."
oc exec "$PG_POD" -n "$PG_NS" -- \
    psql -U "$PG_USER" -d "$PG_USER" \
    -c "SELECT 1 FROM pg_database WHERE datname='${PLANNER_DB}'" 2>/dev/null \
    | grep -q "1" && {
    success "Database '$PLANNER_DB' already exists ✓"
} || {
    oc exec "$PG_POD" -n "$PG_NS" -- \
        psql -U "$PG_USER" -d "$PG_USER" \
        -c "CREATE DATABASE ${PLANNER_DB} OWNER ${PG_USER}" 2>/dev/null && \
        success "Database '$PLANNER_DB' created" || \
        warn "Could not create database — will use '${PG_USER}' database instead"
}

# Build cross-namespace DB URL (FQDN required for demo → redhat-ods-applications)
# URL-encode password (pure bash)
ENCODED_PW=""
for (( i=0; i<${#PG_PASSWORD}; i++ )); do
    _c="${PG_PASSWORD:$i:1}"
    case "$_c" in
        [a-zA-Z0-9._~-]) ENCODED_PW+="$_c" ;;
        *) ENCODED_PW+=$(printf '%%%02X' "'$_c") ;;
    esac
done
PG_FQDN="postgres.${PG_NS}.svc.cluster.local"

# Check which database to use
DB_EXISTS=$(oc exec "$PG_POD" -n "$PG_NS" -- \
    psql -U "$PG_USER" -d "$PG_USER" -tAc \
    "SELECT 1 FROM pg_database WHERE datname='${PLANNER_DB}'" 2>/dev/null || true)
if [ "$DB_EXISTS" = "1" ]; then
    TARGET_DB="$PLANNER_DB"
else
    TARGET_DB="$PG_USER"
    warn "Using '${PG_USER}' database (shared with MaaS/MLflow)"
fi

DB_URL_ASYNC="postgresql+asyncpg://${PG_USER}:${ENCODED_PW}@${PG_FQDN}:5432/${TARGET_DB}?ssl=disable"
DB_URL_SYNC="postgresql://${PG_USER}:${ENCODED_PW}@${PG_FQDN}:5432/${TARGET_DB}?sslmode=disable"

info "DB: ${PG_USER}@${PG_FQDN}:5432/${TARGET_DB}"
echo ""

###############################################################################
# Step 2: ConfigMap + Secret
###############################################################################
info "=== Step 2/4: Configuration ==="

oc apply -n "$NS" -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: planner-config
  namespace: ${NS}
data:
  APP_ENV: "production"
  APP_LOG_LEVEL: "INFO"
  APP_CORS_ORIGINS: "https://inference-planner.${CLUSTER_DOMAIN}"
  LLM_MODEL_NAME: "${LLM_MODEL}"
  MLFLOW_EXPERIMENT_NAME: "inference-design-planner"
  MLFLOW_WORKSPACE: "${NS}"
  PROMETHEUS_ENABLED: "true"
  HF_HOME: "/tmp/hf_cache"
---
apiVersion: v1
kind: Secret
metadata:
  name: planner-secrets
  namespace: ${NS}
type: Opaque
stringData:
  OPENAI_BASE_URL: "${LLM_BASE_URL}"
  OPENAI_API_KEY: "${LLM_API_KEY}"
  DATABASE_URL: "${DB_URL_ASYNC}"
  DATABASE_URL_SYNC: "${DB_URL_SYNC}"
EOF
success "Config + secrets created"
echo ""

###############################################################################
# Step 3: Backend + Frontend
###############################################################################
info "=== Step 3/4: Backend + Frontend ==="

oc apply -n "$NS" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: planner-backend
  namespace: ${NS}
  labels:
    app: planner-backend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: planner-backend
  template:
    metadata:
      labels:
        app: planner-backend
    spec:
      containers:
        - name: backend
          image: ${PLANNER_BACKEND_IMAGE}
          ports:
            - containerPort: 8000
              name: http
          envFrom:
            - configMapRef:
                name: planner-config
            - secretRef:
                name: planner-secrets
            - configMapRef:
                name: mlflow-client-env
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: "1"
              memory: 1Gi
          livenessProbe:
            httpGet:
              path: /api/v1/health
              port: 8000
            initialDelaySeconds: 30
            periodSeconds: 30
          readinessProbe:
            httpGet:
              path: /api/v1/health
              port: 8000
            initialDelaySeconds: 15
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: planner-backend
  namespace: ${NS}
  labels:
    app: planner-backend
spec:
  selector:
    app: planner-backend
  ports:
    - name: http
      port: 8000
      targetPort: 8000
  type: ClusterIP
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: inference-planner-api
  namespace: ${NS}
  labels:
    app: planner-backend
spec:
  host: inference-planner-api.${CLUSTER_DOMAIN}
  to:
    kind: Service
    name: planner-backend
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: planner-frontend
  namespace: ${NS}
  labels:
    app: planner-frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: planner-frontend
  template:
    metadata:
      labels:
        app: planner-frontend
    spec:
      containers:
        - name: frontend
          image: ${PLANNER_FRONTEND_IMAGE}
          ports:
            - containerPort: 3000
              name: http
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
          livenessProbe:
            httpGet:
              path: /
              port: 3000
            initialDelaySeconds: 15
            periodSeconds: 30
          readinessProbe:
            httpGet:
              path: /
              port: 3000
            initialDelaySeconds: 10
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: planner-frontend
  namespace: ${NS}
  labels:
    app: planner-frontend
spec:
  selector:
    app: planner-frontend
  ports:
    - name: http
      port: 3000
      targetPort: 3000
  type: ClusterIP
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: inference-planner
  namespace: ${NS}
  labels:
    app: planner-frontend
spec:
  host: inference-planner.${CLUSTER_DOMAIN}
  to:
    kind: Service
    name: planner-frontend
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

success "Backend + Frontend applied"
echo ""

###############################################################################
# Step 4: DB Migration + MLflow RBAC + Verify
###############################################################################
info "=== Step 4/4: Migration + RBAC + Verify ==="

# DB Migration
oc delete job planner-db-migrate -n "$NS" 2>/dev/null || true
oc apply -n "$NS" -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: planner-db-migrate
  namespace: ${NS}
spec:
  backoffLimit: 3
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: migrate
          image: ${PLANNER_BACKEND_IMAGE}
          command: ["alembic", "upgrade", "head"]
          env:
            - name: DATABASE_URL_SYNC
              valueFrom:
                secretKeyRef:
                  name: planner-secrets
                  key: DATABASE_URL_SYNC
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
EOF

WAIT=0
while [ $WAIT -lt 60 ]; do
    JOB_STATUS=$(oc get job planner-db-migrate -n "$NS" \
        -o jsonpath='{.status.succeeded}' 2>/dev/null || true)
    [ "$JOB_STATUS" = "1" ] && { success "DB migration complete ✓"; break; }
    sleep 5; WAIT=$((WAIT + 5))
done
[ "${JOB_STATUS:-}" != "1" ] && warn "DB migration still running (check: oc logs job/planner-db-migrate -n $NS)"

# MLflow RBAC
if [ "$MLFLOW_AVAILABLE" = true ]; then
    oc create rolebinding planner-mlflow-integration \
        --clusterrole=mlflow-operator-mlflow-integration \
        --serviceaccount="${NS}:default" \
        -n "$NS" --dry-run=client -o yaml 2>/dev/null | oc apply -f - 2>/dev/null || true
    success "MLflow RBAC configured"
fi

# Wait + Verify
oc rollout status deployment/planner-backend -n "$NS" --timeout=180s 2>/dev/null || \
    warn "Backend rollout timeout"
oc rollout status deployment/planner-frontend -n "$NS" --timeout=120s 2>/dev/null || \
    warn "Frontend rollout timeout"

echo ""
PLANNER_URL="https://inference-planner.${CLUSTER_DOMAIN}"
PLANNER_API="https://inference-planner-api.${CLUSTER_DOMAIN}"

BE_READY=$(oc get deployment planner-backend -n "$NS" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
FE_READY=$(oc get deployment planner-frontend -n "$NS" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

[ "${BE_READY:-0}" -ge 1 ] && echo "  ✅ Backend   : $PLANNER_API" || \
    echo "  ⬚  Backend   : $PLANNER_API (starting...)"
[ "${FE_READY:-0}" -ge 1 ] && echo "  ✅ Frontend  : $PLANNER_URL" || \
    echo "  ⬚  Frontend  : $PLANNER_URL (starting...)"
[ "$MLFLOW_AVAILABLE" = true ] && \
    echo "  ✅ MLflow    : enabled (experiment: inference-design-planner)" || \
    echo "  ⬚  MLflow    : disabled (run sno-enable-all-features-35.sh first)"
echo "  ✅ Database  : ${TARGET_DB}@${PG_FQDN} (reused)"

echo ""
info "LLM:"
echo "  URL   : $LLM_BASE_URL"
echo "  Model : $LLM_MODEL"

echo ""
echo "=============================================="
success "Done!"
echo ""
echo "  MLflow UI:"
echo "    Dashboard → Experiments → inference-design-planner"
echo ""
echo "  If pods show ⬚, wait a minute and check:"
echo "    oc get pods -n $NS"
echo "=============================================="
