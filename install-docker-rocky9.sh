#!/bin/bash
# Installs Docker Engine on Rocky Linux 9 / RHEL-family systems.
# Safe to re-run - skips the install if Docker is already present.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This needs root. Try: sudo $0"
  exit 1
fi

echo "== Docker install for Rocky Linux 9 =="
echo

if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
  echo "Docker is already installed and running:"
  docker --version
  echo "Nothing to do."
  exit 0
fi

echo "Step 1/4: Adding the Docker CE repo..."
dnf install -y dnf-plugins-core
dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo

echo
echo "Step 2/4: Installing Docker Engine..."
dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

echo
echo "Step 3/4: Enabling and starting the Docker service..."
systemctl enable --now docker

echo
echo "Step 4/4: Verifying with a test container..."
if docker run --rm hello-world >/tmp/docker-hello-world.log 2>&1; then
  echo "Docker is working."
else
  echo "The hello-world test container failed to run. Check /tmp/docker-hello-world.log and the output above."
  exit 1
fi

echo
docker --version
echo
echo "Done. Docker is installed and running."
echo "Next: run ./install-tanzu-postgres.sh to set up Tanzu Postgres."
