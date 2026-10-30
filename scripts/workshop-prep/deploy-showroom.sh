#!/usr/bin/env bash
# Deploy a public Antora workshop to the currently logged-in OpenShift cluster.
# Inspired by https://github.com/ssgkim/showroom-editor (chart + clone/build/content).
#
# Required inputs:
#   export GIT_URL='https://github.com/jingggg-wenn/rhoai-basic-inference-workshop.git'
#   export GIT_REF='main'           # branch, tag, or commit SHA
#   export CONTENT_PATH='content'   # directory containing antora.yml; '.' is allowed
#   curl -fsSL https://raw.githubusercontent.com/YOUR-ID/YOUR-DEPLOY-REPO/main/deploy-showroom.sh | bash
#
# Requirements: Bash, oc, tr, sha256sum, mktemp, date. Existing oc login and
# permissions to create a namespace, Deployments, ConfigMaps, Services and Routes.
# No local Helm, Ansible, Python, Git, container engine, or editor service needed.
# Creates one shared guide, with no embedded terminal and no new user accounts.
# Existing content is read from Git; its remote repository is never changed.
# The generated site uses the standard Showroom theme, as showroom-editor does.
# Source-specific default-site.yml extensions/supplemental UI are not loaded.
set -euo pipefail

showroom_fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for showroom_command in oc tr sha256sum mktemp date; do
  command -v "$showroom_command" >/dev/null 2>&1 || showroom_fail "Required command missing: $showroom_command"
done
: "${GIT_URL:?Set GIT_URL to the workshop Git HTTPS URL}"
: "${GIT_REF:?Set GIT_REF to a branch, tag, or commit}"
: "${CONTENT_PATH:?Set CONTENT_PATH to the directory containing antora.yml}"

