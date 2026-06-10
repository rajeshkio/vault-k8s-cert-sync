#!/bin/sh
# rancher-master-roles.sh
# Run this inside the vault pod: vault exec -it vault-0 -- sh
# Then: sh /tmp/rancher-master-roles.sh

set -e

echo "Creating Vault roles for rancher-master..."

vault write auth/rancher-master/role/cert-manager \
  bound_service_account_names=cert-manager \
  bound_service_account_namespaces=cert-manager \
  policies=cert-manager-policy \
  ttl=1h \
  audience=vault

echo "✓ cert-manager role created"
vault read auth/rancher-master/role/cert-manager

vault write auth/rancher-master/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets-policy \
  ttl=1h \
  audience=vault

echo "✓ external-secrets role created"
vault read auth/rancher-master/role/external-secrets

vault write auth/rancher-master/role/cert-pusher \
  bound_service_account_names=cert-pusher \
  bound_service_account_namespaces=cert-manager \
  policies=cert-manager-policy \
  ttl=24h \
  max_ttl=48h \
  audience=vault

echo "✓ cert-pusher role created"
vault read auth/rancher-master/role/cert-pusher

echo ""
echo "All rancher-master roles created successfully."
