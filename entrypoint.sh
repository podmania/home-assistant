#!/usr/bin/env bash
set -e

SHARED_DIR="/config"
SOCKET_PATH="/run/virtiofsd/ha.sock"

mkdir -p "$SHARED_DIR" "$(dirname $SOCKET_PATH)"

virtiofsd --socket-path="$SOCKET_PATH" --shared-dir="$SHARED_DIR" --cache=auto --sandbox=chroot --syslog &
VIRTIOFSD_PID=$!
while [ ! -S "$SOCKET_PATH" ]; do
    if ! kill -0 $VIRTIOFSD_PID 2>/dev/null; then exit 1; fi
    sleep 0.1
done

IMAGE_XZ="/storage/haos.img.xz"
IMAGE_QCOW2="/storage/haos.qcow2"
if [ ! -f "$IMAGE_XZ" ]; then cp "${haosSource}" "$IMAGE_XZ"; fi
if [ ! -f "$IMAGE_QCOW2" ]; then
    unxz -k "$IMAGE_XZ"
    if [ "$isX86" = "true" ]; then
        qemu-img convert -f raw -O qcow2 "${IMAGE_XZ%.xz}" "$IMAGE_QCOW2"
        rm "${IMAGE_XZ%.xz}"
    else
        mv "${IMAGE_XZ%.xz}" "$IMAGE_QCOW2"
    fi
fi

KVM_ARGS=""
[ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ] && KVM_ARGS="-enable-kvm -cpu host"

QEMU_USB_ARGS=""
if [ -d "/passthrough" ]; then
    QEMU_USB_ARGS="-usb"
    while IFS= read -r -d '' dev; do
        [ -c "$dev" ] || [ -b "$dev" ] && QEMU_USB_ARGS="$QEMU_USB_ARGS -device usb-host,hostdevice=$dev"
    done < <(find /passthrough -type c -o -type b -print0 2>/dev/null || true)
fi

exec qemu-system-x86_64 $KVM_ARGS -M q35 -smp cores="${CPU_CORES:-2}" -m "${RAM_SIZE:-4096}" \
    -drive file="$IMAGE_QCOW2",if=virtio,cache=unsafe,aio=native \
    -drive file="${OVMF_FD}/FV/OVMF.fd",if=pflash,format=raw,unit=0 \
    -drive file="${OVMF_VARS}/FV/OVMF_VARS.fd",if=pflash,format=raw,unit=1 \
    -netdev user,id=net0,hostfwd=tcp::"${FORWARD_PORT:-8123}"-:8123 \
    -device virtio-net-pci,netdev=net0 \
    -chardev socket,id=char0,path="$SOCKET_PATH" \
    -device vhost-user-fs-pci,queue-size=1024,chardev=char0,tag=config \
    $QEMU_USB_ARGS -nographic -monitor none -serial mon:stdio
