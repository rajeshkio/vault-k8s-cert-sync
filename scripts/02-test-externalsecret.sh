#!/usr/bin/env bash
# scripts/02-test-externalsecret.sh
#
# Tests ExternalSecret sync against all clusters passed as env files.
#
# USAGE:
#   ./scripts/02-test-externalsecret.sh <primary.env> [secondary.env ...]
#
# Example:
#   ./scripts/02-test-externalsecret.sh \
#     suse-ai.env \
#     k3s-server.env

set -euo pipefail

[[ $# -eq 0 ]] && echo "ERROR: at least one env file required" && exit 1

PASS=0; FAIL=0

run_test() {
  local context="$1"
  local store_kind="$2"
  local store_name="$3"
  local namespace="$4"

  echo ""
  echo "==> Testing ExternalSecret on context: ${context}"
  kubectl config use-context "${context}"

  cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: test-vault-cert-sync
  namespace: ${namespace}
spec:
  refreshInterval: "30s"
  secretStoreRef:
    name: ${store_name}
    kind: ${store_kind}
  target:
    name: test-tls-cert
    creationPolicy: Owner
  data:
  - secretKey: tls.crt
    remoteRef:
      key: tls/rajesh-tls-cert
      property: tls.crt
  - secretKey: tls.key
    remoteRef:
      key: tls/rajesh-tls-cert
      property: tls.key
EOF

  echo "    Waiting 20s for ESO to sync..."
  sleep 20

  STATUS=$(kubectl get externalsecret test-vault-cert-sync \
    -n "${namespace}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
    2>/dev/null || echo "Unknown")

  if [ "${STATUS}" = "True" ]; then
    echo "    ExternalSecret synced on ${context}"
    PASS=$((PASS + 1))
  else
    echo "    ExternalSecret NOT ready on ${context} (status: ${STATUS})"
    kubectl describe externalsecret test-vault-cert-sync \
      -n "${namespace}" | tail -15
    FAIL=$((FAIL + 1))
  fi
}

# ── Run tests from env files ──────────────────────────────────────────────────
ALL_CONTEXTS=()

for env_file in "$@"; do
  [[ ! -f "$env_file" ]] && echo "ERROR: env file not found: ${env_file}" && exit 1
  source "${env_file}"

  ALL_CONTEXTS+=("${CONTEXT}")

  if [[ "${TYPE}" == "primary" ]]; then
    run_test "${CONTEXT}" "SecretStore" "vault-backend" "external-secrets"
  else
    run_test "${CONTEXT}" "ClusterSecretStore" "vault-backend-access" "external-secrets"
  fi
done

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo "==> Test results: ${PASS} passed, ${FAIL} failed"

echo ""
echo "==> Cleaning up..."
for env_file in "$@"; do
  source "${env_file}"
  kubectl config use-context "${CONTEXT}"
  kubectl delete externalsecret test-vault-cert-sync \
    -n external-secrets --ignore-not-found
  kubectl delete secret test-tls-cert \
    -n external-secrets --ignore-not-found
done
echo "    Cleanup done."

if [ "${FAIL}" -gt 0 ]; then
  echo ""
  echo "Some tests failed. Common causes:"
  echo "  - Vault role missing audience=vault (Vault 1.21+)"
  echo "  - Wrong apiVersion in SecretStore (use v1 for ESO v0.17+)"
  echo "  - serviceAccountRef missing audiences: [vault] (ESO v2.x)"
  echo "  - Token reviewer SA missing system:auth-delegator binding"
  exit 1
fi
