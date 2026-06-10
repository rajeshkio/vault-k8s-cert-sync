#!/usr/bin/env bash
# scripts/01-configure-vault-auth.sh
#
# Configures Vault Kubernetes auth for all three clusters.
# Run this from your local machine with kubectl contexts set up.
#
# BEFORE RUNNING:
#   1. Update the KUBE_HOST variables below for each cluster
#   2. Ensure you have the right kubectl contexts: rancher-master, k3s-server, rke2-server
#   3. Vault pod must be running and accessible via kubectl -n vault exec

set -euo pipefail

VAULT_NAMESPACE="vault"
VAULT_POD="vault-0"

# ============================================================
# UPDATE THESE VALUES FOR YOUR ENVIRONMENT
# ============================================================
RANCHER_KUBE_HOST="https://192.168.1.102:6443"
K3S_KUBE_HOST="https://192.168.1.101:6443"
RKE2_KUBE_HOST="https://192.168.1.103:6443"
# ============================================================

echo "==> Step 1: Generating token reviewer tokens and CA certs"

# --- rancher-master ---
echo "--> rancher-master"
kubectl config use-context rancher-master

kubectl config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 --decode > /tmp/rancher-ca.crt

kubectl create token vault-auth \
  -n "${VAULT_NAMESPACE}" \
  --duration=8760h > /tmp/vault-rancher-reviewer-token.jwt

echo "    CA cert and reviewer token saved"

# --- k3s-server ---
echo "--> k3s-server"
kubectl config use-context k3s-server

kubectl config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 --decode > /tmp/k3s-ca.crt

kubectl create token vault-auth \
  -n kube-system \
  --duration=8760h > /tmp/vault-k3s-reviewer-token.jwt

echo "    CA cert and reviewer token saved"

# --- rke2-server ---
echo "--> rke2-server"
kubectl config use-context rke2-server

kubectl config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 --decode > /tmp/rke2-ca.crt

kubectl create token vault-auth \
  -n kube-system \
  --duration=8760h > /tmp/vault-rke2-reviewer-token.jwt

echo "    CA cert and reviewer token saved"

# --- Switch back to rancher-master to copy files into vault pod ---
kubectl config use-context rancher-master

echo ""
echo "==> Step 2: Copying certs and tokens into Vault pod"

kubectl -n "${VAULT_NAMESPACE}" cp /tmp/rancher-ca.crt \
  "${VAULT_POD}:/tmp/rancher-ca.crt"
kubectl -n "${VAULT_NAMESPACE}" cp /tmp/vault-rancher-reviewer-token.jwt \
  "${VAULT_POD}:/tmp/vault-rancher-reviewer-token.jwt"

kubectl -n "${VAULT_NAMESPACE}" cp /tmp/k3s-ca.crt \
  "${VAULT_POD}:/tmp/k3s-ca.crt"
kubectl -n "${VAULT_NAMESPACE}" cp /tmp/vault-k3s-reviewer-token.jwt \
  "${VAULT_POD}:/tmp/vault-k3s-reviewer-token.jwt"

kubectl -n "${VAULT_NAMESPACE}" cp /tmp/rke2-ca.crt \
  "${VAULT_POD}:/tmp/rke2-ca.crt"
kubectl -n "${VAULT_NAMESPACE}" cp /tmp/vault-rke2-reviewer-token.jwt \
  "${VAULT_POD}:/tmp/vault-rke2-reviewer-token.jwt"

echo "    All files copied"

echo ""
echo "==> Step 3: Configuring Vault Kubernetes auth mounts"

kubectl -n "${VAULT_NAMESPACE}" exec "${VAULT_POD}" -- sh -c "
  echo '--> Configuring rancher-master auth mount'
  vault write auth/rancher-master/config \
    kubernetes_host='${RANCHER_KUBE_HOST}' \
    kubernetes_ca_cert=@/tmp/rancher-ca.crt \
    token_reviewer_jwt=@/tmp/vault-rancher-reviewer-token.jwt

  echo '--> Configuring k3s-cluster auth mount'
  vault write auth/k3s-cluster/config \
    kubernetes_host='${K3S_KUBE_HOST}' \
    kubernetes_ca_cert=@/tmp/k3s-ca.crt \
    token_reviewer_jwt=@/tmp/vault-k3s-reviewer-token.jwt

  echo '--> Configuring rke2-cluster-test auth mount'
  vault write auth/rke2-cluster-test/config \
    kubernetes_host='${RKE2_KUBE_HOST}' \
    kubernetes_ca_cert=@/tmp/rke2-ca.crt \
    token_reviewer_jwt=@/tmp/vault-rke2-reviewer-token.jwt

  echo ''
  echo 'Verifying configs...'
  vault read auth/rancher-master/config
  vault read auth/k3s-cluster/config
  vault read auth/rke2-cluster-test/config
"

echo ""
echo "==> Step 4: Copying role scripts into Vault pod"

kubectl -n "${VAULT_NAMESPACE}" cp vault/roles/rancher-master-roles.sh \
  "${VAULT_POD}:/tmp/rancher-master-roles.sh"
kubectl -n "${VAULT_NAMESPACE}" cp vault/roles/k3s-cluster-roles.sh \
  "${VAULT_POD}:/tmp/k3s-cluster-roles.sh"
kubectl -n "${VAULT_NAMESPACE}" cp vault/roles/rke2-cluster-roles.sh \
  "${VAULT_POD}:/tmp/rke2-cluster-roles.sh"

echo ""
echo "==> Done. Next step: create Vault roles."
echo "    Run: kubectl -n vault exec -it vault-0 -- sh"
echo "    Then: sh /tmp/rancher-master-roles.sh"
echo "          sh /tmp/k3s-cluster-roles.sh"
echo "          sh /tmp/rke2-cluster-roles.sh"
