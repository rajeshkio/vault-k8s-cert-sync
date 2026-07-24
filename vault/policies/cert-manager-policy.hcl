# cert-manager-policy.hcl
# Used by: cert-manager SA and cert-pusher SA on the primary cluster
# Purpose: read/write certificates into Vault KV v2

path "kv/*" {
  capabilities = ["create", "update", "read", "list"]
}

path "kv/metadata/*" {
  capabilities = ["create", "read", "update", "list"]
}
