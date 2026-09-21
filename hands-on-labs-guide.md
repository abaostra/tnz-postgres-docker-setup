# Hands-On Postgres Labs (Tanzu + Open-Source)

This picks up right after **`tanzu-postgres-docker-guide.md`** — you should already have a container running (`postgres-18` for Tanzu, or `postgres-oss` for the open-source image), reachable with:

```bash
docker exec -it <container> psql -U appuser -d appdb
```

Everything below was tested end-to-end on both images. Where a command differs between them, both versions are shown. Swap in your own container name if you didn't use the defaults.

## Step 0: Load the sample data

The labs below need a `customers` table and an `orders` table with real row volume (the indexing lab in Step 6 needs thousands of rows to actually show a plan change — a handful of rows won't do it). `seed-sample-data.sql`, included alongside this guide, creates both.

```bash
docker cp seed-sample-data.sql <container>:/tmp/seed.sql
docker exec <container> psql -U appuser -d appdb -f /tmp/seed.sql
```

Confirm it worked:
```sql
\dt
-- customers, orders
SELECT count(*) FROM orders;
-- 50025
```

If you skip this step, every query below that references `customers` or `orders` will fail with `relation "customers" does not exist` — that's expected, not a bug; just come back and run this first.

## Step 1: Observe the server

Postgres runs **one operating-system process per client connection** — a supervisor process (the **postmaster**) forks a dedicated **backend** process for each connection.

```bash
ps aux | grep postgres
```
Run this on the **VM host directly**, not inside the container — Docker doesn't hide containerized processes from the host's own process table, so this works as-is. You'll see the main `postgres` process plus utility processes: `io worker`, `checkpointer`, `background writer`, `walwriter`, `autovacuum launcher`, `logical replication launcher`.

```sql
SHOW shared_buffers;   -- 128MB — Postgres's own page cache
SHOW work_mem;         -- 4MB — memory per sort/hash operation, per query
SELECT count(*) FROM pg_stat_activity;
```
Open a second `docker exec -it <container> psql ...` session in another terminal and re-run the count — it goes up by exactly 1.

**Compared to Oracle/SQL Server:** Oracle uses a similar multi-process architecture but can multiplex connections through shared server processes; Postgres always gives you one process per connection, which is exactly why a pooler (PgBouncer) matters more for Postgres at scale. SQL Server uses one process with many lightweight threads instead — cheaper to hold connections open, at the cost of less OS-level isolation between sessions.

## Step 2: psql basics

| Command | What it shows |
|---|---|
| `\l` | List databases |
| `\dt` | List tables in the current schema |
| `\d <table>` | Describe a table — columns, types, indexes, FKs |
| `\du` | List roles |
| `\dn` | List schemas |
| `\dx` | List installed extensions |
| `\timing` | Toggle query timing |
| `\x` | Toggle expanded (one-column-per-line) output |
| `\q` | Quit |

```sql
\l                                   -- appdb, postgres, template0, template1
\dt                                  -- customers, orders
\d customers                         -- id (PK), name, city, country; referenced by orders.customer_id
\timing on
SELECT * FROM customers LIMIT 5;
\x
SELECT * FROM customers LIMIT 5;     -- same 5 rows, one field per line
\x
\timing off
```

**A real gotcha, confirmed on both images:** connecting straight from the VM **host** with `psql "postgresql://appuser@localhost/appdb"` fails with `bash: psql: command not found` — no client is installed on a bare VM host by default. Stick with `docker exec -it <container> psql ...` (what this whole guide uses). If you specifically want a host-side connection string, `sudo dnf install -y postgresql` gets you a client (an older v13 client against our v18 server — still fully compatible for everything here), and then `PGPASSWORD=<password> psql "postgresql://appuser@localhost:5432/appdb"` works.

**Compared to Oracle/SQL Server:** Oracle's equivalent client is `sqlplus`; SQL Server's is `sqlcmd`/SSMS. Neither has a direct equivalent to psql's meta-commands — `SELECT * FROM information_schema.tables` works identically in all three if you'd rather query the catalog directly.

## Step 3: Core objects & the logical model

One running Postgres server (a **cluster** — nothing to do with clustering/HA) can host many **databases**. Each database has **schemas** (namespaces), and each schema holds tables, views, indexes, and sequences. A fully-qualified name is `schema.table`.

```sql
\dn                              -- public (pg_database_owner) only, before you create anything
\du                              -- appuser: Superuser, Create role, Create DB, Replication, Bypass RLS
CREATE SCHEMA training;
CREATE SEQUENCE training.ticket_no;
SELECT nextval('training.ticket_no');   -- 1
\dt training.*
```

⚠️ **Heads-up:** `\dt training.*` on an empty schema doesn't print `(0 rows)` — it prints an **error-styled line**: `Did not find any tables named "training.*".` That's normal psql behavior, not a bug — the schema really is empty (it has a sequence, not a table, and `\dt` only lists tables).

A "user" is just a role with the `LOGIN` privilege set — same underlying object. `GENERATED ALWAYS AS IDENTITY` (or a standalone sequence like the one above) auto-generates primary keys.

**Compared to Oracle/SQL Server:** Oracle historically ties a "schema" to what most people call a "user" — Postgres's cluster → database → schema → table hierarchy is closer to SQL Server's. Postgres and Oracle both have real standalone sequences; SQL Server didn't get sequences until 2012 (before that, only `IDENTITY` columns), which is why SQL Server users often reach for `IDENTITY` reflexively.

## Step 4: SQL & data-type essentials

```sql
CREATE TABLE demo_orders (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    total numeric(10,2)
);
INSERT INTO demo_orders (total) VALUES (19.99), (45.00), (120.50);
SELECT * FROM demo_orders WHERE total > 20 ORDER BY total;

SELECT o.id, c.name, o.total
FROM orders o JOIN customers c ON c.id = o.customer_id
WHERE o.total > 400
ORDER BY o.total DESC
LIMIT 5;

SELECT country, count(*) AS customers FROM customers GROUP BY country ORDER BY customers DESC;

EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders WHERE customer_id = 42;
```

Data types worth knowing:

| Type | Use it for |
|---|---|
| `numeric` | Exact money — never rounds |
| `text` / `varchar` | Strings — identical under the hood in Postgres |
| `boolean` | Native true/false |
| `timestamptz` | A real moment in time — prefer over bare `timestamp` |
| `jsonb` | Binary JSON — indexable, queryable |
| `uuid` | Compact unique IDs |
| Arrays | Native multi-valued columns, e.g. `text[]` |

Constraints — primary key, foreign key, unique, not-null, check — are all enforced at the database level, not just in application code.

**Compared to Oracle/SQL Server:** Postgres treats `text` and `varchar` identically internally (no performance reason to prefer one) — Oracle's `VARCHAR2` has a hard byte limit and treats an empty string as `NULL`, which trips up people moving from Oracle (Postgres, like SQL Server, treats them as distinct). Postgres's `jsonb` predates native JSON support in both Oracle (21c) and SQL Server, and is generally the most mature of the three for indexed JSON queries. Neither Oracle nor SQL Server has a native array column type the way Postgres does.

## Step 5: Transactions & MVCC

`BEGIN` starts a transaction, `COMMIT` makes it permanent, `ROLLBACK` undoes it. Postgres's default isolation level is **Read Committed**.

**MVCC — the centerpiece:** Postgres never overwrites a row in place. An `UPDATE` writes a *new* row version and marks the old one expired. Readers see a consistent snapshot, so readers never block writers and writers never block readers. The consequence: expired versions (**dead tuples**) pile up as **bloat**, and a background process called **autovacuum** reclaims that space.

Open two terminals, both running `docker exec -it <container> psql -U appuser -d appdb`:

**Terminal A:**
```sql
BEGIN;
UPDATE customers SET country='SG' WHERE id=1;
-- don't commit yet
```

**Terminal B, while A is uncommitted:**
```sql
SELECT country FROM customers WHERE id=1;   -- 'IN' — the OLD value; A's change is invisible
```

**Back in Terminal A:**
```sql
COMMIT;
```

**Terminal B, re-read:**
```sql
SELECT country FROM customers WHERE id=1;   -- 'SG' — now visible
```

**Either terminal:**
```sql
SELECT n_dead_tup FROM pg_stat_user_tables WHERE relname='customers';  -- 1
VACUUM customers;
SELECT n_dead_tup FROM pg_stat_user_tables WHERE relname='customers';  -- back to 0
```

**Compared to Oracle/SQL Server:** Oracle also uses MVCC, but reconstructs old row versions on demand from **undo segments** rather than keeping them in the table — which is why Oracle can throw `ORA-01555: snapshot too old` (no Postgres equivalent). SQL Server, by default, uses **lock-based** concurrency where readers *can* block writers — genuinely different from Postgres's default. SQL Server has an MVCC-style `SNAPSHOT` isolation mode, but it's opt-in, not the out-of-the-box default the way it is in Postgres.

## Step 6: Indexes & the planner

An index (like the index at the back of a book) lets Postgres find rows without scanning every one — at the cost of extra disk space and slower writes. **You don't force an index — the planner decides**, based on table statistics.

```sql
-- before an index:
EXPLAIN (ANALYZE) SELECT * FROM orders WHERE customer_id = 42;
-- Seq Scan on orders (actual time≈2.7-3.4ms rows=25) - Rows Removed by Filter: 50000

CREATE INDEX ON orders (customer_id);

-- after:
EXPLAIN (ANALYZE) SELECT * FROM orders WHERE customer_id = 42;
-- Bitmap Heap Scan -> Bitmap Index Scan (actual time≈0.09-0.11ms rows=25)
```
Roughly a 25-30x speedup, confirmed on both images. This needs Step 0's 50,000-row seed to show up — on a 5-row table the planner correctly prefers a sequential scan even with an index present.

**B-Tree** (the default) handles equality, ranges, and sorting. **BRIN** is for big, physically-ordered data (e.g. a timestamp column on an append-only table). GIN (`jsonb`/arrays/full-text) and GiST (spatial) exist too, beyond this guide's scope.

**Compared to Oracle/SQL Server:** the "planner decides" model is universal (`EXPLAIN` ↔ Oracle's `EXPLAIN PLAN` ↔ SQL Server's execution plan). BRIN has no direct Oracle/SQL Server equivalent — the closest analogues are Oracle's Exadata-specific zone maps or SQL Server's columnstore segment elimination.

## Step 7: Observability

Postgres reports on itself through the `pg_stat_*` family of views — no separate agent needed to see what's happening right now.

```sql
SELECT pid, state, query FROM pg_stat_activity WHERE state <> 'idle';
SELECT * FROM pg_locks LIMIT 10;
SELECT relname, n_dead_tup FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 5;
```

Vocabulary worth knowing: **connections** (active sessions), **locks** (who's blocked on whom), **wait events** (what a backend is stuck on), **replication lag**, **dead tuples**.

**Compared to Oracle/SQL Server:** Oracle's equivalent is the `V$` views (`V$SESSION`, `V$LOCK`); SQL Server's is Dynamic Management Views (`sys.dm_exec_sessions`, `sys.dm_tran_locks`). Same idea everywhere — the engine exposes its own state as queryable views — only the naming convention changes.

## Step 8 (Advanced/optional): Extensions

Installed with `CREATE EXTENSION`, listed with `\dx`. This section needs you to recreate the container — do it against the same data directory so you don't lose anything from Steps 0-7.

### `pg_stat_statements`

Fails without preload, on both images:
```sql
CREATE EXTENSION pg_stat_statements;
SELECT count(*) FROM pg_stat_statements;
-- ERROR:  pg_stat_statements must be loaded via "shared_preload_libraries"
```

**Fix — recreate the container with the setting added** (this works on both images the same way):

Tanzu:
```bash
docker rm -f postgres-18
docker run -d --name postgres-18 \
  -e POSTGRES_USER=appuser -e POSTGRES_PASSWORD=<your-password> -e POSTGRES_DB=appdb \
  -v /data/postgres-18:/var/lib/pgsql/data -p 5432:5432 --restart unless-stopped \
  tanzu-sql-postgres.packages.broadcom.com/postgres-oci:v18.6 \
  -c shared_preload_libraries=pg_stat_statements
```

Open-source:
```bash
docker rm -f postgres-oss
docker run -d --name postgres-oss \
  -e POSTGRES_USER=appuser -e POSTGRES_PASSWORD=<your-password> -e POSTGRES_DB=appdb \
  -v /data/postgres-oss:/var/lib/postgresql -p 5432:5432 --restart unless-stopped \
  postgres:latest \
  -c shared_preload_libraries=pg_stat_statements
```

Then:
```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SELECT count(*) FROM pg_stat_statements;   -- non-zero, it's tracking queries now
```

### `pgvector`

Not available by default on either image (`ERROR: extension "vector" is not available`).

**Open-source (Debian-based):**
```bash
docker exec postgres-oss apt-get update -qq
docker exec postgres-oss apt-get install -y postgresql-18-pgvector
```

**Tanzu (RHEL-based):**
```bash
docker exec postgres-18 rpm -Uvh https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
docker exec postgres-18 microdnf install -y pgvector_18
```
⚠️ On Tanzu this pulls in an entire second community-Postgres 18 server package plus `systemd`/`dbus` as dependencies — heavier than ideal, but it doesn't disturb the running Tanzu server and the extension does load against it.

Verify on either image:
```sql
CREATE EXTENSION vector;
CREATE TABLE vector_demo (id serial primary key, embedding vector(3));
INSERT INTO vector_demo (embedding) VALUES ('[1,2,3]'), ('[4,5,6]');
SELECT id, embedding, embedding <-> '[1,2,3]' AS distance FROM vector_demo ORDER BY distance;
DROP TABLE vector_demo;
```

### `PostGIS`

**Open-source:** works cleanly —
```bash
docker exec postgres-oss apt-get install -y postgresql-18-postgis-3
```
```sql
CREATE EXTENSION postgis;
SELECT postgis_version();   -- 3.6 USE_GEOS=1 USE_PROJ=1 USE_STATS=1
```

**Tanzu:** don't bother trying — `microdnf install postgis35_18` fails with an unresolvable dependency (`gdal313-libs` needs `libqhull_r.so.7`, which isn't in EPEL, UBI, or PGDG for this image). If you specifically need PostGIS, use the open-source path for that part of the demo.

**Compared to Oracle/SQL Server:** extensions are a distinctly Postgres concept — Oracle and SQL Server ship most of this functionality (spatial, full-text, JSON) built into the core engine rather than as install-on-demand modules.

## Step 9 (Advanced/optional): Replication

A **replica** (standby) keeps a live copy of the database by streaming the WAL from the **primary**. This needs a second container and a few non-obvious fixes — do this only if you want the full experience; it's not required for Steps 0-8. Pick the block for your image; both were tested exactly as written.

### Tanzu

```bash
# 1. a user-defined network - the default bridge doesn't do container-name DNS resolution
docker network create pglab
docker network connect pglab postgres-18

# 2. the catch-all "host all all all" line in pg_hba.conf does NOT cover replication -
#    add an explicit line and reload
docker exec postgres-18 bash -c 'echo "host replication all 172.18.0.0/16 scram-sha-256" >> /var/lib/pgsql/data/pg_hba.conf'
docker exec postgres-18 psql -U appuser -d appdb -c "SELECT pg_reload_conf();"

# 3. pg_basebackup waits on "waiting for checkpoint" until you force one
docker exec postgres-18 psql -U appuser -d appdb -c "CHECKPOINT;"

# 4. seed the replica's data directory from a live base backup
mkdir -p /data/postgres-18-replica
docker run --rm --network pglab -v /data/postgres-18-replica:/var/lib/pgsql/data -e PGPASSWORD=<your-password> \
  --entrypoint /opt/vmware/postgres/18/bin/pg_basebackup \
  tanzu-sql-postgres.packages.broadcom.com/postgres-oci:v18.6 \
  -h postgres-18 -U appuser -D /var/lib/pgsql/data -R -P

# 5. start it - it comes up in standby mode automatically
docker run -d --name postgres-18-replica --network pglab \
  -v /data/postgres-18-replica:/var/lib/pgsql/data \
  tanzu-sql-postgres.packages.broadcom.com/postgres-oci:v18.6
```

### Open-source

```bash
# 1. a user-defined network - the default bridge doesn't do container-name DNS resolution
docker network create pglab
docker network connect pglab postgres-oss

# 2. the catch-all "host all all all" line in pg_hba.conf does NOT cover replication -
#    add an explicit line and reload
docker exec postgres-oss bash -c 'echo "host replication all 172.18.0.0/16 scram-sha-256" >> /var/lib/postgresql/18/docker/pg_hba.conf'
docker exec postgres-oss psql -U appuser -d appdb -c "SELECT pg_reload_conf();"

# 3. pg_basebackup waits on "waiting for checkpoint" until you force one
docker exec postgres-oss psql -U appuser -d appdb -c "CHECKPOINT;"

# 4. seed the replica's data directory from a live base backup
mkdir -p /data/postgres-oss-replica && chown 999:999 /data/postgres-oss-replica
docker run --rm --network pglab -v /data/postgres-oss-replica:/var/lib/postgresql -e PGPASSWORD=<your-password> \
  --user 999:999 postgres:latest \
  pg_basebackup -h postgres-oss -U appuser -D /var/lib/postgresql/18/docker -R -P

# 5. start it - it comes up in standby mode automatically
docker run -d --name postgres-oss-replica --network pglab \
  -v /data/postgres-oss-replica:/var/lib/postgresql \
  postgres:latest
```

Verify (either image, swap in the right container names):
```sql
-- on the primary:
SELECT pg_is_in_recovery();                                      -- f
SELECT client_addr, state, sync_state FROM pg_stat_replication;  -- streaming, async
-- on the replica:
SELECT pg_is_in_recovery();                                      -- t
```
```bash
docker exec postgres-18 psql -U appuser -d appdb -c "INSERT INTO customers (name, city, country) VALUES ('ReplicaTest', 'Sydney', 'AU');"
docker exec postgres-18-replica psql -U appuser -d appdb -c "SELECT * FROM customers WHERE name='ReplicaTest';"
```
Write on the primary, read on the replica a second later — the row shows up.

**Compared to Oracle/SQL Server:** the WAL/redo-log/transaction-log idea is the same append-only, write-before-data-files concept under three names. **Patroni** (using **etcd** as its source of truth) and **HAProxy** automate the promotion/failover decision on top of this same streaming mechanism — that orchestration layer isn't covered here.

## Step 10 (Advanced/optional): Backup & point-in-time recovery (PITR)

A base backup plus the archived WAL lets you restore to any specific moment — "rewind to just before a bad change." The enterprise tool to know: **pgBackRest**. This is the most involved section — three real gotchas are called out inline. Pick the block for your image.

### Tanzu

```bash
# enable WAL archiving (recreate the container against the same data dir, plus an archive dir)
# ⚠️ gotcha #1 (Tanzu-specific): chown the archive dir to UID 26 (Tanzu's postgres system user) BEFORE
# starting the primary, not after. If the primary starts against a root-owned archive
# dir, its archiver hits "Permission denied" and backs off for ~60s before retrying -
# fixing ownership later doesn't retroactively archive what failed in that window, and
# a restore attempted too soon after will be missing segments.
mkdir -p /data/postgres-18-archive && chown 26:26 /data/postgres-18-archive
docker rm -f postgres-18
docker run -d --name postgres-18 --network pglab \
  -v /data/postgres-18:/var/lib/pgsql/data -v /data/postgres-18-archive:/archive -p 5432:5432 \
  -e POSTGRES_USER=appuser -e POSTGRES_PASSWORD=<your-password> -e POSTGRES_DB=appdb --restart unless-stopped \
  tanzu-sql-postgres.packages.broadcom.com/postgres-oci:v18.6 \
  -c archive_mode=on -c archive_command='cp %p /archive/%f'

# take a fresh base backup
mkdir -p /data/postgres-18-pitr-basebackup
docker run --rm --network pglab -v /data/postgres-18-pitr-basebackup:/backup -e PGPASSWORD=<your-password> \
  --entrypoint /opt/vmware/postgres/18/bin/pg_basebackup \
  tanzu-sql-postgres.packages.broadcom.com/postgres-oci:v18.6 \
  -h postgres-18 -U appuser -D /backup -P
```

```sql
-- "good" marker, then force the WAL segment to actually reach the archive:
INSERT INTO customers (name, city, country) VALUES ('PITR-GOOD-MARKER', 'Good City', 'ZZ');
SELECT now();   -- write this timestamp down
SELECT pg_switch_wal();
-- ⚠️ gotcha #2: WAL only archives once a segment is FULL. A quick insert-then-drop stays
-- in one still-open segment that never reaches the archive - always force a switch after
-- anything you want recoverable in a quick demo.

-- the "bad" change:
DROP TABLE customers CASCADE;
SELECT pg_switch_wal();
```

Restore into a fresh copy of the base backup, targeting the timestamp just before the drop:
```bash
rm -rf /data/postgres-18-pitr-restore && mkdir -p /data/postgres-18-pitr-restore
cp -a /data/postgres-18-pitr-basebackup/. /data/postgres-18-pitr-restore/
touch /data/postgres-18-pitr-restore/recovery.signal
cat >> /data/postgres-18-pitr-restore/postgresql.auto.conf <<EOF
restore_command = 'cp /archive/%f %p'
recovery_target_time = '<timestamp from above>'
recovery_target_action = 'promote'
EOF

docker run -d --name postgres-18-pitr --network pglab \
  -v /data/postgres-18-pitr-restore:/var/lib/pgsql/data -v /data/postgres-18-archive:/archive \
  tanzu-sql-postgres.packages.broadcom.com/postgres-oci:v18.6
```

### Open-source

```bash
# enable WAL archiving (recreate the container against the same data dir, plus an archive dir)
mkdir -p /data/postgres-oss-archive && chown 999:999 /data/postgres-oss-archive && chmod 700 /data/postgres-oss-archive
docker rm -f postgres-oss
docker run -d --name postgres-oss --network pglab \
  -v /data/postgres-oss:/var/lib/postgresql -v /data/postgres-oss-archive:/archive -p 5432:5432 \
  -e POSTGRES_USER=appuser -e POSTGRES_PASSWORD=<your-password> -e POSTGRES_DB=appdb --restart unless-stopped \
  postgres:latest -c archive_mode=on -c archive_command='cp %p /archive/%f'

# take a fresh base backup
mkdir -p /data/postgres-oss-pitr-basebackup && chown 999:999 /data/postgres-oss-pitr-basebackup
docker run --rm --network pglab -v /data/postgres-oss-pitr-basebackup:/backup -e PGPASSWORD=<your-password> \
  --user 999:999 postgres:latest pg_basebackup -h postgres-oss -U appuser -D /backup -P
```

```sql
-- "good" marker, then force the WAL segment to actually reach the archive:
INSERT INTO customers (name, city, country) VALUES ('PITR-GOOD-MARKER', 'Good City', 'ZZ');
SELECT now();   -- write this timestamp down
SELECT pg_switch_wal();
-- ⚠️ gotcha #2: WAL only archives once a segment is FULL. A quick insert-then-drop stays
-- in one still-open segment that never reaches the archive - always force a switch after
-- anything you want recoverable in a quick demo.

-- the "bad" change:
DROP TABLE customers CASCADE;
SELECT pg_switch_wal();
```

Restore into a fresh copy of the base backup, targeting the timestamp just before the drop:
```bash
rm -rf /data/postgres-oss-pitr-restore
cp -a /data/postgres-oss-pitr-basebackup /data/postgres-oss-pitr-restore
chown -R 999:999 /data/postgres-oss-pitr-restore
touch /data/postgres-oss-pitr-restore/recovery.signal
cat >> /data/postgres-oss-pitr-restore/postgresql.auto.conf <<EOF
restore_command = 'cp /archive/%f %p'
recovery_target_time = '<timestamp from above>'
recovery_target_action = 'promote'
EOF

# ⚠️ gotcha #3 (open-source-specific): mount the restore dir at the EXACT pgdata path the entrypoint expects
# (/var/lib/postgresql/18/docker, NOT the parent /var/lib/postgresql) - otherwise it
# thinks the database is uninitialized and runs initdb instead of recovering.
docker run -d --name postgres-oss-pitr --network pglab \
  -v /data/postgres-oss-pitr-restore:/var/lib/postgresql/18/docker -v /data/postgres-oss-archive:/archive \
  postgres:latest
```

Verify (either image, swap in the right restore container name):
```sql
SELECT * FROM customers;              -- table's back, good marker present, drop never happened
SELECT pg_is_in_recovery();           -- f - cleanly promoted to a new timeline
```

## Cleaning up the labs

Drop the objects this guide created, keeping your base Postgres install intact:
```sql
DROP SCHEMA training CASCADE;
DROP TABLE demo_orders;
DROP TABLE IF EXISTS customers CASCADE;
DROP TABLE IF EXISTS orders;
```

If you built the replication/PITR containers in Steps 9-10, remove those too:

**Tanzu:**
```bash
docker rm -f postgres-18-replica postgres-18-pitr
docker network rm pglab
rm -rf /data/postgres-18-replica /data/postgres-18-archive /data/postgres-18-pitr-basebackup /data/postgres-18-pitr-restore
```

**Open-source:**
```bash
docker rm -f postgres-oss-replica postgres-oss-pitr
docker network rm pglab
rm -rf /data/postgres-oss-replica /data/postgres-oss-archive /data/postgres-oss-pitr-basebackup /data/postgres-oss-pitr-restore
```

For tearing down the main Postgres container itself, see **"Tearing down the lab"** in `tanzu-postgres-docker-guide.md`.
