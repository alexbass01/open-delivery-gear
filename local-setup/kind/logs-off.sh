#!/usr/bin/env bash
# kind-logs-off — remove the telemetry chart from kind and stop the Mac backends.
# Data in opensearch/prometheus is kept (docker volumes); wipe with:
#   docker compose -f local-setup/kind/telemetry/compose.yml down -v

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
KUBECONFIG_FILE="${KUBECONFIG:-${REPO_ROOT}/local-setup/kind/kubeconfig}"
NAMESPACE="${NAMESPACE:-odg-observability}"
OBSERVED_NS="${OBSERVED_NS:-odg}"

k() { kubectl --kubeconfig="${KUBECONFIG_FILE}" "$@"; }

if [ -f "${KUBECONFIG_FILE}" ]; then
  helm --kubeconfig="${KUBECONFIG_FILE}" uninstall telemetry -n "${NAMESPACE}" --ignore-not-found || true
  # metrics-operator CRDs are created by the operator, not helm — remove explicitly
  # so re-installs don't wedge on half-migrated CRDs.
  k delete crd metrics.open-control-plane.io datasinks.metrics.open-control-plane.io \
    remoteclusteraccesses.metrics.open-control-plane.io federatedclusteraccesses.metrics.open-control-plane.io \
    managedmetrics.metrics.open-control-plane.io federatedmetrics.metrics.open-control-plane.io \
    federatedmanagedmetrics.metrics.open-control-plane.io --ignore-not-found 2>/dev/null || true
  k annotate pods -n "${OBSERVED_NS}" otel.io/pod-logs- --all 2>/dev/null || true
  k delete namespace "${NAMESPACE}" --ignore-not-found || true
else
  echo "▶ no kubeconfig — skipping cluster teardown"
fi

# kill port-forward loops first (they respawn), then any stray children
pkill -f 'kubectl.*port-forward.*8889:8889' 2>/dev/null || true
pkill -f 'kubectl.*port-forward.*4317:4317' 2>/dev/null || true

docker compose -f "${SCRIPT_DIR}/telemetry/compose.yml" down
echo "✓ telemetry removed (data kept; 'docker compose -f ${SCRIPT_DIR}/telemetry/compose.yml down -v' to wipe)"
