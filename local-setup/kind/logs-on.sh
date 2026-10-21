#!/usr/bin/env bash
# kind-logs-on — local telemetry: backends on your Mac (docker compose) + the
# odg-observability telemetry chart (collector + metrics-operator) in kind.
#
#   backends (Mac, Docker)                  kind cluster (odg-local)
#   ┌──────────────────────────┐            ┌─────────────────────────────────┐
#   │ prometheus   :9090       │──scrape───►│ localhost:8889 (kubectl pf)     │──► otel-collector :8889
#   │ opensearch   :9200       │◄──push────│ otel-collector (daemonset)      │
#   │ dashboards   :5601       │            │   filelog + k8sattributes       │
#   └──────────────────────────┘            │   metrics-operator → ODG counts │
#                                           └─────────────────────────────────┘
#
# Logs reach opensearch via host.docker.internal (Docker Desktop host gateway).
# No logins anywhere — the docker backends run with security plugins disabled.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
ODG_OBSERVABILITY="${ODG_OBSERVABILITY:-${REPO_ROOT}/../odg-observability}"
KUBECONFIG_FILE="${KUBECONFIG:-${REPO_ROOT}/local-setup/kind/kubeconfig}"
NAMESPACE="${NAMESPACE:-odg-observability}"   # chart install location
OBSERVED_NS="${OBSERVED_NS:-odg}"             # where ODG pods live
RELEASE=telemetry
CHART="${ODG_OBSERVABILITY}/charts/telemetry"
BACKENDS="${SCRIPT_DIR}/telemetry"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "▶ $*"; }
ok()   { echo "✓ $*"; }

command -v docker  >/dev/null || die "docker not found"
command -v helm    >/dev/null || die "helm not found"
command -v kubectl >/dev/null || die "kubectl not found"
command -v curl    >/dev/null || die "curl not found"
[ -f "${KUBECONFIG_FILE}" ] || die "kubeconfig not found at ${KUBECONFIG_FILE} — run 'make kind-up' first"
[ -d "${CHART}" ] || die "telemetry chart not found at ${CHART} — checkout odg-observability beside $(basename "${REPO_ROOT}")"

k() { kubectl --kubeconfig="${KUBECONFIG_FILE}" "$@"; }

# ─── 1. Backends on the Mac ──────────────────────────────────────────────────
info "1/5  backends (docker compose)"
docker compose -f "${BACKENDS}/compose.yml" up -d >/dev/null
for i in $(seq 1 60); do
  curl -s -o /dev/null localhost:9200 \
    && curl -s -o /dev/null localhost:9090/-/ready \
    && break
  sleep 2
  [ "$i" = 60 ] && die "backends not ready after 2m — docker compose -f ${BACKENDS}/compose.yml logs"
done
# Data view (index pattern) so Discover works out of the box. 2xx = ok.
for i in $(seq 1 90); do
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST 'localhost:5601/api/saved_objects/index-pattern/logs-otel-v1?overwrite=true' \
    -H 'osd-xsrf: true' -H 'Content-Type: application/json' \
    -d '{"attributes":{"title":"logs-otel-v1","timeFieldName":"@timestamp","name":"otel logs"}}')
  [[ "$code" =~ ^2 ]] && break
  sleep 2
done
[[ "$code" =~ ^2 ]] || info "WARN: dashboards not ready — data view not created (create manually in OS Dashboards)"
ok "backends up (prometheus :9090, opensearch :9200, dashboards :5601)"

# ─── 2. Chart in kind ────────────────────────────────────────────────────────
info "2/5  helm upgrade --install ${RELEASE} (backend=opensearch, host.docker.internal:9200)"
helm --kubeconfig="${KUBECONFIG_FILE}" dependency update "${CHART}" >/dev/null
helm --kubeconfig="${KUBECONFIG_FILE}" upgrade --install "${RELEASE}" "${CHART}" \
  --namespace "${NAMESPACE}" --create-namespace \
  --set backend=opensearch \
  --set opensearch.endpoint=http://host.docker.internal:9200 \
  --set observedNamespace="${OBSERVED_NS}" \
  --timeout 5m || die "helm install failed — see above. Rerun is safe (upgrade --install)."

# ─── 3. Opt-in log annotation (pods restarted later must re-apply this) ──────
info "3/5  annotate odg pods with ${ANNOTATION_KEY:-otel.io/pod-logs}=true"
k -n "${OBSERVED_NS}" annotate pods -l app=delivery-service otel.io/pod-logs=true --overwrite \
  || info "WARN: no delivery-service pods yet — annotate later or set annotationKey=\"\""

info "    waiting for collector daemonset"
COLLECTOR_SVC="${RELEASE}-opentelemetry-collector"
k -n "${NAMESPACE}" rollout status ds/${COLLECTOR_SVC}-agent --timeout=180s \
  || die "collector not ready — kubectl -n ${NAMESPACE} logs ds/${COLLECTOR_SVC}-agent"

# ─── 4. Port-forwards ────────────────────────────────────────────────────────
info "4/5  port-forwards: :8889 (prometheus scrape), :4317 (OTLP for host apps)"
pf() { # pf <local:remote> <svc> <logfile>
  pkill -f "kubectl.*port-forward.*${1}" 2>/dev/null || true; sleep 1
  nohup bash -c '
    while true; do
      kubectl --kubeconfig="'"${KUBECONFIG_FILE}"'" -n '"${NAMESPACE}"' port-forward svc/'"$2"' '"$1"' >>'"$3"' 2>&1
      sleep 2
    done' >/dev/null 2>&1 &
  disown
  sleep 3
  lsof -i tcp:"${1%%:*}" >/dev/null 2>&1 || die "port-forward ${1} for ${2} failed — see $3"
}
pf 8889:8889 "${COLLECTOR_SVC}" /tmp/pf-otel-metrics.log
pf 4317:4317 "${COLLECTOR_SVC}" /tmp/pf-otlp.log
ok "port-forwards up (self-healing loops)"

# ─── 5. Summary ──────────────────────────────────────────────────────────────
cat <<EOF

  UP ✓  (no logins anywhere — security plugins disabled)

  METRICS — http://localhost:9090 (Graph tab)
    k8s_pods_running                                               # value = pod count, one series per resource_namespace
    sum(k8s_pods_running)                                          # cluster-wide total
    k8s_pods_running{resource_namespace="odg"}                     # odg namespace only
    avg(system_cpu_utilization_ratio)                              # host CPU across cores
    Status → Targets: 'otel-collector' should be UP within ~30s

  LOGS — http://localhost:5601 (Discover → 'logs-otel-v1', no password)
    only pods annotated otel.io/pod-logs=true ship logs (delivery-service done above)

  PUSH from host apps — grpc://localhost:4317 (traces/metrics)

  Verify: curl -s localhost:9200/logs-otel-v1/_count
          curl -s 'localhost:9090/api/v1/query?query=k8s_pods_running'

  Down: make kind-logs-off (or ./local-setup/kind/logs-off.sh)
EOF
