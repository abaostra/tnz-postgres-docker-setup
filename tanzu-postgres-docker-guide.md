# Installing Tanzu Postgres on Docker (Rocky Linux 9)

This is the setup guide for the Tanzu Postgres workshop. If you're attending the session, please work through this **before** we meet, so we're not spending the first 30 minutes watching Docker pull layers on a projector. It takes about 15-20 minutes if your VM already has Docker, or 25-30 minutes if it doesn't.

Everything here was tested end-to-end on a fresh Rocky Linux 9.8 VM, so if a command doesn't work for you exactly as written, something in your environment is different (network policy, DNS, an older Docker version, etc.) — check the Troubleshooting section near the end before assuming you did something wrong.

## What you'll end up with

A single Tanzu Postgres 18.6 container running on your VM, listening on port 5432, with its data written to a folder on disk (so you can stop/start the container without losing anything). This is a standalone container, not a Kubernetes deployment — good enough for a demo or for kicking the tires, not what you'd run in production. If you need HA later, that's a different conversation involving the Tanzu Postgres Kubernetes operator.

## Prerequisites

- A Linux VM. We used Rocky Linux 9.8, and these steps assume RHEL/Rocky 9 (`dnf`-based). If you're on Ubuntu or something else, the Docker install commands will differ slightly — the Postgres steps themselves are identical everywhere.
- Root or sudo access on that VM.
- **Docker already installed and running.** Most workshop VMs will come with this pre-installed. If yours doesn't, see the optional section right below — don't skip ahead assuming it'll just work.
- A network path from the VM to `*.broadcom.com` (outbound HTTPS). No inbound firewall changes are needed unless you want to reach Postgres from a different machine — see Step 5.
- A Broadcom Support Portal account. If you don't have one, Step 1 covers signing up.

## Optional: installing Docker

Skip this if `docker --version` already returns something on your VM.

If it doesn't, here's the manual way (this is exactly what we ran, no surprises):

```bash
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
docker --version
```

Sanity-check it with:

```bash
sudo docker run --rm hello-world
```

If that prints "Hello from Docker!", you're good.

If you'd rather not type all that, there's a script that does exactly this — `install-docker-rocky9.sh`, included alongside this guide. Run it with `sudo ./install-docker-rocky9.sh` and it'll walk through the same steps, printing what it's doing as it goes, and it won't touch anything if Docker's already there.

## Step 1: Get a Broadcom registry token

The Tanzu Postgres image lives behind Broadcom's package registry, not Docker Hub, so you need an account and a token before you can pull it.

