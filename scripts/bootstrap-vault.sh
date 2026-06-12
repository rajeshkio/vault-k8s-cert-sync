#!/usr/bin/env bash
# scripts/bootstrap-vault.sh
#
# Run ONCE after Vault is initialised and unsealed.
# Enables KV v2 engine and applies both policies.
# Does NOT configure any cluster — use add-cluster.sh for that.
#
# USAGE:
#   ./scripts/bootstrap-vault.sh
#
# REQUIREMENTS:
#   - kubectl context set to the cluster where Vault is running
#   - Vault already unsealed and logged in

set -euo pipefail

VAULT_NS="vault"
VAULT_POD="vault-0"

log() { echo ""; echo "==> $1"; }
ok()  { echo "    ✓ $1"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log "Enabling KV v2 secret engine"
kubectl -n "${VAULT_NS}" exec "${VAULT_POD}" -- sh -c \
  "vault secrets list | grep -q '^kv/' \
    && echo '    kv/ already enabled' \
    || vault secrets enable -path=kv kv-v2"
ok "KV v2 ready at kv/"

log "Applying policies"
kubectl -n "${VAULT_NS}" cp \
  "${REPO_ROOT}/vault/policies/cert-manager-policy.hcl" \
  "${VAULT_POD}:/tmp/cert-manager-policy.hcl"

kubectl -n "${VAULT_NS}" cp \
  "${REPO_ROOT}/vault/policies/external-secrets-policy.hcl" \
  "${VAULT_POD}:/tmp/external-secrets-policy.hcl"

kubectl -n "${VAULT_NS}" exec "${VAULT_POD}" -- sh -c "
  vault policy write cert-manager-policy /tmp/cert-manager-policy.hcl
  vault policy write external-secrets-policy /tmp/external-secrets-policy.hcl
  echo ''
  vault policy list
"
ok "Policies applied"

echo ""
echo "Bootstrap complete. Now add clusters:"
echo ""
echo "  Primary cluster (cert-manager + external-secrets roles):"
echo "  ./scripts/add-cluster.sh \\"
echo "    --context rancher-master \\"
echo "    --kube-host https://<IP>:6443 \\"
echo "    --mount rancher-master \\"
echo "    --type primary"
echo ""
echo "  Secondary cluster (external-secrets role only):"
echo "  ./scripts/add-cluster.sh \\"
echo "    --context k3s-server \\"
echo "    --kube-host https://<IP>:6443 \\"
echo "    --mount k3s-cluster \\"
echo "    --type secondary"
