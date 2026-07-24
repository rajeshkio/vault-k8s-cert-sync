# vault-k8s-cert-sync

Companion repository for the article:
**[Vault + Kubernetes Auth: The Certificate Management Solution I Wish I'd Known Earlier](https://medium.com/@rk90229/vault-kubernetes-auth-the-certificate-management-solution-i-wish-id-known-earlier-c90084a4ff10)**

Automates TLS certificate distribution across multiple Kubernetes clusters using:

- **cert-manager** — certificate issuance and renewal
- **HashiCorp Vault** — single source of truth for secrets
- **External Secrets Operator (ESO)** — pulls secrets from Vault into Kubernetes
- **PushSecret** — pushes cert-manager secrets into Vault automatically

---

## Architecture

Primary cluster runs Vault and cert-manager:

cert-manager --> PushSecret --> Vault KV v2
Vault KV v2 --> SecretStore --> external-secrets

Secondary clusters pull from Vault:

Vault KV v2 --> ClusterSecretStore --> external-secrets (cluster 2)
Vault KV v2 --> ClusterSecretStore --> external-secrets (cluster 3)

Each cluster gets its own Kubernetes auth mount in Vault.
Vault is the single source of truth. cert-manager handles renewal.
Everything else is automated.

---

## Versions

| Component        | Version |
| ---------------- | ------- |
| cert-manager     | v1.16.2 |
| external-secrets | v2.5.0  |
| Vault            | 2.0.2   |

---

## Important Notes

**Vault 1.21+** — All Vault roles require `audience=vault`. Without it,
authentication fails with "invalid audience claim".

**ESO v0.17+** — All manifests use `apiVersion: external-secrets.io/v1`.
The `v1beta1` API is no longer served. PushSecret stays at `v1alpha1`.

**ESO v2.x** — `serviceAccountRef` inside SecretStore and ClusterSecretStore
requires `audiences: [vault]`. Without it, ESO presents a token without the
vault audience claim and Vault rejects it with 403 even when `audience=vault`
is set on the role.

---

## Repo Structure

```
vault-k8s-cert-sync/
├── vault/
│   ├── values.yaml                     # Helm values for single-node deployment
│   └── policies/
│       ├── cert-manager-policy.hcl     # read/write to kv/*
│       └── external-secrets-policy.hcl # read-only from kv/*
├── clusters/
│   └── <primary-cluster/mount>/
│       └── pushsecret.yaml             # PushSecret for cert to Vault
├── scripts/
│   ├── bootstrap-vault.sh              # run once after unseal
│   ├── add-cluster.sh                  # add any cluster with one command
│   └── 02-test-externalsecret.sh       # verify end-to-end sync
└── README.md
```

---

## Prerequisites

- Kubernetes cluster with `kubectl` access
- Vault deployed and unsealed (see Vault Deployment below)
- cert-manager installed on the primary cluster
- External Secrets Operator v2.x installed on all clusters
- Vault accessible at a resolvable URL from all clusters

---

## Vault Deployment

Vault is deployed manually via Helm. It cannot be managed by ArgoCD because
init and unseal require manual operator steps after every pod restart.

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update hashicorp

kubectl create namespace vault

helm install vault hashicorp/vault \
  -n vault \
  -f vault/values.yaml \
  --version 0.33.0 \
  --wait --timeout 5m
```

### Initialise

```bash
kubectl -n vault exec vault-0 -- \
  vault operator init \
    -key-shares=5 \
    -key-threshold=3 \
    -format=json > vault-init-keys.json
```

⚠️ Back up `vault-init-keys.json` immediately. It is gitignored and will
never be committed. This is the only time you will see these keys.

### Unseal

```bash
KEY1=$(cat vault-init-keys.json | python3 -c "import sys,json; print(json.load(sys.stdin)['unseal_keys_b64'][0])")
KEY2=$(cat vault-init-keys.json | python3 -c "import sys,json; print(json.load(sys.stdin)['unseal_keys_b64'][1])")
KEY3=$(cat vault-init-keys.json | python3 -c "import sys,json; print(json.load(sys.stdin)['unseal_keys_b64'][2])")

kubectl -n vault exec vault-0 -- vault operator unseal $KEY1
kubectl -n vault exec vault-0 -- vault operator unseal $KEY2
kubectl -n vault exec vault-0 -- vault operator unseal $KEY3

kubectl -n vault exec vault-0 -- vault status
```

### Login

```bash
ROOT_TOKEN=$(cat vault-init-keys.json | python3 -c "import sys,json; print(json.load(sys.stdin)['root_token'])")
kubectl -n vault exec vault-0 -- vault login $ROOT_TOKEN
```

---

## Setup — After Unseal

### Step 1 — Bootstrap Vault

Run once after unseal. Enables KV v2 and applies both policies.

```bash
./scripts/bootstrap-vault.sh
```

Expected output:

### Step 2 — Add clusters

Add the primary cluster (cert-manager + cert-pusher + external-secrets roles):

```bash
./scripts/add-cluster.sh \
  --context <kubectl-context> \
  --kube-host https://<API-SERVER-IP>:6443 \
  --mount <auth-mount-name> \
  --type primary
```

Add any secondary cluster (external-secrets role only):

```bash
./scripts/add-cluster.sh \
  --context <kubectl-context> \
  --kube-host https://<API-SERVER-IP>:6443 \
  --mount <auth-mount-name> \
  --type secondary
```

The script handles everything in one shot:

- Creates namespaces, service accounts, ClusterRoleBinding on the target cluster
- Generates reviewer token and CA cert
- Enables and configures the Vault auth mount
- Creates Vault roles
- Applies SecretStore (primary) or ClusterSecretStore (secondary)
- Verifies the store is Ready

### Step 3 — Apply PushSecret

Once cert-manager has issued a certificate on the primary cluster:

```bash
kubectl apply -f clusters/<primary-cluster/mount>/pushsecret.yaml
kubectl get pushsecret push-rajesh-cert -n certificates -w
```

### Step 4 — Verify

```bash
./scripts/02-test-externalsecret.sh
```

---

## Adding a New Cluster

One command:

```bash
./scripts/add-cluster.sh \
  --context new-cluster \
  --kube-host https://192.168.1.200:6443 \
  --mount new-cluster \
  --type secondary
```

No files to create. No directories to add. No manual kubectl exec.

---

## Troubleshooting

**`invalid audience claim` during Vault auth**

All Vault roles must include `audience=vault` (Vault 1.21+). Verify:

```bash
kubectl -n vault exec vault-0 -- vault read auth/<mount>/role/<name>
```

**ESO SecretStore `403` with audience error**

Add `audiences: [vault]` to `serviceAccountRef` in your SecretStore
or ClusterSecretStore. Required in ESO v2.x:

```yaml
serviceAccountRef:
  name: external-secrets
  audiences:
    - vault
```

**`permission denied` on token review**

The `vault-auth` SA needs `system:auth-delegator`. Verify:

```bash
kubectl get clusterrolebinding vault-auth-tokenreview-binding -o yaml
```

**SecretStore shows `InvalidProviderConfig`**

Check ESO version. If on v0.17+, use `apiVersion: external-secrets.io/v1`.
Describe for the actual error:

```bash
kubectl describe secretstore vault-backend -n external-secrets
```

**PushSecret not syncing**

Confirm the source secret exists and the cert-pusher role has write access:

```bash
kubectl describe pushsecret push-rajesh-cert -n certificates
```

---

## Related

- [Article on Medium](https://medium.com/@rk90229/vault-kubernetes-auth-the-certificate-management-solution-i-wish-id-known-earlier-c90084a4ff10)
- [External Secrets Operator docs](https://external-secrets.io)
- [HashiCorp Vault Kubernetes auth](https://developer.hashicorp.com/vault/docs/auth/kubernetes)
- [Vault Secrets Operator](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso)
