# pgAudit Production Tradeoffs

## Overview

pgAudit hooks into PostgreSQL's logging facility to emit structured audit records for session and object-level activity. It writes to the Postgres log stream — not to any table inside the database. That design choice is both its strength and the source of most of its tradeoffs.

---

## Tradeoff Table

| Tradeoff | Impact | Root Cause | Solution |
|---|---|---|---|
| Query latency overhead | High | pgAudit logs synchronously in the same backend process. Enabling `READ` on a busy database adds per-query formatting and I/O cost on every SELECT. | Restrict session logging to `DDL, WRITE` only. Use object-level auditing scoped to specific sensitive tables for READ — not global. `ALTER SYSTEM SET pgaudit.log = 'DDL, WRITE';` |
| Log volume and storage cost | High | `pgaudit.log_catalog = on` by default causes every ORM or pooler query touching system tables to be logged. Broad scope multiplies this further. | Set `pgaudit.log_catalog = off` to suppress system table noise. Configure `log_rotation_age` and `log_rotation_size` to control file growth. Ship logs to a SIEM (ELK, Splunk, Datadog) for compressed, long-term storage off the database host. |
| Logs not queryable via SQL | Medium | pgAudit writes only to the Postgres log stream — not to any table. You cannot run SQL against audit records without external tooling. | Ship logs to ELK, Splunk, or Datadog for searchable storage. For SQL-queryable history on business-critical tables, complement pgAudit with application-layer audit tables (separate concern, not a replacement). |
| PII exposed in logs | High | With `pgaudit.log_parameter = on`, actual bind parameter values — including passwords, SSNs, card numbers — are written to the log in plaintext. | Keep `pgaudit.log_parameter = off` (the default). Enable it only temporarily and selectively if forensic detail is required — never as a permanent setting on tables containing PII. Ensure log storage is encrypted at rest and access-controlled. |
| Requires a restart to enable | Medium | pgAudit must be loaded via `shared_preload_libraries`, which is a startup-time parameter — changing it requires a PostgreSQL restart. | Add pgAudit to `shared_preload_libraries` from day one, even before you need it. Set `pgaudit.log = 'none'` initially — near-zero overhead. Activate log classes at runtime with `pg_reload_conf()`, no restart needed. |
| Noisy service accounts | Low | Connection poolers, monitoring agents, and ORM frameworks issue frequent low-value queries. Auditing them inflates log volume without compliance benefit. | Exclude specific roles or databases using per-role settings: `ALTER ROLE monitoring_user SET pgaudit.log = 'none';` or `ALTER DATABASE internal_tools SET pgaudit.log = 'none';` |

---

## Recommended Baseline Config for Production

```sql
-- postgresql.conf
shared_preload_libraries = 'pgaudit'

-- After restart, apply at runtime (no further restart needed)
ALTER SYSTEM SET pgaudit.log = 'DDL, WRITE';
ALTER SYSTEM SET pgaudit.log_catalog = off;
ALTER SYSTEM SET pgaudit.log_parameter = off;
SELECT pg_reload_conf();

-- Exclude noisy service accounts
ALTER ROLE monitoring_user SET pgaudit.log = 'none';
ALTER ROLE pgbouncer SET pgaudit.log = 'none';
```

---

## Key Rule

Add pgAudit to `shared_preload_libraries` from day one with `pgaudit.log = 'none'`. The extension adds negligible overhead when logging is inactive. You can then activate specific log classes at runtime without a restart — the restart is a one-time cost at setup, not an ongoing operational constraint.
