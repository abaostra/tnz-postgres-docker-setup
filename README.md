# Tanzu Postgres on Docker — Workshop Setup

Everything you need to get Tanzu Postgres running on Docker on a Rocky Linux 9 VM, ahead of the workshop.

## Start here

**[tanzu-postgres-docker-guide.md](tanzu-postgres-docker-guide.md)** — the full manual walkthrough: prerequisites, getting a Broadcom registry token, installing Docker, pulling and running the image, basic `psql` usage, troubleshooting, and tearing the lab down again. Read this if it's your first time.

(A PDF export of the same guide is handed out separately for offline reading — it's not checked into this repo, just regenerate it from the Markdown if you need one.)

No Broadcom account? The guide and both scripts also cover the official open-source `postgres:latest` image as a fallback — same Postgres engine, no account or login needed. See "Which image should you use?" near the top of the guide.

If you'd rather skip the typing, three scripts run the same steps for you:

- **`install-docker-rocky9.sh`** — installs Docker Engine on Rocky Linux 9, if it isn't already there. Safe to re-run.
- **`install-tanzu-postgres.sh`** — logs in to the Broadcom registry, pulls the image, and runs the Tanzu Postgres container. Prompts for your Broadcom username/token interactively (never written to disk by the script). Safe to re-run; see `--help` for options.
- **`install-postgres-opensource.sh`** — pulls the official `postgres:latest` image and runs it, no account or login step at all. Use this one if you don't have Tanzu registry access. Safe to re-run; see `--help` for options.

```bash
chmod +x install-docker-rocky9.sh install-tanzu-postgres.sh install-postgres-opensource.sh
sudo ./install-docker-rocky9.sh          # skip if Docker's already installed

# pick one:
sudo ./install-tanzu-postgres.sh --with-docker
sudo ./install-postgres-opensource.sh --with-docker
```

## What you'll need

- A Rocky Linux 9 (or RHEL-family) VM with root/sudo access
- **Either** a Broadcom Support Portal account (for Tanzu Postgres — the guide covers signing up if you don't have one) **or** nothing extra at all (for the open-source fallback)
- Outbound internet access from the VM to `*.broadcom.com` (Tanzu path) or Docker Hub (open-source path)

## Reference

Based on the official [Tanzu Postgres OCI image docs](https://techdocs.broadcom.com/us/en/vmware-tanzu/data-solutions/tanzu-for-postgres/18-6/tnz-postgres/postgres-oci-image.html), with everything cross-checked against a real install on Rocky Linux 9.8.
