1. if using container, go inside the container vault service.
2. set the VAULT_TOKEN=YOUR_TOKEN (you can use root / auth user) for authorization
3. set the export VAULT_SKIP_VERIFY=true (bypass tls handshake if local setup)
4. setup kv engine for postgres
vault secrets enable -path=pg_tde -version=2 kv
5. setup policy for pg_tde:
```
vault policy write pg_tde-policy - <<EOF
path "pg_tde/data/*" {
  capabilities = ["read", "create", "update", "list"]
}

path "pg_tde/metadata/*" {
  capabilities = ["read", "list"]
}

path "sys/mounts/*" {
  capabilities = ["read"]
}
EOF
```

6. enable approle (this use for client token such: postgres service, minkms service)
```
vault auth enable approle
```

7. create pg_tde-policy approle
```
vault write auth/approle/role/tde-role policies="pg_tde-policy"
```

8. Generate a token with pg_tde-policy (for pg_tde in postgres service later)
```
vault token create -policy="pg_tde-policy" -ttl=8760h -field=token
```
you should get token like this: hvs.WKwkwkwkWK_sample_dkRreEFOYU1ZUW5ZY3BUMEhFRXg