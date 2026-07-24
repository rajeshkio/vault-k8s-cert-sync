#!/usr/bin/env bash
# scripts/add-cluster.sh
#
# Adds a Kubernetes cluster to Vault auth and configures ESO SecretStore.
# Run from the root of vault-k8s-cert-sync repo after Vault is unsealed
# and bootstrap-vault.sh has been run.
#
# USAGE:
#   ./scripts/add-cluster.sh \
#     --context <kubectl-context> \
#     --kube-host <api-server-url> \
#     --mount <vault-auth-mount-name> \
#     --type <primary|secondary>
#     --vault-url https://<your-vault-domain>
#
# Example:
#   ./scripts/add-cluster.sh \
#     --context default \
#     --kube-host https://192.168.90.100:6443 \
#     --mount suse-ai \
#     --type primary \
#     --vault-url https://vault.rajesh-kumar.in
#
# primary   = vault-auth + cert-manager + cert-pusher + external-secrets SAs
#             Vault roles: cert-manager, cert-pusher, external-secrets
#             SecretStore (namespaced, in external-secrets namespace)
#
# secondary = vault-auth + external-secrets SAs only
#             Vault roles: external-secrets only
#             ClusterSecretStore (cluster-scoped)

set -euo pipefail

VAULT_NS="vault"
VAULT_POD="vault-0"
VAULT_CONTEXT=$(kubectl config current-context)
echo "Vault context (current): ${VAULT_CONTEXT}"

# ── Argument parsing ─────────────────────────────────────────────────────────
CONTEXT=""
KUBE_HOST=""
MOUNT=""
TYPE=""
VAULT_URL=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --context)   CONTEXT="$2";   shift 2 ;;
    --kube-host) KUBE_HOST="$2"; shift 2 ;;
    --mount)     MOUNT="$2";     shift 2 ;;
    --type)      TYPE="$2";      shift 2 ;;
    --vault-url)     VAULT_URL="$2";     shift 2 ;;
    *) echo "ERROR: Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Validate ─────────────────────────────────────────────────────────────────
[[ -z "$CONTEXT"   ]] && echo "ERROR: --context is required"   && exit 1
[[ -z "$KUBE_HOST" ]] && echo "ERROR: --kube-host is required" && exit 1
[[ -z "$MOUNT"     ]] && echo "ERROR: --mount is required"     && exit 1
[[ -z "$TYPE"      ]] && echo "ERROR: --type must be primary|secondary" && exit 1
[[ -z "$VAULT_URL"     ]] && echo "ERROR: --vault-url is required"     && exit 1
[[ "$TYPE" != "primary" && "$TYPE" != "secondary" ]] && \
  echo "ERROR: --type must be 'primary' or 'secondary'" && exit 1

log()     { echo ""; echo "==> $1"; }
ok()      { echo "    ✓ $1"; }
section() { echo ""; echo "────────────────────────────────────────────"; \
            echo "  $1"; \
            echo "────────────────────────────────────────────"; }

section "Adding cluster: ${CONTEXT} (${TYPE})"
echo "  Auth mount : ${MOUNT}"
echo "  Kube host  : ${KUBE_HOST}"

# vault-auth SA namespace
VAULT_AUTH_NS="kube-system"
[[ "$TYPE" == "primary" ]] && VAULT_AUTH_NS="vault"

# ── Step 1: Kubernetes resources on target cluster ───────────────────────────
log "Step 1: Creating Kubernetes resources on ${CONTEXT}"
kubectl config use-context "${CONTEXT}"

# Namespaces
for ns in external-secrets "${VAULT_AUTH_NS}"; do
  kubectl get namespace "${ns}" &>/dev/null \
    && echo "    namespace/${ns}: exists" \
    || kubectl create namespace "${ns}" \
    && echo "    namespace/${ns}: created"
done

if [[ "$TYPE" == "primary" ]]; then
  for ns in cert-manager certificates; do
    kubectl get namespace "${ns}" &>/dev/null \
      && echo "    namespace/${ns}: exists" \
      || kubectl create namespace "${ns}" \
      && echo "    namespace/${ns}: created"
  done
fi