[[ "$GIT_URL" =~ ^https://[^/@[:space:]]+/[^[:space:]?#]+$ ]] || showroom_fail 'GIT_URL must be an HTTPS Git URL without embedded credentials or a query string.'
[[ "$GIT_REF" != -* && ! "$GIT_REF" =~ [[:space:]] ]] || showroom_fail 'GIT_REF must not start with a dash or contain whitespace.'
[[ "$CONTENT_PATH" =~ ^[A-Za-z0-9._/-]+$ && "$CONTENT_PATH" != /* && ! "$CONTENT_PATH" =~ (^|/)\.\.(/|$) ]] || showroom_fail 'CONTENT_PATH must be a relative directory without .. segments.'

showroom_user="$(oc whoami)" || showroom_fail 'Log in to the intended cluster with oc login first.'
showroom_api="$(oc whoami --show-server)"
showroom_domain="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
[[ "$showroom_domain" =~ ^[a-zA-Z0-9.-]+$ ]] || showroom_fail 'Could not determine the cluster ingress domain.'
[[ "$(oc auth can-i create namespaces)" == yes ]] || showroom_fail 'This account needs permission to create a Showroom namespace.'

showroom_slug="${GIT_URL%/}"
showroom_slug="${showroom_slug##*/}"
showroom_slug="${showroom_slug%.git}"
showroom_slug="$(printf '%s' "$showroom_slug" | tr '[:upper:]_' '[:lower:]-' | tr -cd 'a-z0-9-')"
showroom_slug="${showroom_slug:0:28}"
showroom_slug="${showroom_slug:-workshop}"
showroom_hash="$(printf '%s\n%s' "$GIT_URL" "$CONTENT_PATH" | sha256sum)"
showroom_hash="${showroom_hash:0:8}"
showroom_ns="showroom-${showroom_slug}-${showroom_hash}"
showroom_host="showroom-${showroom_ns}.${showroom_domain}"
showroom_url="https://${showroom_host}"
showroom_run="$(date -u +%Y%m%dT%H%M%SZ)-${RANDOM}"
showroom_tmp="$(mktemp -d)"
trap 'rm -rf -- "$showroom_tmp"' EXIT

showroom_existing="$(oc get namespace "$showroom_ns" --ignore-not-found -o jsonpath='{.metadata.name}')"
if [[ -n "$showroom_existing" ]]; then
  showroom_owner="$(oc get namespace "$showroom_ns" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}')"
  [[ "$showroom_owner" == showroom-bootstrap ]] || showroom_fail "Namespace $showroom_ns exists and is not managed by this script."
else
  oc create namespace "$showroom_ns"
  oc label namespace "$showroom_ns" app.kubernetes.io/managed-by=showroom-bootstrap
fi

showroom_console_host="$(oc get route console -n openshift-console --ignore-not-found -o jsonpath='{.spec.host}' 2>/dev/null || true)"
showroom_console="https://${showroom_console_host:-console-openshift-console.${showroom_domain}}"
showroom_ai_host="$(oc get route data-science-gateway -n redhat-ods-applications --ignore-not-found -o jsonpath='{.spec.host}' 2>/dev/null || true)"
if [[ -z "$showroom_ai_host" ]]; then
  showroom_ai_host="$(oc get route rhods-dashboard -n redhat-ods-applications --ignore-not-found -o jsonpath='{.spec.host}' 2>/dev/null || true)"
fi
showroom_ai_url=""
[[ -z "$showroom_ai_host" ]] || showroom_ai_url="https://${showroom_ai_host}/"

cat > "$showroom_tmp/clone.sh" <<'CLONE_SCRIPT'
#!/bin/sh
set -eu
repo_dir="${SHOWROOM_REPO_DIR:-/showroom/repo}"
mkdir -p "$repo_dir"
git -c safe.directory="$repo_dir" -C "$repo_dir" init --quiet
if git -c safe.directory="$repo_dir" -C "$repo_dir" remote get-url origin >/dev/null 2>&1; then
  git -c safe.directory="$repo_dir" -C "$repo_dir" remote set-url origin "$GIT_URL"
else
  git -c safe.directory="$repo_dir" -C "$repo_dir" remote add origin "$GIT_URL"
fi
git -c safe.directory="$repo_dir" -C "$repo_dir" fetch --quiet --depth=1 origin "$GIT_REF"
git -c safe.directory="$repo_dir" -C "$repo_dir" checkout --quiet --force --detach FETCH_HEAD
test -f "$repo_dir/$CONTENT_PATH/antora.yml" || { echo 'CONTENT_PATH/antora.yml does not exist.' >&2; exit 1; }
test -f "$repo_dir/$CONTENT_PATH/modules/ROOT/pages/index.adoc" || { echo 'Expected modules/ROOT/pages/index.adoc in the selected Antora component.' >&2; exit 1; }
echo '[clone] Workshop content is ready.'
CLONE_SCRIPT

cat > "$showroom_tmp/site.yml" <<'SITE_PLAYBOOK'
site:
  title: Workshop
  start_page: workshop::index.adoc
content:
  sources:
    - url: /showroom/repo
      branches: HEAD
      start_path: content
ui:
  bundle:
    url: https://github.com/rhpds/rhdp_showroom_theme/releases/download/latest/ui-bundle.zip
    snapshot: true
runtime:
  cache_dir: /tmp/.cache/antora
output:
  dir: /showroom/www
SITE_PLAYBOOK

cat > "$showroom_tmp/build.sh" <<'BUILD_SCRIPT'
#!/bin/bash
set -euo pipefail
export SHOWROOM_BUILD_REPO="${SHOWROOM_REPO_DIR:-/showroom/repo}"
export SHOWROOM_OUTPUT_DIR="${SHOWROOM_OUTPUT_DIR:-/showroom/www}"
export SHOWROOM_CACHE_DIR="${SHOWROOM_CACHE_DIR:-/tmp/.cache/antora}"
showroom_config_dir="${SHOWROOM_CONFIG_DIR:-/config}"
export SHOWROOM_DESCRIPTOR="$SHOWROOM_BUILD_REPO/$CONTENT_PATH/antora.yml"
cd "$SHOWROOM_BUILD_REPO"
# As in showroom-editor, normalize the component identity in the Pod's worktree.
yq -i '
  .name = "workshop" | .version = "main" |
  .asciidoc.attributes *= {
    "user": strenv(SHOWROOM_USER),
    "username": strenv(SHOWROOM_USER),
    "password": "Use the credentials provided by your instructor",
    "openshift_cluster_ingress_domain": strenv(CLUSTER_DOMAIN),
    "openshift_api_url": strenv(CLUSTER_API_URL),
    "openshift_api_server_url": strenv(CLUSTER_API_URL),
    "openshift_cluster_console_url": strenv(CONSOLE_URL),
    "page-openshift_cluster_console_url": strenv(CONSOLE_URL),
    "login_command": ("oc login -u " + strenv(SHOWROOM_USER) + " " + strenv(CLUSTER_API_URL))
  }
' "$SHOWROOM_DESCRIPTOR"
if [[ -n "${RHOAI_URL:-}" ]]; then
  yq -i '.asciidoc.attributes.rhoai_dashboard_url = strenv(RHOAI_URL) | .asciidoc.attributes.page-rhoai_dashboard_url = strenv(RHOAI_URL)' "$SHOWROOM_DESCRIPTOR"
fi
cp "$showroom_config_dir/site.yml" ./site.yml
yq -i '
  .site.title = (load(strenv(SHOWROOM_DESCRIPTOR)).title // "Workshop") |
  .site.url = strenv(SHOWROOM_URL) |
  .content.sources[0].url = strenv(SHOWROOM_BUILD_REPO) |
  .content.sources[0].start_path = strenv(CONTENT_PATH) |
  .runtime.cache_dir = strenv(SHOWROOM_CACHE_DIR) |
  .output.dir = strenv(SHOWROOM_OUTPUT_DIR)
' ./site.yml
antora --stacktrace ./site.yml
test -s "$SHOWROOM_OUTPUT_DIR/workshop/main/index.html"
echo '[build] Showroom HTML is ready.'
BUILD_SCRIPT

cat > "$showroom_tmp/ui-config.yml" <<UI_CONFIG
type: showroom
default_width: 40
persist_url_state: true
antora:
  dir: www
  name: www
  modules:
    - name: workshop/main/index
tabs:
  - name: OpenShift Console
    url: "$showroom_console"
    external: true
UI_CONFIG
if [[ -n "$showroom_ai_url" ]]; then
  cat >> "$showroom_tmp/ui-config.yml" <<AI_TAB
  - name: OpenShift AI Dashboard
    url: "$showroom_ai_url"
    external: true
AI_TAB
fi

oc create configmap showroom-config -n "$showroom_ns" --dry-run=client -o yaml \
  --from-literal=GIT_URL="$GIT_URL" \
  --from-literal=GIT_REF="$GIT_REF" \
  --from-literal=CONTENT_PATH="$CONTENT_PATH" \
  --from-literal=CLUSTER_DOMAIN="$showroom_domain" \
  --from-literal=CLUSTER_API_URL="$showroom_api" \
  --from-literal=CONSOLE_URL="$showroom_console" \
  --from-literal=RHOAI_URL="$showroom_ai_url" \
  --from-literal=SHOWROOM_USER="$showroom_user" \
  --from-literal=SHOWROOM_URL="$showroom_url" \
  --from-file=clone.sh="$showroom_tmp/clone.sh" \
  --from-file=build.sh="$showroom_tmp/build.sh" \
  --from-file=site.yml="$showroom_tmp/site.yml" \
  --from-file=ui-config.yml="$showroom_tmp/ui-config.yml" > "$showroom_tmp/configmap.yaml"
oc apply -f "$showroom_tmp/configmap.yaml"

cat > "$showroom_tmp/workload.yaml" <<WORKLOAD
apiVersion: apps/v1
kind: Deployment
metadata:
  name: showroom
  namespace: $showroom_ns
  labels: {app.kubernetes.io/managed-by: showroom-bootstrap}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector:
    matchLabels: {app.kubernetes.io/name: showroom}
  template:
    metadata:
      labels: {app.kubernetes.io/name: showroom}
      annotations: {showroom-bootstrap/run: "$showroom_run"}
    spec:
      automountServiceAccountToken: false
      initContainers:
        - name: clone
          image: quay.io/rhpds/git-cloner:v1.1.5
          command: [sh, /config/clone.sh]
          env: &workshop-env
            - name: GIT_URL
              valueFrom: {configMapKeyRef: {name: showroom-config, key: GIT_URL}}
            - name: GIT_REF
              valueFrom: {configMapKeyRef: {name: showroom-config, key: GIT_REF}}
            - name: CONTENT_PATH
              valueFrom: {configMapKeyRef: {name: showroom-config, key: CONTENT_PATH}}
            - name: CLUSTER_DOMAIN
              valueFrom: {configMapKeyRef: {name: showroom-config, key: CLUSTER_DOMAIN}}
            - name: CLUSTER_API_URL
              valueFrom: {configMapKeyRef: {name: showroom-config, key: CLUSTER_API_URL}}
            - name: CONSOLE_URL
              valueFrom: {configMapKeyRef: {name: showroom-config, key: CONSOLE_URL}}
            - name: RHOAI_URL
              valueFrom: {configMapKeyRef: {name: showroom-config, key: RHOAI_URL}}
            - name: SHOWROOM_USER
              valueFrom: {configMapKeyRef: {name: showroom-config, key: SHOWROOM_USER}}
            - name: SHOWROOM_URL
              valueFrom: {configMapKeyRef: {name: showroom-config, key: SHOWROOM_URL}}
            - {name: GIT_TERMINAL_PROMPT, value: "0"}
          volumeMounts: &build-mounts
            - {name: config, mountPath: /config, readOnly: true}
            - {name: work, mountPath: /showroom/repo, subPath: repo}
            - {name: work, mountPath: /showroom/www, subPath: www}
          resources: &build-resources
            requests: {cpu: 100m, memory: 256Mi}
            limits: {cpu: "1", memory: 1Gi}
        - name: build
          image: quay.io/rhpds/antora:v1.3.0
          command: [bash, /config/build.sh]
          env: *workshop-env
          volumeMounts: *build-mounts
          resources: *build-resources
      containers:
        - name: content
          image: quay.io/rhpds/showroom-content:v1.4.3
          env:
            - {name: ANTORA_PLAYBOOK, value: site.yml}
            - {name: ZT_UI_ENABLED, value: "true"}
            - {name: ZT_BUNDLE, value: "https://github.com/rhpds/nookbag/releases/download/nookbag-v0.5.1/nookbag-v0.5.1.zip"}
            - name: SHOWROOM_UI_CONFIG
              valueFrom: {configMapKeyRef: {name: showroom-config, key: ui-config.yml}}
          ports: [{name: http, containerPort: 8000}]
          startupProbe:
            httpGet: {path: /, port: http}
            periodSeconds: 5
            failureThreshold: 60
          readinessProbe:
            httpGet: {path: /, port: http}
            periodSeconds: 10
          livenessProbe:
            httpGet: {path: /, port: http}
            periodSeconds: 20
          volumeMounts:
            - {name: work, mountPath: /showroom/repo, subPath: repo}
            - {name: work, mountPath: /showroom/www, subPath: www}
          resources:
            requests: {cpu: 10m, memory: 64Mi}
            limits: {cpu: 200m, memory: 256Mi}
      volumes:
        - name: config
          configMap: {name: showroom-config}
        - name: work
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: showroom
  namespace: $showroom_ns
spec:
  selector: {app.kubernetes.io/name: showroom}
  ports: [{name: http, port: 8080, targetPort: http}]
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: showroom
  namespace: $showroom_ns
spec:
  host: "$showroom_host"
  to: {kind: Service, name: showroom}
  port: {targetPort: http}
  tls: {termination: edge, insecureEdgeTerminationPolicy: Redirect}
WORKLOAD

printf '\nDeploying %s @ %s (%s)\nNamespace: %s\n' "$GIT_URL" "$GIT_REF" "$CONTENT_PATH" "$showroom_ns"
oc apply -f "$showroom_tmp/workload.yaml"
if ! oc rollout status deployment/showroom -n "$showroom_ns" --timeout=600s; then
  printf '\nDeployment did not become ready. Inspect:\n' >&2
  printf '  oc get pods -n %s\n' "$showroom_ns" >&2
  printf '  oc logs -n %s deployment/showroom -c clone\n' "$showroom_ns" >&2
  printf '  oc logs -n %s deployment/showroom -c build\n' "$showroom_ns" >&2
  printf '  oc logs -n %s deployment/showroom -c content\n' "$showroom_ns" >&2
  exit 1
fi
showroom_actual_host="$(oc get route showroom -n "$showroom_ns" -o jsonpath='{.spec.host}')"
printf '\nShowroom is ready: https://%s\nNamespace: %s\n' "$showroom_actual_host" "$showroom_ns"
