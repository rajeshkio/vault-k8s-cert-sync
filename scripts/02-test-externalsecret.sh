#!/usr/bin/env bash
# scripts/02-test-externalsecret.sh
#
# Creates a test ExternalSecret on each cluster and verifies the secret
# is pulled from Vault successfully.
# Assumes the PushSecret has already synced "rajesh-tls-cert" to Vault.

set -euo pipefail

PASS=0
FAIL=0

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
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")

  if [ "${STATUS}" = "True" ]; then
    echo "    ✓ ExternalSecret synced successfully on ${context}"
    kubectl get secret test-tls-cert -n "${namespace}" \
      -o jsonpath='{.data}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('    Keys found:', list(d.keys()))
"
    PASS=$((PASS + 1))
  else
    echo "    ✗ ExternalSecret NOT ready on ${context} (status: ${STATUS})"
    echo "    Describing ExternalSecret for details:"
    kubectl describe externalsecret test-vault-cert-sync -n "${namespace}" | tail -20
    FAIL=$((FAIL + 1))
  fi
}

run_test "rancher-master" "SecretStore"      "vault-backend"        "external-secrets"
run_test "k3s-server"     "ClusterSecretStore" "vault-backend-access" "external-secrets"
run_test "rke2-server"    "ClusterSecretStore" "vault-backend-access" "external-secrets"

echo ""
echo "==> Test results: ${PASS} passed, ${FAIL} failed"

echo ""
echo "==> Cleaning up test ExternalSecrets..."
for ctx in rancher-master k3s-server rke2-server; do
  kubectl config use-context "${ctx}"
  kubectl delete externalsecret test-vault-cert-sync -n external-secrets --ignore-not-found
  kubectl delete secret test-tls-cert -n external-secrets --ignore-not-found
done
echo "    Cleanup done."

if [ "${FAIL}" -gt 0 ]; then
  echo ""
  echo "Some tests failed. Common causes:"
  echo "  - Vault role missing audience=vault (Vault 1.21+)"
  echo "  - Wrong apiVersion in SecretStore (use v1 for ESO v0.17+)"
  echo "  - Token reviewer SA missing system:auth-delegator binding"
  echo "  - PushSecret has not synced the cert to Vault yet"
  exit 1
fi