# vault-auth SA + ClusterRoleBinding
kubectl apply -f - <<MANIFEST
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-auth
  namespace: ${VAULT_AUTH_NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vault-auth-tokenreview-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: vault-auth
  namespace: ${VAULT_AUTH_NS}
MANIFEST
ok "vault-auth SA + ClusterRoleBinding applied"

# external-secrets SA
kubectl apply -f - <<MANIFEST
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-secrets
  namespace: external-secrets
MANIFEST
ok "external-secrets SA applied"

# cert-manager + cert-pusher SAs (primary only)
if [[ "$TYPE" == "primary" ]]; then
  kubectl apply -f - <<MANIFEST
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cert-manager
  namespace: cert-manager
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cert-pusher
  namespace: cert-manager
MANIFEST
  ok "cert-manager + cert-pusher SAs applied"
fi

# ── Step 2: Reviewer token + CA cert ─────────────────────────────────────────
log "Step 2: Generating reviewer token and CA cert"

CA_FILE="/tmp/vault-${CONTEXT}-ca.crt"
TOKEN_FILE="/tmp/vault-${CONTEXT}-reviewer.jwt"

kubectl config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 --decode > "${CA_FILE}"
ok "CA cert: ${CA_FILE}"

kubectl create token vault-auth \
  -n "${VAULT_AUTH_NS}" \
  --duration=8760h > "${TOKEN_FILE}"
ok "Reviewer token: ${TOKEN_FILE}"

# ── Step 3: Copy into Vault pod ───────────────────────────────────────────────
log "Step 3: Copying files into Vault pod"
kubectl config use-context "${VAULT_CONTEXT}"

kubectl -n "${VAULT_NS}" cp "${CA_FILE}" \
  "${VAULT_POD}:/tmp/vault-${CONTEXT}-ca.crt"
kubectl -n "${VAULT_NS}" cp "${TOKEN_FILE}" \
  "${VAULT_POD}:/tmp/vault-${CONTEXT}-reviewer.jwt"
ok "Files copied to ${VAULT_POD}"

# ── Step 4: Configure Vault auth mount ───────────────────────────────────────
log "Step 4: Configuring Vault auth mount: ${MOUNT}"

kubectl -n "${VAULT_NS}" exec "${VAULT_POD}" -- sh -c "
  set -e

  if vault auth list | grep -q '^${MOUNT}/'; then
    echo '    auth/${MOUNT}/ already exists — reconfiguring'
  else
    vault auth enable -path=${MOUNT} kubernetes
    echo '    ✓ auth/${MOUNT}/ enabled'
  fi

  vault write auth/${MOUNT}/config \
    kubernetes_host='${KUBE_HOST}' \
    kubernetes_ca_cert=@/tmp/vault-${CONTEXT}-ca.crt \
    token_reviewer_jwt=@/tmp/vault-${CONTEXT}-reviewer.jwt

  echo '    ✓ auth/${MOUNT}/ configured'
  vault read auth/${MOUNT}/config
"

# ── Step 5: Create Vault roles ────────────────────────────────────────────────
log "Step 5: Creating Vault roles"

kubectl -n "${VAULT_NS}" exec "${VAULT_POD}" -- sh -c "
  set -e

  vault write auth/${MOUNT}/role/external-secrets \
    bound_service_account_names=external-secrets \
    bound_service_account_namespaces=external-secrets \
    policies=external-secrets-policy \
    ttl=1h \
    audience=vault
  echo '    ✓ external-secrets role created'
"

if [[ "$TYPE" == "primary" ]]; then
  kubectl -n "${VAULT_NS}" exec "${VAULT_POD}" -- sh -c "
    set -e

    vault write auth/${MOUNT}/role/cert-manager \
      bound_service_account_names=cert-manager \
      bound_service_account_namespaces=cert-manager \
      policies=cert-manager-policy \
      ttl=1h \
      audience=vault
    echo '    ✓ cert-manager role created'

    vault write auth/${MOUNT}/role/cert-pusher \
      bound_service_account_names=cert-pusher \
      bound_service_account_namespaces=cert-manager \
      policies=cert-manager-policy \
      ttl=24h \
      max_ttl=48h \
      audience=vault
    echo '    ✓ cert-pusher role created'
  "
fi

# ── Step 6: SecretStore / ClusterSecretStore ──────────────────────────────────
log "Step 6: Applying SecretStore on ${CONTEXT}"
kubectl config use-context "${CONTEXT}"

if [[ "$TYPE" == "primary" ]]; then
  kubectl apply -f - <<MANIFEST
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: external-secrets
spec:
  provider:
    vault:
      server: "${VAULT_URL}"
      path: "kv"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "${MOUNT}"
          role: "external-secrets"
          serviceAccountRef:
            name: "external-secrets"
            audiences:
              - vault
MANIFEST
  ok "SecretStore/vault-backend applied"

  echo "    Waiting 15s for SecretStore to sync..."
  sleep 15
  STATUS=$(kubectl get secretstore vault-backend \
    -n external-secrets \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
    2>/dev/null || echo "Unknown")
  [[ "$STATUS" == "True" ]] \
    && ok "SecretStore is Ready" \
    || echo "    ⚠ SecretStore status: ${STATUS} — check: kubectl describe secretstore vault-backend -n external-secrets"

  kubectl apply -f - <<MANIFEST
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: vault-pusher
spec:
  provider:
    vault:
      server: "${VAULT_URL}"
      path: "kv"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "${MOUNT}"
          role: "cert-pusher"
          serviceAccountRef:
            name: "cert-pusher"
            namespace: "cert-manager"
            audiences:
              - vault 
MANIFEST
  ok "ClusterSecretStore/vault-pusher applied"

else
  kubectl apply -f - <<MANIFEST
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: vault-backend-access
spec:
  provider:
    vault:
      server: "${VAULT_URL}"
      path: "kv"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "${MOUNT}"
          role: "external-secrets"
          serviceAccountRef:
            name: "external-secrets"
            namespace: "external-secrets"
            audiences:
              - vault
MANIFEST
  ok "ClusterSecretStore/vault-backend-access applied"

  echo "    Waiting 15s for ClusterSecretStore to sync..."
  sleep 15
  STATUS=$(kubectl get clustersecretstore vault-backend-access \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
    2>/dev/null || echo "Unknown")
  [[ "$STATUS" == "True" ]] \
    && ok "ClusterSecretStore is Ready" \
    || echo "    ClusterSecretStore status: ${STATUS} — check: kubectl describe clustersecretstore vault-backend-access"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
section "Done: ${CONTEXT} added to Vault"
echo "  Context    : ${CONTEXT}"
echo "  Auth mount : ${MOUNT}/"
echo "  Type       : ${TYPE}"
if [[ "$TYPE" == "primary" ]]; then
  echo "  Roles      : external-secrets, cert-manager, cert-pusher"
  echo "  Store      : SecretStore/vault-backend (ns: external-secrets)"
  echo ""
  echo "  Next: apply PushSecret once cert-manager has issued a cert:"
  echo "    kubectl apply -f clusters/${MOUNT}/pushsecret.yaml"
else
  echo "  Roles      : external-secrets"
  echo "  Store      : ClusterSecretStore/vault-backend-access"
fi
