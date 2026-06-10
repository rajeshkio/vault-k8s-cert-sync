# vault-k8s-cert-sync

Companion repository for the article:
**[Vault + Kubernetes Auth: The Certificate Management Solution I Wish I'd Known Earlier](https://medium.com/@rajesh-kumar)**

Automates TLS certificate distribution across multiple Kubernetes clusters using:
- **cert-manager** — certificate issuance and renewal
- **HashiCorp Vault** — single source of truth for secrets
- **External Secrets Operator (ESO)** — pulls secrets from Vault into Kubernetes
- **PushSecret** — pushes cert-manager secrets into Vault automatically

---

## Lab Architecture

```
┌─────────────────────────────────────────────────────────┐
│                   rancher-master (k3s)                   │
│  cert-manager  ──►  PushSecret  ──►  Vault (KV v2)      │
│  external-secrets ◄── SecretStore ◄── Vault              │
└─────────────────────────────────────────────────────────┘
          │                              │
          ▼                              ▼
┌──────────────────┐          ┌──────────────────────┐
│  k3s-server      │          │  rke2-server         │
│  ESO + ClusterSS │          │  ESO + ClusterSS     │
│  ◄── Vault KV    │          │  ◄── Vault KV        │
└──────────────────┘          └──────────────────────┘
```

Vault runs on `rancher-master`. Both `k3s-server` and `rke2-server` use Kubernetes auth to pull certificates from Vault via their own auth mount paths.

---

## Versions

| Component      | Version  |
|----------------|----------|
| cert-manager   | v1.16.2  |
| external-secrets | v2.5.0 |
| Vault          | 1.21+    |

> **ESO API Note:** All manifests use `apiVersion: external-secrets.io/v1`. If you are on ESO older than v0.17, change these to `v1beta1`. PushSecret stays at `v1alpha1` regardless.

> **Vault 1.21+ Note:** All Vault roles include `audience=vault`. This is required in Vault 1.21+. Without it, auth fails with "invalid audience claim".

---

## Repo Structure

```
vault-k8s-cert-sync/
├── vault/
│   ├── policies/
│   │   ├── cert-manager-policy.hcl     # read/write to kv/*
│   │   └── external-secrets-policy.hcl # read-only from kv/*
│   └── roles/
│       ├── rancher-master-roles.sh     # vault write commands for rancher-master
│       ├── k3s-cluster-roles.sh        # vault write commands for k3s-server
│       └── rke2-cluster-roles.sh       # vault write commands for rke2-server
├── clusters/
│   ├── rancher-master/
│   │   ├── serviceaccounts.yaml        # vault-auth, cert-manager, external-secrets, cert-pusher SAs
│   │   ├── clusterrolebinding.yaml     # vault-auth tokenreview binding
│   │   ├── secretstore.yaml            # SecretStore for external-secrets
│   │   └── pushsecret.yaml             # PushSecret for cert → Vault
│   ├── k3s-server/
│   │   ├── serviceaccounts.yaml        # vault-auth, external-secrets SAs
│   │   ├── clusterrolebinding.yaml     # vault-auth tokenreview binding
│   │   └── clustersecretstore.yaml     # ClusterSecretStore for external-secrets
│   └── rke2-server/
│       ├── serviceaccounts.yaml        # vault-auth, external-secrets SAs
│       ├── clusterrolebinding.yaml     # vault-auth tokenreview binding
│       └── clustersecretstore.yaml     # ClusterSecretStore for external-secrets
├── scripts/
│   ├── 01-configure-vault-auth.sh      # Full Vault auth setup for all three clusters
│   └── 02-test-externalsecret.sh       # Creates a test ExternalSecret and verifies sync
└── README.md
```

---

## Prerequisites

- Three Kubernetes clusters accessible via `kubectl` contexts named `rancher-master`, `k3s-server`, `rke2-server`
- Vault running and unsealed on `rancher-master`, accessible at your Vault URL
- cert-manager installed on `rancher-master`
- External Secrets Operator v2.x installed on all three clusters
- `vault` CLI available locally or you can exec into the vault pod

---

## Setup Order

Follow this order. Each step depends on the previous one.

### 1. Apply Vault Policies

```bash
# Copy policies to vault pod and apply
kubectl -n vault cp vault/policies/cert-manager-policy.hcl vault-0:/tmp/
kubectl -n vault cp vault/policies/external-secrets-policy.hcl vault-0:/tmp/

kubectl -n vault exec -it vault-0 -- sh
vault policy write cert-manager-policy /tmp/cert-manager-policy.hcl
vault policy write external-secrets-policy /tmp/external-secrets-policy.hcl
```

### 2. Create Service Accounts

```bash
# rancher-master
kubectl config use-context rancher-master
kubectl apply -f clusters/rancher-master/serviceaccounts.yaml
kubectl apply -f clusters/rancher-master/clusterrolebinding.yaml

# k3s-server
kubectl config use-context k3s-server
kubectl apply -f clusters/k3s-server/serviceaccounts.yaml
kubectl apply -f clusters/k3s-server/clusterrolebinding.yaml

# rke2-server
kubectl config use-context rke2-server
kubectl apply -f clusters/rke2-server/serviceaccounts.yaml
kubectl apply -f clusters/rke2-server/clusterrolebinding.yaml
```

### 3. Configure Vault Kubernetes Auth

Run the full setup script (edit the `KUBE_HOST` values inside first):

```bash
./scripts/01-configure-vault-auth.sh
```

### 4. Create Vault Roles

```bash
kubectl -n vault exec -it vault-0 -- sh

# rancher-master roles
bash /tmp/rancher-master-roles.sh   # after copying vault/roles/rancher-master-roles.sh to pod

# k3s roles
bash /tmp/k3s-cluster-roles.sh

# rke2 roles
bash /tmp/rke2-cluster-roles.sh
```

### 5. Apply SecretStores and PushSecret

```bash
kubectl config use-context rancher-master
kubectl apply -f clusters/rancher-master/secretstore.yaml
kubectl apply -f clusters/rancher-master/pushsecret.yaml

kubectl config use-context k3s-server
kubectl apply -f clusters/k3s-server/clustersecretstore.yaml

kubectl config use-context rke2-server
kubectl apply -f clusters/rke2-server/clustersecretstore.yaml
```

### 6. Test

```bash
./scripts/02-test-externalsecret.sh
```

---

## Troubleshooting

**`invalid audience claim` error during Vault auth**
All Vault roles must include `audience=vault`. This is required from Vault 1.21+. Check your role with `vault read auth/<mount>/role/<name>` and verify the audience field.

**`permission denied` on token review**
You are likely using the wrong JWT as the token reviewer. The `vault-auth` service account needs `system:auth-delegator`. Check with:
```bash
kubectl get clusterrolebinding vault-auth-tokenreview-binding -o yaml
```

**ESO SecretStore showing `invalid` status**
Check ESO version first. If on v0.17+, manifests must use `apiVersion: external-secrets.io/v1`, not `v1beta1`. Describe the SecretStore for the actual error:
```bash
kubectl describe secretstore vault-backend -n external-secrets
```

**PushSecret not syncing**
Check that the source secret exists and that the `cert-pusher` service account role in Vault has write permissions on `kv/*`:
```bash
kubectl describe pushsecret push-rajesh-cert -n certificates
```

---

## Related

- [Article on Medium](https://medium.com/@rajesh-kumar)
- [External Secrets Operator docs](https://external-secrets.io)
- [HashiCorp Vault Kubernetes auth docs](https://developer.hashicorp.com/vault/docs/auth/kubernetes)
- [Vault Secrets Operator (VSO)](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso) — HashiCorp's native alternative to ESO; worth evaluating if Vault is your only secrets backend
