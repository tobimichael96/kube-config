#!/usr/bin/env bash
# Install or upgrade the host NVIDIA driver from NVIDIA's .run installer.
#
# The GPU operator runs with driver.enabled=false, so the driver lives on the
# host. Container images bundle CUDA forward-compat libs that GeForce cards
# can't use, so the host driver must support at least the CUDA version of
# every GPU image (including the gpu-operator validator).
#
# Usage: sudo ./install-nvidia-driver.sh [version]
#   version defaults to the latest production release from latest.txt.
set -euo pipefail

BASE_URL="https://download.nvidia.com/XFree86/Linux-x86_64"
WORK_DIR="/var/tmp/nvidia-driver"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi

version="${1:-$(curl -fsS "$BASE_URL/latest.txt" | awk '{print $1}')}"
installed="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)"

echo "Installed driver: ${installed:-none}"
echo "Target driver:    $version"
if [[ "$installed" == "$version" ]]; then
  echo "Already up to date."
  exit 0
fi
read -rp "Continue? This stops k3s and all its pods. [y/N] " answer
[[ "$answer" =~ ^[Yy]$ ]] || exit 1

# DKMS rebuilds the module on kernel updates, so a Debian kernel upgrade
# doesn't leave the node without a GPU.
apt-get update
apt-get install -y dkms build-essential "linux-headers-$(uname -r)"

run_file="NVIDIA-Linux-x86_64-$version.run"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"
curl -fL --continue-at - -o "$run_file" "$BASE_URL/$version/$run_file"
curl -fsS -o "$run_file.sha256sum" "$BASE_URL/$version/$run_file.sha256sum"
sha256sum -c "$run_file.sha256sum"
chmod +x "$run_file"

# `systemctl stop k3s` leaves containers running and holding /dev/nvidia*,
# which blocks unloading the old kernel module. killall stops them too.
/usr/local/bin/k3s-killall.sh

# The installer uninstalls the previous .run driver itself. Headless server,
# so no X config.
"./$run_file" --dkms --no-questions --ui=none --no-x-check

echo
echo "Installed $version. Reboot to load the new kernel module:"
echo "  systemctl reboot"
echo "k3s starts again on boot; then restart the gpu-operator validator and GPU workloads."
