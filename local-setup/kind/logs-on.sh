#!/usr/bin/env bash
# kind-logs-on — deploy telemetry chart (otel collector + opensearch) to the local kind cluster.
# Generates a random OpenSearch admin password each run, stores it as a k8s Secret
# that the chart references via extraEnvs. Helm chart stays credential-free in git.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"   # script lives in local-setup/kind/, repo root is two levels up
ODG_OBSERVABILITY="${ODG_OBSERVABILITY:-${REPO_ROOT}/../odg-observability}"
METRICS_OPERATOR_ENABLED="${METRICS_OPERATOR_ENABLED:-1}"
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
if [ "${METRICS_OPERATOR_ENABLED}" = "1" ]; then
  [ -d "${ODG_OBSERVABILITY}/charts/odg-metrics" ] || die "odg-metrics wrapper chart not found at ${ODG_OBSERVABILITY}/charts/odg-metrics (set METRICS_OPERATOR_ENABLED=0 to skip)"
  [ -d "${REPO_ROOT}/../metrics-operator/charts/metrics-operator" ] || die "metrics-operator chart not found at ${REPO_ROOT}/../metrics-operator — file:// dep; checkout expected beside $(basename ${REPO_ROOT})"
fi

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
# Kill any stale pfs FIRST so we don't kill our own upcoming one.
# Kill host processes holding :4317 / :15601 too (uvicorn, stray pf) — they would
# otherwise prevent the new pf from binding.
info "Setting up port-forward to OpenSearch on :9200"
for PORT in 9200 15601 4317; do
  lsof -ti tcp:${PORT} | xargs kill -9 2>/dev/null || true
done
sleep 1
nohup kubectl --kubeconfig="${KUBECONFIG_FILE}" -n "${NAMESPACE}" port-forward svc/opensearch-cluster-master 9200:9200 >/dev/null 2>&1 &
disown
PF_PID=$!
# Sanity check that it actually bound before claiming success
sleep 3
if ! lsof -i tcp:9200 >/dev/null 2>&1; then
  echo "ERROR: port-forward failed to bind on :9200" >&2
  exit 1
fi
ok "opensearch reachable at https://localhost:9200"