1. Go to [support.broadcom.com](https://support.broadcom.com) and either sign in or create an account if you don't have one yet.
2. Once logged in, go to **My Downloads**.
3. Search for "Postgres" and open **VMware Tanzu Postgres**.
4. Look for **Registry Tokens** on that page and click **Generate Token**.
5. Copy the token somewhere safe — you'll use it as a password in the next step, and it typically expires after a day or two, so don't generate it a week in advance.

This token is tied to your account, so treat it like a password. Don't paste it into Slack, a ticket, or a script that gets committed anywhere.

## Step 2: Log in to the registry

```bash
docker login tanzu-sql-postgres.packages.broadcom.com --username=<your-broadcom-email>
```

Leave `--password` off the command and let it prompt you — type the token in at the `Password:` prompt rather than pasting it as a command-line argument. Two reasons: it keeps the token out of your shell history, and (we found this out the hard way) piping the token through something before it reaches `docker login` — an SSH tool, a Windows-to-Linux clipboard, whatever — can silently mangle a trailing character or line ending and turn a perfectly valid token into one that fails with a cryptic `Token failed verification: signature` error. Typing it directly at the prompt, or using `--password-stdin` from a real shell on the box itself, avoids that entirely.

You should see:

```
Login Succeeded
```

## Step 3: Pull the image

```bash
docker pull tanzu-sql-postgres.packages.broadcom.com/postgres-oci:v18.6
```

This is about a 2 GB image, so give it a minute depending on your connection.

## Step 4: Set up a data directory

Postgres needs somewhere on disk to keep its data so it survives a container restart.

```bash
sudo mkdir -p /data/postgres-18
sudo chmod 700 /data/postgres-18
```

One thing worth calling out: Rocky Linux 9 runs SELinux in enforcing mode by default, and normally that's exactly the kind of thing that blocks a container from writing to a bind-mounted host directory. In our testing, Docker handled this fine without any extra `:Z` mount flag or SELinux relabeling — the container started and initialized the database on the first try. If you're on a more locked-down VM and see permission errors when the container starts, that's the first thing to check, but don't add it pre-emptively — it wasn't needed for us and it changes the SELinux label on that whole directory.

If you do need it, it gets appended directly to the end of the `-v` flag in Step 6, after the container-side path:

```bash
-v /data/postgres-18:/var/lib/pgsql/data:Z
```

Nothing else in the command changes — just that one flag. Docker actually supports two variants here: `:Z` (uppercase) relabels the directory for **exclusive** use by this one container, while `:z` (lowercase) relabels it as **shared**, usable by multiple containers. For a single Postgres container like this, `:Z` (uppercase) is the one you want.

## Step 5: Open the firewall port (only if you need to)

Check first:

```bash
sudo firewall-cmd --state
```

If it says `not running`, there's nothing to do. If it's active and you want to reach Postgres from another machine (not just from the VM itself), open the port:

```bash
sudo firewall-cmd --permanent --add-port=5432/tcp
sudo firewall-cmd --reload
```

Note this only covers the VM's own firewall. If your VM sits behind a network security group, cloud firewall, or corporate network ACL, you'll need to open 5432 there too — that's outside what this guide can help with, since it's specific to your environment.

## Step 6: Run the container

There are two ways to do this — a bare-bones version for "I just want it running," and a fuller version for when you actually care about the credentials and tuning. Both were tested and both work fine; pick whichever matches what you need.

### Basic mode

This is the fastest path to a working instance. It uses the image's defaults for everything except the username and password, which you should always set explicitly rather than relying on the auto-generated one (fine for a two-minute test, annoying to dig out of container logs for anything longer-lived):

```bash
docker run -d \
  --name postgres-18 \
  -e POSTGRES_USER=appuser \
  -e POSTGRES_PASSWORD=pick-your-own-password \
  -v /data/postgres-18:/var/lib/pgsql/data \
  -p 5432:5432 \
  --restart unless-stopped \
  tanzu-sql-postgres.packages.broadcom.com/postgres-oci:v18.6
```

That's it — superuser `appuser` with the password you chose, a default database also called `appuser`, 100 max connections, and whatever the image's default memory settings are. Good enough for the workshop.

### Full example, every option explained

If you want more control — a specific database name, connection limits, memory tuning, a named volume instead of a bind mount — here's the fuller version we actually ran and confirmed working:

```bash
docker run -d \
  --name postgres-18-production \
  -e POSTGRES_USER=appuser \
  -e POSTGRES_PASSWORD=mysecurepassword \
  -e POSTGRES_DB=appdb \
  -e POSTGRES_MAX_CONNECTIONS=200 \
  -e POSTGRES_SHARED_BUFFERS=512MB \
  -e POSTGRES_WORK_MEM=16MB \
  -e POSTGRES_EFFECTIVE_CACHE_SIZE=2GB \
  -e POSTGRES_INITDB_ARGS="--encoding=UTF8 --data-checksums" \
  -v pgdata-18-prod:/var/lib/pgsql/data \
  -p 5432:5432 \
  --restart unless-stopped \
  tanzu-sql-postgres.packages.broadcom.com/postgres-oci:v18.6
```

Going through it line by line:

- **`--name postgres-18-production`** — whatever you want to call the container. This is what you'll reference in every `docker` command afterward (`docker logs postgres-18-production`, `docker stop postgres-18-production`, etc.).
- **`-e POSTGRES_USER=appuser`** — the Postgres superuser that gets created. Defaults to `postgres` if you leave this out.
- **`-e POSTGRES_PASSWORD=mysecurepassword`** — the password for that user. If you skip this, the container generates a random 16-character one and prints it to the logs exactly once — set your own instead so you're not digging through `docker logs` later. Obviously, don't actually use the literal string "mysecurepassword" for anything beyond a demo.
- **`-e POSTGRES_DB=appdb`** — the name of the default database created at startup. Defaults to whatever `POSTGRES_USER` is set to, if omitted.
- **`-e POSTGRES_MAX_CONNECTIONS=200`** — how many concurrent client connections Postgres will accept. Default is 100. We confirmed this actually takes effect (`SHOW max_connections;` returned `200`).
- **`-e POSTGRES_SHARED_BUFFERS=512MB`** — the chunk of memory Postgres dedicates to caching data pages. Default is 128MB. As a rule of thumb this is usually set to around 25% of the VM's RAM for a dedicated database box — 512MB is a reasonable number for a demo VM with a few GB of RAM, not a hard rule.
- **`-e POSTGRES_WORK_MEM=16MB`** — memory available per sort/hash operation within a query, before it starts spilling to disk. Default is 4MB. Bump this if you're demoing queries with heavier sorts or joins.
- **`-e POSTGRES_EFFECTIVE_CACHE_SIZE=2GB`** — tells the query planner roughly how much memory is available for caching, across both Postgres's own buffers and the OS filesystem cache. It doesn't allocate anything by itself, it just influences whether the planner favors index scans or sequential scans. Default is 512MB.
- **`-e POSTGRES_INITDB_ARGS="--encoding=UTF8 --data-checksums"`** — extra flags passed straight to `initdb` when the database cluster is first created. `--encoding=UTF8` is usually already the default depending on your locale, but it's worth being explicit. `--data-checksums` turns on page-level checksums, which helps `initdb` (and later Postgres itself) catch storage corruption early — it's a one-time decision, since you can't turn it on for an already-initialized cluster without redoing `initdb`. We confirmed `SHOW data_checksums;` returned `on` with this set.
- **`-v pgdata-18-prod:/var/lib/pgsql/data`** — this is a **named Docker volume** rather than a bind mount to a host path. Docker manages where it actually lives on disk (usually under `/var/lib/docker/volumes/`). It behaves the same as the bind-mount approach from Step 4 as far as Postgres is concerned — pick whichever you find easier to reason about. Named volumes are a bit more "Docker-native" and slightly easier to back up with `docker volume` commands; bind mounts are easier if you want to poke at the raw files directly from the host or you're already used to a specific path like `/data/postgres-18`.
- **`-p 5432:5432`** — maps container port 5432 to host port 5432. First number is the host side, second is the container side — change the first if 5432 is already taken on your VM (e.g. `-p 5433:5432`).
- **`--restart unless-stopped`** — tells Docker to automatically restart the container if it crashes or the VM reboots, unless you explicitly stopped it yourself. Worth having for anything you want to stay up between reboots without babysitting it.

All of the above env vars only take effect the **first time** the container initializes an empty data directory. If you've already run the container once against that volume/directory, changing these values and re-running won't do anything — Postgres won't re-run `initdb` against existing data. You'd need to wipe the volume/directory (see Cleanup below) and start over for changes to take effect.

## Step 7: Verify it's actually working

The rest of this section uses `postgres-18` and user `appuser` — swap in whatever you actually named your container and user.

If you didn't set `POSTGRES_PASSWORD` (only relevant if you skipped it entirely, which we don't recommend), grab the auto-generated one from the logs:

