#!/bin/sh
# rke2-cluster-roles.sh
# Run this inside the vault pod: vault exec -it vault-0 -- sh
# Then: sh /tmp/rke2-cluster-roles.sh

set -e

echo "Creating Vault roles for rke2-cluster-test..."

vault write auth/rke2-cluster-test/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets-policy \
  ttl=1h \
  audience=vault

echo "✓ external-secrets role created"
vault read auth/rke2-cluster-test/role/external-secrets

echo ""
echo "All rke2-cluster-test roles created successfully."
