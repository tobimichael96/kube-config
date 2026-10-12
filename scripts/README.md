# Scripts

## install-nvidia-driver.sh

Installs or upgrades the host NVIDIA driver from NVIDIA's official `.run` installer. Use it when the driver is installed on the host rather than by the GPU operator.

```sh
sudo ./install-nvidia-driver.sh            # latest production driver
sudo ./install-nvidia-driver.sh 580.126.09 # specific version
```

The script:

1. Resolves the latest version from `download.nvidia.com` and exits if it's already installed.
2. Installs `dkms`, build tools and kernel headers, so the module rebuilds on kernel updates.
3. Downloads the installer and verifies its SHA-256 checksum.
4. Stops k3s and all its containers so the old kernel module can be unloaded.
5. Runs the installer non-interactively with DKMS enabled.

Reboot afterwards to load the new module. k3s starts again on boot.

**Requirements:** Debian/Ubuntu (apt), k3s, root, x86_64.
