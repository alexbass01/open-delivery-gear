#!/usr/bin/env bash
# kind-logs-btp-creds — create/refresh the btp-otlp-credentials k8s Secret from
# a BTP Cloud Logging service-binding JSON (the blob you download from BTP cockpit).
# Idempotent. Safe to re-run when the binding rotates.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
KUBECONFIG_FILE="${REPO_ROOT}/local-setup/kind/kubeconfig"
NAMESPACE="${NAMESPACE:-odg-observability}"
SECRET_NAME="${SECRET_NAME:-btp-otlp-credentials}"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "▶ $*"; }
ok()   { echo "✓ $*"; }

usage() {
  cat <<EOF
Usage: $0 [--json PATH] [--namespace NS] [--secret NAME]

Flags:
  --json PATH       Path to the BTP Cloud Logging binding JSON
                    (default: \$BTP_CLS_JSON, else ~/Downloads/cloud-logging-alextest.json)
  --namespace NS    K8s namespace for the secret (default: odg-observability)
  --secret NAME     Secret name (default: btp-otlp-credentials; matches values/btp.certsSecret)

Env vars honored instead of flags:
  BTP_CLS_JSON     same as --json
  NAMESPACE        same as --namespace
  SECRET_NAME      same as --secret
EOF
}

# ── parse args ──────────────────────────────────────────────────────────────
BINDING_JSON="${BTP_CLS_JSON:-${HOME}/Downloads/cloud-logging-alextest.json}"
while [ $# -gt 0 ]; do
  case "$1" in
    --json)       BINDING_JSON="$2"; shift 2 ;;
    --namespace)  NAMESPACE="$2";    shift 2 ;;
    --secret)     SECRET_NAME="$2";  shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) die "unknown flag: $1 (see --help)" ;;
  esac
done

command -v jq      >/dev/null || die "jq not found"
command -v kubectl >/dev/null || die "kubectl not found"
[ -f "${KUBECONFIG_FILE}" ] || die "kubeconfig not found at ${KUBECONFIG_FILE} — run 'make kind-up' first"
[ -f "${BINDING_JSON}" ]   || die "binding JSON not found at ${BINDING_JSON}"

k() { kubectl --kubeconfig="${KUBECONFIG_FILE}" "$@"; }

# ── extract required fields from the binding ────────────────────────────────
info "Reading binding from ${BINDING_JSON}"
ENDPOINT=$(jq -r '."ingest-otlp-endpoint" // empty' "${BINDING_JSON}")
CERT=$(jq -r '."ingest-otlp-cert"     // empty' "${BINDING_JSON}")
KEY=$(jq  -r '."ingest-otlp-key"      // empty' "${BINDING_JSON}")
CA=$(jq   -r '."server-ca"            // empty' "${BINDING_JSON}")

[ -n "${ENDPOINT}" ] || die "binding JSON missing required key: ingest-otlp-endpoint"
[ -n "${CERT}" ]     || die "binding JSON missing required key: ingest-otlp-cert"
[ -n "${KEY}" ]      || die "binding JSON missing required key: ingest-otlp-key"
[ -n "${CA}" ]       || die "binding JSON missing required key: server-ca"

# ── ensure namespace ─────────────────────────────────────────────────────────
info "Ensuring namespace ${NAMESPACE}"
k create namespace "${NAMESPACE}" --dry-run=client -o yaml | k apply -f - >/dev/null

# ── create/replace the secret ────────────────────────────────────────────────
# Deterministic content → kubectl apply on the dry-run output is idempotent.
info "Applying secret ${NAMESPACE}/${SECRET_NAME}"
k -n "${NAMESPACE}" create secret generic "${SECRET_NAME}" \
  --from-literal=ca.crt="${CA}" \
  --from-literal=tls.crt="${CERT}" \
  --from-literal=tls.key="${KEY}" \
  --dry-run=client -o yaml \
  | k apply -f -

ok "secret ${SECRET_NAME} written"
echo
echo "Chart values to activate the BTP backend:"
echo
echo "  backend: btp"
echo "  opensearch:"
echo "    enabled: false"
echo "  btp:"
echo "    endpoint: \"${ENDPOINT}\""
echo "    certsSecret: ${SECRET_NAME}"
echo
echo "These are already in local-setup/kind/values/collector-btp.yaml — verify the"
echo "endpoint matches: $(grep -E '^\s+endpoint:' "${SCRIPT_DIR}/values/collector-btp.yaml" | awk '{print $2}')"
echo
echo "Next: helm upgrade --install telemetry <chart> -f values/collector-btp.yaml"
