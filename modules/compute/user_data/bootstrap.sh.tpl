#!/bin/bash

# This bootstrap script modifies every domain referenced in '/etc/apt/sources.list.d/ubuntu.sources'
# to utilize the 'https' protocol instead of 'http'

set -euo pipefail

LOG_FILE="/var/log/instance-bootstrap.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[INFO] Starting bootstrap at $(date -Is)"

UBUNTU_SOURCES="/etc/apt/sources.list.d/ubuntu.sources"

if [[ -f "$UBUNTU_SOURCES" ]]; then
  cp "$UBUNTU_SOURCES" "$UBUNTU_SOURCES.bak"
  sed -i 's|http://|https://|g' "$UBUNTU_SOURCES"
  echo "[INFO] Updated Ubuntu package sources to HTTPS"
else
  echo "[WARN] $UBUNTU_SOURCES not found; skipping source rewrite"
fi

apt-get update -y
apt-get install -y ca-certificates curl jq

echo "[INFO] Bootstrap complete at $(date -Is)"