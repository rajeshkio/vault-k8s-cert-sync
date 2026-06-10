#!/bin/sh
# k3s-cluster-roles.sh
# Run this inside the vault pod: vault exec -it vault-0 -- sh
# Then: sh /tmp/k3s-cluster-roles.sh

set -e

echo "Creating Vault roles for k3s-cluster..."

vault write auth/k3s-cluster/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets-policy \
  ttl=1h \
  audience=vault

echo "✓ external-secrets role created"
vault read auth/k3s-cluster/role/external-secrets

echo ""
echo "All k3s-cluster roles created successfully."
