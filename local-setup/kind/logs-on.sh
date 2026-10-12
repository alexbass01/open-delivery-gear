#!/usr/bin/env bash
# kind-logs-on — deploy telemetry chart (otel collector + opensearch) to the local kind cluster.
# Generates a random OpenSearch admin password each run, stores it as a k8s Secret
# that the chart references via extraEnvs. Helm chart stays credential-free in git.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"   # script lives in local-setup/kind/, repo root is two levels up
ODG_OBSERVABILITY="${ODG_OBSERVABILITY:-${REPO_ROOT}/../odg-observability}"
# Always target the kind cluster's kubeconfig explicitly — don't inherit caller's
# multi-file KUBECONFIG (kubectl chokes on ":"-separated values via [--kubeconfig])
KUBECONFIG_FILE="${REPO_ROOT}/local-setup/kind/kubeconfig"
NAMESPACE="${NAMESPACE:-odg-observability}"
RELEASE="${RELEASE:-telemetry}"
CREDS_SECRET="${RELEASE}-opensearch-credentials"
VALUES_FILE="${REPO_ROOT}/local-setup/kind/values/collector.yaml"
OBSERVED_NS="${OBSERVED_NS:-odg}"
ANNOTATION_KEY="${ANNOTATION_KEY:-otel.io/pod-logs}"
ANNOTATION_SELECTOR="${ANNOTATION_SELECTOR:-app=delivery-service}"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "▶ $*"; }
ok()   { echo "✓ $*"; }

command -v kubectl >/dev/null || die "kubectl not found"
command -v helm    >/dev/null || die "helm not found"
[ -f "${KUBECONFIG_FILE}" ] || die "kubeconfig not found at ${KUBECONFIG_FILE} — run 'make kind-up' first"
[ -d "${ODG_OBSERVABILITY}/charts/telemetry" ] || die "telemetry chart not found at ${ODG_OBSERVABILITY}/charts/telemetry"

alias k8s="kubectl --kubeconfig=${KUBECONFIG_FILE}"
k() { kubectl --kubeconfig="${KUBECONFIG_FILE}" "$@"; }

# 1. Namespace
info "Ensuring namespace ${NAMESPACE}"
k create namespace "${NAMESPACE}" --dry-run=client -o yaml | k apply -f -

# 2. Random password → k8s Secret (chart reads it via extraEnvs secretKeyRef)
if k -n "${NAMESPACE}" get secret "${CREDS_SECRET}" >/dev/null 2>&1; then
  info "Secret ${CREDS_SECRET} exists; reusing"
  ADMIN_PASSWORD=$(k -n "${NAMESPACE}" get secret "${CREDS_SECRET}" -o jsonpath='{.data.opensearch-password}' | base64 -d)
else
  ADMIN_PASSWORD="$(head -c 200 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 20)Os1!"
  info "Creating secret ${CREDS_SECRET} (fresh random password)"
  k -n "${NAMESPACE}" create secret generic "${CREDS_SECRET}" \
    --from-literal=opensearch-username=admin \
    --from-literal=opensearch-password="${ADMIN_PASSWORD}"
fi

# 3. Pull chart dependencies
info "helm dep update"
helm --kubeconfig="${KUBECONFIG_FILE}" dependency update "${ODG_OBSERVABILITY}/charts/telemetry" >/dev/null

# 4. Upgrade
info "helm upgrade --install ${RELEASE}"
helm --kubeconfig="${KUBECONFIG_FILE}" upgrade --install "${RELEASE}" "${ODG_OBSERVABILITY}/charts/telemetry" \
  -f "${VALUES_FILE}" \
  --namespace "${NAMESPACE}" --create-namespace \
  --timeout 5m

ok "helm chart upgraded"

# 5. Annotate observed pods for opt-in collection
info "Annotating pods in ns=${OBSERVED_NS} matching ${ANNOTATION_SELECTOR} with ${ANNOTATION_KEY}=true"
k -n "${OBSERVED_NS}" annotate pods -l "${ANNOTATION_SELECTOR}" \
  "${ANNOTATION_KEY}=true" --overwrite

ok "pods annotated"

# 6. Wait opensearch ready (max 3 min)
info "Waiting for OpenSearch pod"
k -n "${NAMESPACE}" wait --for=condition=ready pod \
  -l app.kubernetes.io/component=opensearch-cluster-master --timeout=180s || \
  info "opensearch pod not ready yet — check 'kubectl -n ${NAMESPACE} logs opensearch-cluster-master-0'"

# 7. Port-forward opensearch to localhost:9200 (pattern from kind-up.sh for delivery-service)
# Kill any stale pfs FIRST so we don't kill our own upcoming one
info "Setting up port-forward to OpenSearch on :9200"
lsof -ti tcp:9200 | xargs kill -9 2>/dev/null || true
sleep 1
k -n "${NAMESPACE}" port-forward svc/opensearch-cluster-master 9200:9200 >/dev/null 2>&1 &
PF_PID=$!
# Sanity check that it actually bound before claiming success
sleep 3
if ! lsof -i tcp:9200 >/dev/null 2>&1; then
  echo "ERROR: port-forward failed to bind on :9200" >&2
  exit 1
fi
ok "opensearch reachable at https://localhost:9200"

echo
echo "────────────────────────────────────────────────────────────────"
echo "OpenSearch admin credentials (also in: kubectl -n ${NAMESPACE} get secret ${CREDS_SECRET} -o yaml):"
echo "  user:     admin"
echo "  password: ${ADMIN_PASSWORD}"
echo
echo "Next: view logs"
echo "  curl -ku admin:${ADMIN_PASSWORD} https://localhost:9200/logs-otel-v1/_search?pretty"
echo "────────────────────────────────────────────────────────────────"
