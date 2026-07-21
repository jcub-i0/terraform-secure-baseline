#!/bin/bash

set -Eeuo pipefail

LOG_FILE="/var/log/instance-bootstrap.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[INFO] Starting bootstrap at $(date -Is)"

export DEBIAN_FRONTEND=noninteractive

apt_get() {
  apt-get \
    -o DPkg::Lock::Timeout=300 \
    -o Acquire::Retries=5 \
    "$@"
}

UBUNTU_SOURCES="/etc/apt/sources.list.d/ubuntu.sources"

if [[ -f "$UBUNTU_SOURCES" ]]; then
  cp "$UBUNTU_SOURCES" "${UBUNTU_SOURCES}.bak"
  sed -i 's|http://|https://|g' "$UBUNTU_SOURCES"
  echo "[INFO] Updated Ubuntu package sources to HTTPS"
else
  echo "[WARN] ${UBUNTU_SOURCES} not found; skipping source rewrite"
fi

echo "[INFO] Refreshing APT metadata"
apt_get update

echo "[INFO] Installing current package updates"
apt_get dist-upgrade -y

echo "[INFO] Installing required bootstrap packages"
apt_get install -y \
  ca-certificates \
  curl \
  jq

echo "[INFO] Recording relevant package versions"
dpkg-query -W \
  -f='${binary:Package}\t${Version}\n' \
  ubuntu-advantage-tools \
  ubuntu-pro-client \
  ubuntu-pro-client-l10n \
  vim \
  vim-common \
  vim-runtime \
  vim-tiny \
  xxd \
  2>/dev/null || true

if [[ -f /var/run/reboot-required ]]; then
  echo "[WARN] A reboot is required"
  cat /var/run/reboot-required.pkgs 2>/dev/null || true
fi

echo "[INFO] Bootstrap complete at $(date -Is)"