#!/usr/bin/env bash
# Deploy the observability stack (prometheus-operator + kube-state-metrics) from a local
# odg-observability checkout into the running odg-local kind cluster.
#
# Usage:
#   ./deploy-observability.sh [--observability-repo <path>] [--namespace <ns>]
#
#   OBSERVABILITY_REPO=/path/to/checkout ./deploy-observability.sh
#
# Defaults:
#   --observability-repo  ~/code/github.com/odg-observability
#   --namespace           odg
#
# After deploy, Prometheus is port-forwarded to http://localhost:9090/graph

set -euo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
. "${SCRIPT_DIR}/helm-helpers.sh"

# Default: look for the observability repo next to open-delivery-gear
DEFAULT_OBSERVABILITY_REPO="${HOME}/code/github.com/odg-observability"

OBSERVABILITY_REPO="${OBSERVABILITY_REPO:-${DEFAULT_OBSERVABILITY_REPO}}"
NAMESPACE="${NAMESPACE:-odg}"
RELEASE_NAME="prometheus-operator"
CHART_PATH="${OBSERVABILITY_REPO}/charts/prometheus-operator"

parse_flags() {
  while test $# -gt 0; do
    case "$1" in
    --observability-repo)
      shift; OBSERVABILITY_REPO="$1"; CHART_PATH="${OBSERVABILITY_REPO}/charts/prometheus-operator"
      ;;
    --namespace)
      shift; NAMESPACE="$1"
      ;;
    esac
    shift
  done
}

parse_flags "$@"

if [ ! -d "${CHART_PATH}" ]; then
  echo "ERROR: Chart not found at ${CHART_PATH}"
  echo "       Set --observability-repo or export OBSERVABILITY_REPO to point at the odg-observability checkout."
  exit 1
fi

echo ">>> Using observability chart from: ${CHART_PATH}"
echo ">>> Checking for local override files in ${SCRIPT_DIR}"
build_helm_override_args "${SCRIPT_DIR}"

kubectl config set-context --current --namespace="${NAMESPACE}"

echo ">>> Running helm dependency build for ${CHART_PATH}"
helm dependency build "${CHART_PATH}"

echo ">>> Applying CRDs from ${CHART_PATH}/crds"
kubectl apply --server-side --force-conflicts -f "${CHART_PATH}/crds/"

HELM_SET_ARGS=(
  --set host="localhost"
  --set image.repository="quay.io/prometheus-operator/prometheus-operator"
  --set image.tag="v0.94.1"
  --set prometheus.image.repository="docker.io/prom/prometheus"
  --set prometheus.image.tag="v3.15.0-distroless"
  --set "prometheus-config-reloader.image.repository=quay.io/prometheus-operator/prometheus-config-reloader"
  --set "prometheus-config-reloader.image.tag=v0.94.1"
)

echo ">>> Deploying ${RELEASE_NAME} to namespace ${NAMESPACE}"
helm template "${RELEASE_NAME}" "${CHART_PATH}" \
  --namespace "${NAMESPACE}" \
  --skip-crds \
  "${HELM_SET_ARGS[@]}" \
  "${HELM_OVERRIDE_ARGS[@]}" \
  | kubectl apply --server-side --force-conflicts -n "${NAMESPACE}" -f -

echo ">>> Waiting for ${RELEASE_NAME} rollout"
kubectl rollout status deployment "${RELEASE_NAME}" -n "${NAMESPACE}" --timeout=120s

echo ">>> Waiting for kube-state-metrics rollout"
kubectl rollout status deployment "${RELEASE_NAME}-kube-state-metrics" -n "${NAMESPACE}" --timeout=120s

echo ">>> ${RELEASE_NAME} deployed successfully"

echo ">>> Port-forwarding Prometheus to http://localhost:9090/graph"
lsof -i tcp:9090 | grep kubectl | awk 'NR!=1 {print $2}' | xargs kill 2>/dev/null || true
kubectl port-forward service/prometheus-operated 9090:9090 -n "${NAMESPACE}" > /dev/null &
