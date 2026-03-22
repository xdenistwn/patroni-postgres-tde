# Operations Runbook — TLS Management

## Executive Summary

Mutual TLS (mTLS) is a cornerstone of the security architecture in this stack. It is used to secure communication between Patroni and etcd, between etcd peer nodes, and between MinIO and MinKMS. In mTLS, not only does the client verify the server's certificate (standard TLS), but the server also demands a valid certificate from the client before allowing the connection. 

Because public Certificate Authorities (like Let's Encrypt or DigiCert) do not issue certificates for internal Docker hostnames (`etcd1`, `postgres-one`), we operate a custom internal Root Certificate Authority (Root CA). All service certificates must be signed by this custom Root CA to be trusted within the cluster.

## Why This Matters (Business / Compliance Context)

Encryption in transit is a non-negotiable requirement for zero-trust networks and compliance frameworks (ISO 27001 A.10, SOC 2 CC6.1, PCI-DSS Requirement 4). Furthermore, by using mTLS for etcd, we ensure that only authorised containers possessing a valid client certificate can read or alter the cluster state (acting as a strong authentication mechanism). If a certificate expires, the affected component will instantly fail to communicate, causing a severe outage. Proper TLS management is critical for both security and availability.

## Component Role in This Stack

- **Root CA:** Signs all other certificates. Trusted by `etcd`, `patroni`, `minio`, and `minkms`.
- **etcd certs:** Used for both server (`2379`, `2380`) and client authentication. Include SANs for `etcd1`, `etcd2`, `etcd3`.
- **PostgreSQL/Patroni certs:** Used as a client certificate to authenticate against etcd.
- **MinIO/MinKMS certs:** Secures the SSE-KMS API traffic on port `7373`.

## 1. Generating Certificates

All certificate management is handled by the `scripts/generate_tls_cert.sh` script, which uses `openssl` under the hood.

### Prerequisites

- OpenSSL installed on the machine running the script (`openssl version`).
- A clean directory for the output certificates. By default, the script creates them in the current working directory or a specified output folder.

### 1.1 Generate the Root CA

You must generate the Root CA *first*. This creates the `ca.crt` (public key) and `ca.key` (highly sensitive private key).

```bash
# Generate a Root CA valid for 10 years (3650 days)
./scripts/generate_tls_cert.sh --type ca --days 3650 --outdir ./certs
```

**Security Warning:** In a production environment, the `ca.key` should be generated offline, stored in a secure vault (like HashiCorp Vault's PKI engine or a physical HSM), and never placed on the database servers. For this Docker R&D environment, it is kept in `certs/` for convenience.

### 1.2 Generate Service Certificates

Once the Root CA exists in the output directory, you can generate certificates for the individual services. 

**etcd Certificates:**
These certificates require Subject Alternative Names (SANs) because etcd nodes communicate via their container hostnames (`etcd1`, `etcd2`, `etcd3`).

```bash
# Generate a single certificate valid for all etcd nodes and localhost
./scripts/generate_tls_cert.sh \
  --type service \
  --name etcd-cluster \
  --days 365 \
  --san "DNS:localhost,IP:127.0.0.1,DNS:etcd1,DNS:etcd2,DNS:etcd3" \
  --outdir ./certs
```
*This produces `public.crt` and `private.key` alongside the `ca.crt` in the `./certs` directory.*

**Patroni Client Certificates:**
Patroni only acts as a client to etcd, so it doesn't strictly need SANs for its own hostname, but generating one with standard SANs is good practice.

```bash
./scripts/generate_tls_cert.sh \
  --type service \
  --name patroni-client \
  --days 365 \
  --san "DNS:localhost,IP:127.0.0.1,DNS:postgres-one,DNS:postgres-two" \
  --outdir ./postgres/certs
```

### 1.3 Distributing Certificates

After generation, the certificates must be placed in the correct paths expected by Docker Compose volumes:

1. **etcd:** Copy `ca.crt`, `public.crt`, `private.key` to `etcd/node1/certs/` (and node2/node3).
2. **PostgreSQL/Patroni:** Copy `ca.crt`, `public.crt`, `private.key` to `postgres/certs/`.
3. **MinIO/MinKMS:** Copy `ca.crt`, `public.crt`, `private.key` to `minio/certs/`.

Ensure file permissions on the `.key` files are restricted:
```bash
chmod 600 **/*.key
```

---

## 2. Certificate Renewal and Rotation

Service certificates are generated with a finite lifespan (e.g., `--days 365`). When a certificate expires, components will immediately reject connections (e.g., Patroni will lose its etcd lock and the database will go offline).

### Monitoring Expiry

You can check the expiration date of any generated certificate:

```bash
openssl x509 -enddate -noout -in ./certs/public.crt

# Output example:
# notAfter=Mar 20 14:30:00 2027 GMT
```

### Rotation Procedure

To rotate expiring service certificates without causing a complete cluster outage, you must replace the certificates on a rolling basis.

1. **Generate the new certificate:**
   Re-run the `./scripts/generate_tls_cert.sh` command using the *existing* Root CA. 
   *(Do NOT regenerate the Root CA, or you will break trust across the entire cluster forcing a hard restart of everything).*

2. **Deploy to a Replica (postgres-two):**
   - Copy the new `public.crt` and `private.key` to the replica's cert directory.
   - Restart the replica Patroni container:
     ```bash
     docker restart postgres-two
     ```
   - Verify it rejoins the cluster successfully viewing the Patroni logs.

3. **Deploy to the Leader (postgres-one):**
   - Perform a manual switchover to demote the leader (see `03-failover-switchover.md`).
   - Copy the new certificates to `postgres-one`.
   - Restart the new replica container.

4. **Deploy to etcd Nodes (Rolling):**
   etcd supports a rolling restart. Replace the certs on `etcd3`, restart it, and wait for it to rejoin quorum. Repeat for `etcd2`, then `etcd1`.

---

## Troubleshooting TLS Errors

**Symptoms of a TLS Failure:**
- Patroni log: `Waiting for leader to bootstrap` or `etcd connection refused/certificate verify failed`.
- etcd log: `rejected connection from "x.x.x.x:yyyy" (error "tls: failed to verify client certificate")`.
- MinIO log: `KMS error: tls: unknown certificate authority`.

**Diagnostic Steps:**

1. **Check Expiry:**
   Verify the cert hasn't expired (`openssl x509 -enddate...`).

2. **Verify Trust Chain:**
   Ensure the service certificate was actually signed by the Root CA you are using in the config.
   ```bash
   openssl verify -CAfile certs/ca.crt certs/public.crt
   # Expected: certs/public.crt: OK
   ```

3. **Check Subject Alternative Names (SANs):**
   If etcd is rejecting Patroni, ensure Patroni connects using a hostname listed in the etcd certificate's SANs, and vice versa.
   ```bash
   openssl x509 -text -noout -in certs/public.crt | grep -A 1 "Subject Alternative Name"
   ```

4. **File Permissions:**
   etcd and Patroni will refuse to start if the `.key` file is world-readable. Ensure `chmod 600`.

## References

- [etcd TLS Setup](https://etcd.io/docs/v3.5/op-guide/security/)
- [OpenSSL Certificate Verification](https://www.openssl.org/docs/man3.0/man1/openssl-verify.html)
- [scripts/generate_tls_cert.sh](../../scripts/generate_tls_cert.sh)
