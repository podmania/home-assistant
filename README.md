# Home Assistant OS Container

Run **Home Assistant OS** in a container with KVM acceleration and `virtio‑fs` sharing for `/config`.

Pre‑built multi‑arch images are published to GitHub Container Registry (GHCR). A weekly CI job automatically updates the bundled HAOS disk image to the latest release.

## Prerequisites

- Linux host with **KVM support** (`/dev/kvm` accessible, user in `kvm` group)
- **Podman** or **Docker**

## What's Inside

- HAOS disk image – bundled compressed, decompressed automatically on first run.
- virtio-fs – shares the host’s ./config directory with the guest at /config.
- KVM acceleration – enabled automatically if /dev/kvm is available.
- Headless – uses serial console; no VNC or web viewer.

## Configuration

| Variable       | Default | Description                          |
|----------------|---------|--------------------------------------|
| `CPU_CORES`    | `2`     | Number of CPU cores for the VM       |
| `RAM_SIZE`     | `4096`  | Memory in MB for the VM              |
| `FORWARD_PORT` | `8123`  | Host port forwarded to HAOS port 8123 |

## Persistent Storage

- **`/config`** – bind‑mounted directory for your Home Assistant configuration.

## First Run

- The container copies and decompresses the HAOS image (takes ~30‑60 seconds).
- On x86_64, the raw `.img.xz` is converted to `qcow2` format.
- Subsequent runs start immediately.

## Notes

- KVM requires your user to be in the `kvm` group. Add yourself: `sudo usermod -aG kvm $USER` (log out and back in).
