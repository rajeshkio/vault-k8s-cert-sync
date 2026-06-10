# external-secrets-policy.hcl
# Used by: external-secrets SA on all three clusters
# Purpose: read-only access to Vault KV v2

path "kv/*" {
  capabilities = ["read", "list"]
}

path "kv/data/*" {
  capabilities = ["read", "list"]
}

path "kv/metadata/*" {
  capabilities = ["read", "list"]
}

path "secret/*" {
  capabilities = ["read", "list"]
}

path "secret/data/*" {
  capabilities = ["read", "list"]
}

path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