```bash
docker logs postgres-18 2>&1 | grep -A1 "Password:"
```

It only gets printed once, right after the container first initializes — write it down.

Then check the container's actually up:

```bash
docker ps --filter name=postgres-18
```

And run a query through it:

```bash
docker exec postgres-18 psql -U appuser -c "SHOW max_connections;"
```

(Don't add `-it` to that if you're running it through a script or over something like plink/PuTTY's non-interactive mode — `-it` needs a real terminal attached, and you'll get `cannot attach stdin to a TTY-enabled container because stdin is not a terminal`. Drop `-it` and it works the same, minus the interactive prompt.)

If you want to actually get a `psql` prompt to poke around:

```bash
docker exec -it postgres-18 psql -U appuser
```

And to confirm the port mapping is really listening (useful if something above worked but you're still not sure):

```bash
ss -tlnp | grep 5432
```

You should see `docker-proxy` listening on `0.0.0.0:5432`.

## Step 8: Poke around — basic psql operations

If you've never used `psql` before, here's enough to look dangerous during the demo. Get a prompt first:

```bash
docker exec -it postgres-18 psql -U appuser -d appuser
```

Everything below was run against a real container while writing this guide, so copy-paste away.

**Create a table:**

```sql
CREATE TABLE employees (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    department TEXT,
    hire_date DATE DEFAULT CURRENT_DATE
);
```

**Insert some rows:**

```sql
INSERT INTO employees (name, department) VALUES
    ('Aman', 'Engineering'),
    ('Priya', 'Sales');
```

**Query it:**

```sql
SELECT * FROM employees;
```

**Update a row:**

```sql
UPDATE employees SET department = 'Platform Engineering' WHERE name = 'Aman';
```

**Create a view** (a saved query you can select from like a table):

```sql
CREATE VIEW engineering_staff AS
    SELECT name, hire_date FROM employees WHERE department ILIKE '%engineering%';

SELECT * FROM engineering_staff;
```

**List tables and describe one** (these are `psql` shortcuts, not SQL — no semicolon needed):

```
\dt
\d employees
```

Other shortcuts worth knowing: `\l` lists databases, `\du` lists users/roles, `\q` quits.

**Delete a row, then clean up the objects you just made:**

```sql
DELETE FROM employees WHERE name = 'Priya';

DROP VIEW engineering_staff;
DROP TABLE employees;
```

That's genuinely most of what you need for a demo — create something, show data in it, query it, tear it down.

## Prefer to skip typing all of this?

`install-tanzu-postgres.sh`, included alongside this guide, runs Steps 1 through 7 for you — it asks for your Broadcom username and token interactively (input hidden, never written to disk by the script), and narrates what it's doing at each stage so you can still follow along against the guide. Pair it with `install-docker-rocky9.sh` first if your VM doesn't have Docker yet. Neither script touches the psql basics in Step 8 — that part's still on you to click through live.

## Troubleshooting

**`docker login` fails with "Token failed verification: signature"**
The token itself is probably fine — this almost always means something between you and the terminal mangled it (a piped command, a clipboard round-trip through Windows, an extra newline). Type the password directly at the interactive `Password:` prompt instead of passing `--password=` or piping it through anything, and it'll almost certainly work.

**"cannot attach stdin to a TTY-enabled container because stdin is not a terminal"**
You used `-it` on `docker exec` from a context without a real terminal (a script, a non-interactive SSH session, etc.). Drop the `-it` flags.

**Container starts then immediately exits**
Check `docker logs postgres-18` for the actual error — usually it's a permissions issue on the data directory, or a leftover `postgresql.pid` file if you're reusing an old data directory from a previous run. If it's a truly fresh directory and this happens, check `getenforce` and try adding `:Z` to the volume mount.

**Can connect with `docker exec` but not from outside the VM**
That's a network problem, not a Postgres problem. Confirm the port is listening locally first (`ss -tlnp | grep 5432`), then work outward — VM firewall (Step 5), then whatever network security group / ACL sits between the VM and wherever you're connecting from.

**Port 5432 already in use**
Something else on the VM is already listening on it (maybe a previous test run, or a native Postgres install). `sudo ss -tlnp | grep 5432` will tell you what. Either stop that, or map to a different host port with `-p 5433:5432` and connect on 5433 instead.

## Tearing down the lab

Depending on whether you're pausing between demos or fully decommissioning the VM, pick one of these.

**Just stop it for now (keep everything):**

```bash
docker stop postgres-18
```

`docker start postgres-18` brings it right back with the same data, same credentials.

**Stop and remove the container, but keep the data** (e.g. you want to recreate it with different settings but not lose what's in it):

```bash
docker stop postgres-18
docker rm postgres-18
```

Running Step 6 again against the same `/data/postgres-18` picks up right where you left off — remember, env vars like `POSTGRES_PASSWORD` won't re-apply against existing data.

**Wipe the database completely and start fresh** (careful — this deletes the data for good):

```bash
docker rm -f postgres-18
sudo rm -rf /data/postgres-18
```

**Full teardown — remove everything this guide installed**, for when the workshop's over and you want the VM back to a clean slate:

```bash
# stop and remove the container
docker rm -f postgres-18

# delete the data directory
sudo rm -rf /data/postgres-18

# remove the downloaded image
docker rmi tanzu-sql-postgres.packages.broadcom.com/postgres-oci:v18.6

# forget the registry login (removes the stored token from /root/.docker/config.json)
docker logout tanzu-sql-postgres.packages.broadcom.com
```

If you also want to remove Docker itself from the VM (not usually necessary — most people just leave it installed for next time):

```bash
sudo systemctl stop docker
sudo dnf remove -y docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin docker-ce-rootless-extras
sudo rm -rf /var/lib/docker /var/lib/containerd
```

That last `rm -rf` deletes every image, container, and volume Docker was managing on this VM — not just the ones from this guide — so only run it if you genuinely want Docker gone.
