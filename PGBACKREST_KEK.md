# pgBackRest Envelope Key Encryption

Encrypts the pgBackRest `cipher-pass` using a two-layer **envelope encryption** scheme.  
The KEK lives in Vault. The encrypted DEK lives in `/data/db`. No plaintext key ever touches disk.

---

## How It Works

```
Vault (KEK)
    │
    │  encrypts
    ▼
/data/db/pgbackrest_dek.enc   ──►  pgbackrest-get-cipher-pass.sh ──►  In-Memory Cipher Pass
  (encrypted DEK on disk)                                                        │
                                                                                 ▼
                                                                        pgbackrest backup/wal
```

| Layer | Name | Where | What it does |
|-------|------|-------|-------------|
| KEK   | Key Encryption Key | HashiCorp Vault (`secret/data/pgbackrest/kek`) | Encrypts the DEK |
| DEK   | Data Encryption Key | `/data/db/pgbackrest_dek.enc` | The actual pgBackRest `cipher-pass`, AES-256-CBC encrypted |

- **AES-256-CBC** is used to encrypt the DEK with the KEK.  
- **HMAC-SHA256** is stored alongside to detect tampering.  
- **Maximum Security:** No plaintext keys ever touch the filesystem or RAM-disks.
- **Runtime Decryption:** The KEK is fetched from Vault and the DEK is decrypted in-memory for every call.
- **Instant Rotation:** Replacing the encrypted file on any node (primary or replica) during rotation instantly updates that node's password for the next run.


---

## Files

| Script | Purpose |
|--------|---------|
| `scripts/pgbackrest-keymgmt-init.sh` | **First-time setup**: generate KEK + DEK, store KEK in Vault, write encrypted DEK to `/data/db` |
| `scripts/pgbackrest-keymgmt-rotate.sh` | **Manual rotation**: generate new KEK + DEK, re-encrypt, update Vault and all nodes |
| `scripts/pgbackrest-get-cipher-pass.sh` | **Runtime resolver**: fetch KEK from Vault, decrypt DEK, print plaintext cipher-pass to stdout |
| `scripts/pgbackrest-backup.sh` | Updated backup script: calls resolver at runtime |

DEK storage:
- `/data/db/pgbackrest_dek.enc` — encrypted DEK (`IV:encrypted_b64:hmac`)
- `/data/db/pgbackrest_dek.meta` — version + timestamp metadata

---

## First-Time Setup

This runs automatically as the `pgbackrest-keymgmt-init` service in docker-compose.  
To run manually inside the cluster:

```bash
docker-compose exec postgres-one bash /scripts/pgbackrest-keymgmt-init.sh
```

---

## Rotating KEK + DEK (Manual)

Run from the **host machine** (not inside a container):

```bash
export VAULT_ADDR="http://localhost:8200"
export VAULT_TOKEN="<your-vault-token>"

./scripts/pgbackrest-keymgmt-rotate.sh
```

The rotation script will:
1. Read the old KEK from Vault and decrypt the current DEK (integrity checked via HMAC)
2. Generate a new KEK + new DEK
3. Encrypt the new DEK with the new KEK
4. Atomically write the new encrypted DEK to the **primary** container's `/data/db`
5. Update the **new KEK** in Vault
6. Copy the new encrypted DEK to all **replica** containers

> **No restart needed.** The cipher-pass is resolved per-run, so the next WAL archive or backup automatically uses the new DEK.

---

## How Replicas Get the New DEK

Since each postgres container has its **own** Docker volume for `/data/db`, the rotation script explicitly copies the new `pgbackrest_dek.enc` file to all replica containers after updating the primary. This mirrors the approach used by `pg_tde` key propagation.

> The DEK file is synced by the rotation script — not by Postgres replication (which only replicates WAL, not arbitrary files).

---

## Vault Setup

The `vault-init.sh` script sets up:
- KV v2 mount at `secret/` for pgBackRest KEK
- Policy `pgbackrest-policy` with read/write to `secret/data/pgbackrest/*`
- Dedicated Vault token saved to `/etc/postgresql/secrets/pgbackrest_vault_token.txt`

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VAULT_ADDR` | `http://vault:8200` | Vault server address |
| `VAULT_TOKEN` | *(from token file)* | Vault token (or use `VAULT_TOKEN_FILE`) |
| `VAULT_TOKEN_FILE` | `/etc/postgresql/secrets/pgbackrest_vault_token.txt` | Path to Vault token file |
| `VAULT_KEK_PATH` | `pgbackrest/kek` | KV path for the KEK |
| `VAULT_SECRET_MOUNT` | `secret` | KV v2 mount name |
| `DEK_FILE` | `/data/db/pgbackrest_dek.enc` | Path to encrypted DEK file |
| `DEK_META_FILE` | `/data/db/pgbackrest_dek.meta` | Path to DEK metadata file |