# 8. Port-forward dashboards to localhost:15601 (less-used port)
info "Setting up port-forward to OpenSearch Dashboards on :15601"
lsof -ti tcp:15601 | xargs kill -9 2>/dev/null || true
# 8. Port-forward dashboards to localhost:15601 (less-used port)
# Race-fix: kubectl pf exits permanently if the pod's 5601 isn't listening yet.
# Wait for dashboards pod to be Ready BEFORE forwarding.
info "Waiting for Dashboards pod to be Ready"
for i in $(seq 1 90); do
  READY=$(k -n "${NAMESPACE}" get pod -l app.kubernetes.io/name=opensearch-dashboards -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  if [ "${READY}" = "True" ]; then break; fi
  sleep 2
done

info "Setting up port-forward to OpenSearch Dashboards on :15601"
# kubectl port-forward dies permanently on any single connection error from the
# pod ("lost connection to pod"), which OpenSearch Dashboards routinely causes
# when its HTTP server restarts/stalls during startup. Wrap in a restart loop
# that also shrugs off port-in-use races while the previous instance's socket
# is still draining.
nohup bash -c 'while true; do
  kubectl --kubeconfig="'"${KUBECONFIG_FILE}"'" -n '"${NAMESPACE}"' port-forward svc/telemetry-opensearch-dashboards 15601:5601 >>/tmp/pf-dashboards.log 2>&1
  sleep 1
done' >/dev/null 2>&1 &
disown
sleep 4
if ! lsof -i tcp:15601 >/dev/null 2>&1; then
  echo "ERROR: port-forward failed to bind on :15601" >&2
  cat /tmp/pf-dashboards.log >&2 || true
  exit 1
fi
ok "dashboards reachable at http://localhost:15601"

# 8b. Port-forward OTLP gRPC :4317 — lab apps on the host (app.py) push
# traces/metrics/logs to the collector at localhost:4317.
info "Setting up port-forward for OTLP gRPC on :4317"
lsof -ti tcp:4317 | xargs kill -9 2>/dev/null || true
sleep 1
# Expose via telemetry-opentelemetry-collector Service (helm generates this when
# service.enabled=true; name does NOT have '-agent' suffix)
nohup kubectl --kubeconfig="${KUBECONFIG_FILE}" -n "${NAMESPACE}" port-forward svc/telemetry-opentelemetry-collector 4317:4317 >/tmp/pf-otlp.log 2>&1 &
disown
sleep 4
if ! lsof -i tcp:4317 >/dev/null 2>&1; then
  echo "ERROR: port-forward failed to bind on :4317" >&2
  cat /tmp/pf-otlp.log >&2 || true
  exit 1
fi
ok "otlp reachable at grpc://localhost:4317"

# 9. Wait for dashboards to be ready, then create index patterns so Discover works immediately.
# Dashboards needs up to 3-4 minutes on cold start; allow 5 min timeout.
info "Waiting for Dashboards to come up on http://localhost:15601"
READY=false
for i in $(seq 1 150); do
  STATE=$(curl -sku "admin:${ADMIN_PASSWORD}" http://localhost:15601/api/status 2>/dev/null | grep -o '"state":"[a-z]*"' | head -1 || true)
  if [ -n "$STATE" ] && [ "$STATE" != '"state":"unavailable"' ]; then
    ok "Dashboards ready ($STATE)"
    READY=true
    break
  fi
  sleep 2
done
if [ "$READY" != "true" ]; then
  echo "ERROR: Dashboards never became ready after 5 min" >&2
  echo "  pf:   $(lsof -i tcp:15601 | head -2 | tail -1 || echo none)" >&2
  echo "  pod:  $(k -n ${NAMESPACE} get pod -l app.kubernetes.io/name=opensearch-dashboards -o jsonpath='{.items[0].status.phase}' 2>/dev/null)" >&2
  exit 1
fi

# Idempotent create-or-update of index patterns for logs + traces only.
# Metrics no longer land in OpenSearch — they go to Prometheus via scrape.
for NAME in logs-otel-v1 traces-otel-v1; do
  info "Creating index pattern $NAME"
  curl -sku "admin:${ADMIN_PASSWORD}" -X POST "http://localhost:15601/api/saved_objects/index-pattern/${NAME}" \
    -H 'osd-xsrf: true' -H 'Content-Type: application/json' \
    -d "{\"attributes\":{\"title\":\"${NAME}\",\"timeFieldName\":\"@timestamp\"}}" \
    >/dev/null 2>&1 || curl -sku "admin:${ADMIN_PASSWORD}" -X PUT "http://localhost:15601/api/saved_objects/index-pattern/${NAME}" \
    -H 'osd-xsrf: true' -H 'Content-Type: application/json' \
    -d "{\"attributes\":{\"title\":\"${NAME}\",\"timeFieldName\":\"@timestamp\"}}" >/dev/null 2>&1
done
ok "index patterns ready"

# ─── Prometheus port-forward — metrics end up here via scrape-from-collector.
# Collector exposes /metrics on :8889 (prometheus exporter); prometheus scrapes it.
info "Setting up port-forward to Prometheus on :9090"
lsof -ti tcp:9090 | xargs kill -9 2>/dev/null || true
sleep 1
nohup kubectl --kubeconfig="${KUBECONFIG_FILE}" -n "${NAMESPACE}" port-forward svc/telemetry-prometheus-server 9090:80 >/tmp/pf-prometheus.log 2>&1 &
disown
sleep 4
if ! lsof -i tcp:9090 >/dev/null 2>&1; then
  echo "ERROR: port-forward failed to bind on :9090" >&2
  cat /tmp/pf-prometheus.log >&2 || true
  exit 1
fi
ok "prometheus reachable at http://localhost:9090"

echo
# ─── 10. odg-metrics (metrics-operator + CRDs + ODG Metric CRs) — counts ODG
# CRs like BacklogItems and pushes counts via OTLP to the collector (:4317),
# which re-exports them on :8889 where the bundled prometheus scrapes.
if [ "${METRICS_OPERATOR_ENABLED}" = "1" ]; then
  METRICS_OPERATOR_WRAPPER="${ODG_OBSERVABILITY}/charts/odg-metrics"
  [ -d "${METRICS_OPERATOR_WRAPPER}" ] || die "odg-metrics wrapper chart not found at ${METRICS_OPERATOR_WRAPPER}"

  info "helm dep update odg-metrics"
  helm --kubeconfig="${KUBECONFIG_FILE}" dependency update "${METRICS_OPERATOR_WRAPPER}" >/dev/null

  # Collector endpoint is hard-coded in odg-metrics/values.yaml against release
  # 'telemetry' in this namespace — keep it there; simpler than templating here.
  info "helm upgrade --install odg-metrics"
  helm --kubeconfig="${KUBECONFIG_FILE}" upgrade --install odg-metrics "${METRICS_OPERATOR_WRAPPER}" \
    --namespace "${NAMESPACE}" --create-namespace \
    --timeout 5m
  ok "odg-metrics installed — odg_backlog_items_total lands in Prometheus within ~1 min"
  ok "  view: http://localhost:9090/graph?g0.expr=odg_backlog_items_total"
fi

echo
echo "────────────────────────────────────────────────────────────────"
echo "OpenSearch admin credentials (also in: kubectl -n ${NAMESPACE} get secret ${CREDS_SECRET} -o yaml):"
echo "  user:     admin"
echo "  password: ${ADMIN_PASSWORD}"
echo
echo "Next: view logs"
echo "  curl -ku admin:${ADMIN_PASSWORD} https://localhost:9200/logs-otel-v1/_search?pretty"
echo
echo "Logs/Traces UI (OpenSearch Dashboards):"
echo "  http://localhost:15601"
echo "  (login: admin / ${ADMIN_PASSWORD})"
echo "  → Discover → index patterns: 'logs-otel-v1', 'traces-otel-v1'"
echo
echo "Metrics UI (Prometheus):"
echo "  http://localhost:9090"
echo "  → /query — try 'up' or any exported metric name"
echo "  → /targets — verify 'otel-collector' scrape is UP"
echo
echo "OTLP ingestion (for lab apps on this host):"
echo "  grpc://localhost:4317"
echo "    traces  → OpenSearch (index traces-otel-v1, visible in Dashboards)"
echo "    metrics → Prometheus (via collector :8889 scrape)"
echo "    logs from local processes are NOT accepted (collector receives logs via filelog only)"
echo "────────────────────────────────────────────────────────────────"
