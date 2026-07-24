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

# --------- Load env file -----------------------------------------------------
ENV_FILE="${1:-}"
[[ -z "$ENV_FILE" ]]      && echo "ERROR: env file required. Usage: ./scripts/add-cluster.sh mycluster.env" && exit 1
[[ ! -f "$ENV_FILE" ]]    && echo "ERROR: env file not found: ${ENV_FILE}" && exit 1

# shellcheck source=/dev/null
source "${ENV_FILE}"

# --------- Validate ----------------------------------------------------------
[[ -z "${CONTEXT:-}"   ]] && echo "ERROR: CONTEXT is required in ${ENV_FILE}"   && exit 1
[[ -z "${KUBE_HOST:-}" ]] && echo "ERROR: KUBE_HOST is required in ${ENV_FILE}" && exit 1
[[ -z "${MOUNT:-}"     ]] && echo "ERROR: MOUNT is required in ${ENV_FILE}"     && exit 1
[[ -z "${TYPE:-}"      ]] && echo "ERROR: TYPE is required in ${ENV_FILE}"      && exit 1
[[ -z "${VAULT_URL:-}" ]] && echo "ERROR: VAULT_URL is required in ${ENV_FILE}" && exit 1

[[ "$TYPE" != "primary" && "$TYPE" != "secondary" ]] && \
  echo "ERROR: TYPE must be 'primary' or 'secondary'" && exit 1

if [[ "$TYPE" == "primary" ]]; then
  [[ -z "${SECRET_NAME:-}"      ]] && echo "ERROR: SECRET_NAME is required for primary clusters"      && exit 1
  [[ -z "${SECRET_NAMESPACE:-}" ]] && echo "ERROR: SECRET_NAMESPACE is required for primary clusters" && exit 1
  [[ -z "${VAULT_PATH:-}"       ]] && echo "ERROR: VAULT_PATH is required for primary clusters"       && exit 1
fi

log()     { echo ""; echo "==> $1"; }
ok()      { echo "    $1"; }
section() { echo ""; echo "--------------------------------------------------"
            echo "  $1"
            echo "----------------------------------------------"; }

section "Adding cluster: ${CONTEXT} (${TYPE})"
echo "  Env file   : ${ENV_FILE}"
echo "  Auth mount : ${MOUNT}"
echo "  Kube host  : ${KUBE_HOST}"
echo "  Vault URL  : ${VAULT_URL}"

# vault-auth SA namespace
VAULT_AUTH_NS="kube-system"
[[ "$TYPE" == "primary" ]] && VAULT_AUTH_NS="vault"

# --------- Step 1: Kubernetes resources on target cluster ----------------------
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

# --------- Step 2: Reviewer token + CA cert ---------------------------------
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

# --------- Step 3: Copy into Vault pod -----------------------------------------
log "Step 3: Copying files into Vault pod"
kubectl config use-context "${VAULT_CONTEXT}"

kubectl -n "${VAULT_NS}" cp "${CA_FILE}" \
  "${VAULT_POD}:/tmp/vault-${CONTEXT}-ca.crt"
kubectl -n "${VAULT_NS}" cp "${TOKEN_FILE}" \
  "${VAULT_POD}:/tmp/vault-${CONTEXT}-reviewer.jwt"
ok "Files copied to ${VAULT_POD}"

# --------- Step 4: Configure Vault auth mount ----------------------------------- 
log "Step 4: Configuring Vault auth mount: ${MOUNT}"

kubectl -n "${VAULT_NS}" exec "${VAULT_POD}" -- sh -c "
  set -e

  if vault auth list | grep -q '^${MOUNT}/'; then
    echo '    auth/${MOUNT}/ already exists — reconfiguring'
  else
    vault auth enable -path=${MOUNT} kubernetes
    echo '    auth/${MOUNT}/ enabled'
  fi

  vault write auth/${MOUNT}/config \
    kubernetes_host='${KUBE_HOST}' \
    kubernetes_ca_cert=@/tmp/vault-${CONTEXT}-ca.crt \
    token_reviewer_jwt=@/tmp/vault-${CONTEXT}-reviewer.jwt

  echo '    auth/${MOUNT}/ configured'
  vault read auth/${MOUNT}/config
"

# ------------ Step 5: Create Vault roles ----------------------------------------- 
log "Step 5: Creating Vault roles"

kubectl -n "${VAULT_NS}" exec "${VAULT_POD}" -- sh -c "
  set -e

  vault write auth/${MOUNT}/role/external-secrets \
    bound_service_account_names=external-secrets \
    bound_service_account_namespaces=external-secrets \
    policies=external-secrets-policy \
    ttl=1h \
    audience=vault
  echo '    external-secrets role created'
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
    echo '    cert-manager role created'

    vault write auth/${MOUNT}/role/cert-pusher \
      bound_service_account_names=cert-pusher \
      bound_service_account_namespaces=cert-manager \
      policies=cert-manager-policy \
      ttl=24h \
      max_ttl=48h \
      audience=vault
    echo '    cert-pusher role created'
  "
fi

# ----------  Step 6: SecretStore / ClusterSecretStore -------------------------------
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
    || echo "    SecretStore status: ${STATUS} — check: kubectl describe secretstore vault-backend -n external-secrets"

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

# --------- Step 7: PushSecret (primary only) ---------------------------------
if [[ "$TYPE" == "primary" ]]; then
  log "Step 7: Applying PushSecret"
  kubectl config use-context "${CONTEXT}"

  kubectl apply -f - <<MANIFEST
apiVersion: external-secrets.io/v1alpha1
kind: PushSecret
metadata:
  name: push-${SECRET_NAME}
  namespace: ${SECRET_NAMESPACE}
spec:
  refreshInterval: 10m
  secretStoreRefs:
  - name: vault-pusher
    kind: ClusterSecretStore
  selector:
    secret:
      name: ${SECRET_NAME}
  data:
  - match:
      secretKey: tls.crt
      remoteRef:
        remoteKey: ${VAULT_PATH}
        property: tls.crt
  - match:
      secretKey: tls.key
      remoteRef:
        remoteKey: ${VAULT_PATH}
        property: tls.key
MANIFEST
  ok "PushSecret/push-${SECRET_NAME} applied in namespace ${SECRET_NAMESPACE}"
  echo "    Note: PushSecret will sync once secret '${SECRET_NAME}' exists in namespace '${SECRET_NAMESPACE}'"
fi

# --------- Summary ------------------------------------------------
section "Done: ${CONTEXT} added to Vault"
echo "  Context    : ${CONTEXT}"
echo "  Auth mount : ${MOUNT}/"
echo "  Type       : ${TYPE}"
if [[ "$TYPE" == "primary" ]]; then
  echo "  Roles      : external-secrets, cert-manager, cert-pusher"
  echo "  Stores     : SecretStore/vault-backend, ClusterSecretStore/vault-pusher"
  echo "  PushSecret : push-${SECRET_NAME} (ns: ${SECRET_NAMESPACE})"
  echo ""
  echo "  Check sync status:"
  echo "    kubectl get pushsecret push-${SECRET_NAME} -n ${SECRET_NAMESPACE} -w"
else
  echo "  Roles      : external-secrets"
  echo "  Store      : ClusterSecretStore/vault-backend-access"
fi
