#!/usr/bin/env bash
# kind-logs-off — remove telemetry chart and its secrets from the local kind cluster.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"   # script lives in local-setup/kind/, repo root is two levels up
KUBECONFIG_FILE="${REPO_ROOT}/local-setup/kind/kubeconfig"
NAMESPACE="${NAMESPACE:-odg-observability}"
RELEASE="${RELEASE:-telemetry}"
OBSERVED_NS="${OBSERVED_NS:-odg}"
ANNOTATION_KEY="${ANNOTATION_KEY:-otel.io/pod-logs}"

export KUBECONFIG

k() { kubectl --kubeconfig="${KUBECONFIG_FILE}" "$@"; }

helm --kubeconfig="${KUBECONFIG_FILE}" uninstall "${RELEASE}" -n "${NAMESPACE}" --ignore-not-found || true
k delete namespace "${NAMESPACE}" --ignore-not-found
k annotate pods -n "${OBSERVED_NS}" "${ANNOTATION_KEY}-" --all 2>/dev/null || true
# kill port-forward started by logs-on.sh
lsof -i tcp:9200 | grep kubectl | awk 'NR!=1 {print $2}' | xargs kill 2>/dev/null || true

echo "✓ telemetry stack removed"
