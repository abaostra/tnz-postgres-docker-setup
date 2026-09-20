# Tanzu Postgres on Docker — Workshop Setup

Everything you need to get Tanzu Postgres running on Docker on a Rocky Linux 9 VM, ahead of the workshop.

## Start here

**[tanzu-postgres-docker-guide.md](tanzu-postgres-docker-guide.md)** — the full manual walkthrough: prerequisites, getting a Broadcom registry token, installing Docker, pulling and running the image, basic `psql` usage, troubleshooting, and tearing the lab down again. Read this if it's your first time.

(A PDF export of the same guide is handed out separately for offline reading — it's not checked into this repo, just regenerate it from the Markdown if you need one.)

If you'd rather skip the typing, two scripts run the same steps for you:

- **`install-docker-rocky9.sh`** — installs Docker Engine on Rocky Linux 9, if it isn't already there. Safe to re-run.
- **`install-tanzu-postgres.sh`** — logs in to the Broadcom registry, pulls the image, and runs the Tanzu Postgres container. Prompts for your Broadcom username/token interactively (never written to disk by the script). Safe to re-run; see `--help` for options.

```bash
chmod +x install-docker-rocky9.sh install-tanzu-postgres.sh
sudo ./install-docker-rocky9.sh          # skip if Docker's already installed
sudo ./install-tanzu-postgres.sh --with-docker
```

## What you'll need

- A Rocky Linux 9 (or RHEL-family) VM with root/sudo access
- A Broadcom Support Portal account — the guide covers signing up if you don't have one
- Outbound internet access from the VM to `*.broadcom.com`

## Reference

Based on the official [Tanzu Postgres OCI image docs](https://techdocs.broadcom.com/us/en/vmware-tanzu/data-solutions/tanzu-for-postgres/18-6/tnz-postgres/postgres-oci-image.html), with everything cross-checked against a real install on Rocky Linux 9.8.
