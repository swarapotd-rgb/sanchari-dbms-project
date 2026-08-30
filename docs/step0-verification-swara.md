# Step 0 verification — Swara

**Date:** 30 August 2026
**Machine:** Windows 11, Docker Desktop 4.88.1 / Engine 29.7.2
**Method:** Path A (Docker), image `pgvector/pgvector:pg17-bookworm`

## Result: PASS — no `ERROR` lines

| Check | Value |
|---|---|
| PostgreSQL | **17.11** (Debian 17.11-1.pgdg12+2) |
| Database | `sanchari` |
| Port | 5432 |
| pgvector | **0.8.6** |
| btree_gist | 1.7 |
| Similarity ordering | waterfall → lake → fort ✓ |
| CHECK constraint test | passed |
| Server timezone | Etc/UTC |

> Note: the setup guide's example output showed pgvector 0.8.5; the Docker image
> supplied 0.8.6. Not a problem — only the *major* PostgreSQL version must match
> between team members.

## Command used

```powershell
Get-Content .\db\00_check_setup.sql | docker exec -i sanchari-db psql -U postgres -d sanchari
```

## Full output

```
=== 1. Which PostgreSQL am I talking to? ============================
                                                       postgres_version
------------------------------------------------------------------------------------------------------------------------------
 PostgreSQL 17.11 (Debian 17.11-1.pgdg12+2) on x86_64-pc-linux-gnu, compiled by gcc (Debian 12.2.0-14+deb12u1) 12.2.0, 64-bit
(1 row)

=== 2. Which database and user? =====================================
 database | connected_as | port
----------+--------------+------
 sanchari | postgres     | 5432
(1 row)

=== 3. Are the extensions we need available to install? =============
    name    | default_version | installed_version
------------+-----------------+-------------------
 btree_gist | 1.7             |
 vector     | 0.8.6           | 0.8.6
(2 rows)

=== 4. Install them =================================================
CREATE EXTENSION
NOTICE:  extension "vector" already exists, skipping
CREATE EXTENSION

=== 5. Confirm they are now installed ===============================
 extension  | version
------------+---------
 btree_gist | 1.7
 vector     | 0.8.6
(2 rows)

=== 6. Smoke test: create, insert, vector search, drop ==============
CREATE TABLE
INSERT 0 3
--- nearest neighbours to [1,2,3] by cosine distance (lake should beat fort):
   label   | cosine_distance
-----------+-----------------
 waterfall |        0.000000
 lake      |        0.008540
 fort      |        0.025368
(3 rows)

--- checking a CHECK constraint actually fires:
ALTER TABLE
DROP TABLE

=== 7. Timezone sanity =============================================
 TimeZone
----------
 Etc/UTC
(1 row)

        server_time_now
-------------------------------
 2026-08-30 11:28:41.566573+00
(1 row)
```

---

## Teammate

Step 0 pending. Must match on **PostgreSQL major version 17**. Record the result in
`docs/step0-verification-<name>.md` alongside this file.
