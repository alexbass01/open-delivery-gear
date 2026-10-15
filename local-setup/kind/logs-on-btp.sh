#!/usr/bin/env bash
# kind-logs-on-btp — deploy telemetry chart with backend=btp (mTLS to Cloud Logging).
# Prereq: kind-logs-btp-creds must have created the btp-otlp-credentials secret.
# No OpenSearch, no dashboards, no port-forward of either. The collector ships
# everything to BTP. Metrics also go to the local Prometheus (still installed).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
ODG_OBSERVABILITY="${ODG_OBSERVABILITY:-${REPO_ROOT}/../odg-observability}"
METRICS_OPERATOR_ENABLED="${METRICS_OPERATOR_ENABLED:-1}"
KUBECONFIG_FILE="${REPO_ROOT}/local-setup/kind/kubeconfig"
NAMESPACE="${NAMESPACE:-odg-observability}"
RELEASE="${RELEASE:-telemetry}"
SECRET_NAME="${SECRET_NAME:-btp-otlp-credentials}"
VALUES_FILE="${REPO_ROOT}/local-setup/kind/values/collector-btp.yaml"
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

k() { kubectl --kubeconfig="${KUBECONFIG_FILE}" "$@"; }

# 1. Prereq: btp-otlp-credentials must already exist (run kind-logs-btp-creds first)
k -n "${NAMESPACE}" get secret "${SECRET_NAME}" >/dev/null 2>&1 \
  || die "secret ${NAMESPACE}/${SECRET_NAME} missing — run 'make kind-logs-btp-creds' first"

# 2. Pull chart dependencies
info "helm dep update"
helm --kubeconfig="${KUBECONFIG_FILE}" dependency update "${ODG_OBSERVABILITY}/charts/telemetry" >/dev/null

# 3. Upgrade with btp values
info "helm upgrade --install ${RELEASE} (backend=btp)"
helm --kubeconfig="${KUBECONFIG_FILE}" upgrade --install "${RELEASE}" "${ODG_OBSERVABILITY}/charts/telemetry" \
  -f "${VALUES_FILE}" \
  --namespace "${NAMESPACE}" --create-namespace \
  --timeout 5m

ok "helm chart upgraded"

# Wait for collector daemonset and prometheus to be ready before port-forwarding.
info "Waiting for OTel collector to be ready"
k -n "${NAMESPACE}" rollout status daemonset/${RELEASE}-opentelemetry-collector-agent --timeout=3m
info "Waiting for Prometheus to be ready"
k -n "${NAMESPACE}" rollout status deployment/${RELEASE}-prometheus-server --timeout=3m
ok "pods ready"

# 4. Annotate observed pods
info "Annotating pods in ns=${OBSERVED_NS} matching ${ANNOTATION_SELECTOR} with ${ANNOTATION_KEY}=true"
k -n "${OBSERVED_NS}" annotate pods -l "${ANNOTATION_SELECTOR}" \
  "${ANNOTATION_KEY}=true" --overwrite

ok "pods annotated"

# 5. Port-forward prometheus for inspecting metrics that also went to BTP
info "Setting up port-forward to Prometheus on :9090"
lsof -ti tcp:9090 | xargs kill -9 2>/dev/null || true
sleep 1
nohup kubectl --kubeconfig="${KUBECONFIG_FILE}" -n "${NAMESPACE}" port-forward svc/telemetry-prometheus-server 9090:80 >/tmp/pf-prometheus.log 2>&1 &
disown
sleep 4
if ! lsof -i tcp:9090 >/dev/null 2>&1; then
  echo "WARN: prometheus port-forward failed to bind on :9090 (continuing)" >&2
else
  ok "prometheus reachable at http://localhost:9090"
fi

# ─── 6. odg-metrics (metrics-operator + CRDs + ODG Metric CRs) — same wiring
# as logs-on.sh standalone path. Counts ODG CRs like BacklogItems via OTel
# gauge pushed to the collector, which serves them to Prometheus on :8889.
if [ "${METRICS_OPERATOR_ENABLED}" = "1" ]; then
  METRICS_OPERATOR_WRAPPER="${ODG_OBSERVABILITY}/charts/odg-metrics"
  [ -d "${METRICS_OPERATOR_WRAPPER}" ] || die "odg-metrics wrapper chart not found at ${METRICS_OPERATOR_WRAPPER}"

  info "helm dep update odg-metrics"
  helm --kubeconfig="${KUBECONFIG_FILE}" dependency update "${METRICS_OPERATOR_WRAPPER}" >/dev/null

  info "helm upgrade --install odg-metrics"
  helm --kubeconfig="${KUBECONFIG_FILE}" upgrade --install odg-metrics "${METRICS_OPERATOR_WRAPPER}" \
    --namespace "${NAMESPACE}" --create-namespace \
    --timeout 5m
  ok "odg-metrics installed"
fi

# 6b. Port-forward OTLP gRPC for local dev apps pushing to the collector
info "Setting up port-forward for OTLP gRPC on :4317"
lsof -ti tcp:4317 | xargs kill -9 2>/dev/null || true
sleep 1
nohup kubectl --kubeconfig="${KUBECONFIG_FILE}" -n "${NAMESPACE}" port-forward svc/telemetry-opentelemetry-collector 4317:4317 >/tmp/pf-otlp.log 2>&1 &
disown
sleep 4
if ! lsof -i tcp:4317 >/dev/null 2>&1; then
  echo "ERROR: port-forward failed to bind on :4317" >&2
  cat /tmp/pf-otlp.log >&2 || true
  exit 1
fi
ok "otlp reachable at grpc://localhost:4317"

echo
echo "────────────────────────────────────────────────────────────────"
echo "BTP backend active — logs + traces ship to Cloud Logging via mTLS."
echo
echo "Watch collector logs for connection issues:"
echo "  kubectl --kubeconfig=${KUBECONFIG_FILE} -n ${NAMESPACE} logs -l app.kubernetes.io/component=agent-collector -f"
echo
echo "Prometheus UI (still available — metrics are also scraped from the collector):"
echo "  http://localhost:9090"
echo "  → /targets — 'otel-collector' should be UP"
echo "  → /query — try 'up' or any exported metric"
echo
echo "OTLP ingestion (for lab apps on this host):"
echo "  grpc://localhost:4317"
echo "    traces  → BTP Cloud Logging"
echo "    metrics → BTP + local Prometheus (scraped)"
echo "    logs from local processes are NOT accepted (collector receives logs via filelog only)"
echo "────────────────────────────────────────────────────────────────"
