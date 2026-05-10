{
  description = "HAOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix2container.url = "github:nlewo/nix2container";
    base.url = "github:podmania/base";
  };

  outputs = { self, nixpkgs, nix2container, base }: let
    system = builtins.currentSystem;
    pkgs = nixpkgs.legacyPackages.${system};
    n2c = nix2container.outputs.packages.${system}.nix2container;

    # ------------------------------------------------------------------------
    # 1. Download HAOS (compressed)
    # ------------------------------------------------------------------------
    haosXz = pkgs.fetchurl {
      url = "https://github.com/home-assistant/operating-system/releases/download/17.0/haos_ova-17.0.qcow2.xz";
      hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
      curlOpts = [ "--user-agent" "Mozilla/5.0" ];
    };

    # ------------------------------------------------------------------------
    # 2. Decompress and customize the HAOS image at build time
    # ------------------------------------------------------------------------
    # We decompress -> customize -> then re-compress to save space.
    haosCustomizedXz = pkgs.stdenv.mkDerivation {
      name = "haos-customized";
      nativeBuildInputs = with pkgs; [ xz libguestfs qemu ];
      buildCommand = ''
        # Decompress original image
        xz -d < ${haosXz} > haos.raw

        # Customize the image using virt-customize (no root required with proper qemu)
        # Set LIBGUESTFS_BACKEND=direct to avoid libvirtd
        export LIBGUESTFS_BACKEND=direct

        # Create mount unit script and first-boot service
        cat > mount-config.sh <<'EOF'
        #!/bin/bash
        mkdir -p /mnt/config
        cat > /etc/systemd/system/mnt-config.mount <<UNIT
        [Unit]
        Description=Mount virtio-fs config share
        Before=homeassistant.service

        [Mount]
        What=config
        Where=/mnt/config
        Type=virtiofs
        Options=defaults

        [Install]
        WantedBy=multi-user.target
        UNIT

        systemctl enable mnt-config.mount
        systemctl start mnt-config.mount

        # Replace /config with symlink to the mount
        if [ -L /config ]; then rm /config; elif [ -d /config ]; then mv /config /config.orig; fi
        ln -s /mnt/config /config

        # Disable this first-boot script
        systemctl disable haos-firstboot
        rm /etc/systemd/system/haos-firstboot.service
        EOF

        chmod +x mount-config.sh

        # Inject the script and create a systemd service that runs it once
        virt-customize -a haos.raw \
          --run-command "mkdir -p /usr/local/bin" \
          --upload mount-config.sh:/usr/local/bin/mount-config.sh \
          --run-command "chmod +x /usr/local/bin/mount-config.sh" \
          --run-command "cat > /etc/systemd/system/haos-firstboot.service <<EOF
        [Unit]
        Description=HAOS first boot configuration
        After=network.target

        [Service]
        Type=oneshot
        ExecStart=/usr/local/bin/mount-config.sh
        RemainAfterExit=yes

        [Install]
        WantedBy=multi-user.target
        EOF" \
          --run-command "systemctl enable haos-firstboot.service"

        # Re-compress the customized image
        xz -c haos.raw > $out
      '';
    };

    # ------------------------------------------------------------------------
    # 3. Extra packages for runtime
    # ------------------------------------------------------------------------
    extraPackages = with pkgs; [
      qemu
      ovmf
      virtiofsd
      xz
    ];

    # ------------------------------------------------------------------------
    # 4. Entrypoint script (container runtime)
    # ------------------------------------------------------------------------
    entrypointScript = pkgs.writeShellScript "entrypoint.sh" ''
      #!${pkgs.bash}/bin/bash
      set -e

      SHARED_DIR="/config"
      SOCKET_PATH="/run/virtiofsd/ha.sock"

      mkdir -p "$SHARED_DIR" "$(dirname $SOCKET_PATH)"

      # Start virtiofsd
      virtiofsd \
        --socket-path="$SOCKET_PATH" \
        --shared-dir="$SHARED_DIR" \
        --cache=auto \
        --sandbox=chroot \
        --syslog &
      VIRTIOFSD_PID=$!

      while [ ! -S "$SOCKET_PATH" ]; do
        if ! kill -0 $VIRTIOFSD_PID 2>/dev/null; then
          echo "ERROR: virtiofsd died"
          exit 1
        fi
        sleep 0.1
      done

      # HAOS disk setup
      IMAGE_XZ="/storage/haos.qcow2.xz"
      IMAGE_QCOW2="''${IMAGE_XZ%.xz}"

      if [ ! -f "$IMAGE_XZ" ]; then
        cp ${haosCustomizedXz} "$IMAGE_XZ"
      fi
      if [ ! -f "$IMAGE_QCOW2" ]; then
        echo "Decompressing HAOS (first run)..."
        unxz -k "$IMAGE_XZ"
      fi

      KVM_ARGS=""
      if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        KVM_ARGS="-enable-kvm -cpu host"
      else
        echo "WARNING: /dev/kvm not accessible – using TCG"
      fi

      exec qemu-system-x86_64 \
        $KVM_ARGS \
        -M q35 \
        -smp cores="''${CPU_CORES:-2}" \
        -m "''${RAM_SIZE:-4096}" \
        -drive file="$IMAGE_QCOW2",if=virtio,cache=unsafe,aio=native \
        -drive file=${pkgs.OVMF.fd}/FV/OVMF.fd,if=pflash,format=raw,unit=0 \
        -drive file=${pkgs.OVMF.fd}/FV/OVMF_VARS.fd,if=pflash,format=raw,unit=1 \
        -netdev user,id=net0,hostfwd=tcp::''${FORWARD_PORT:-8123}-:8123 \
        -device virtio-net-pci,netdev=net0 \
        -chardev socket,id=char0,path="$SOCKET_PATH" \
        -device vhost-user-fs-pci,queue-size=1024,chardev=char0,tag=config \
        -nographic -monitor none -serial mon:stdio
    '';

    # ------------------------------------------------------------------------
    # 5. Rootfs overlay
    # ------------------------------------------------------------------------
    extraLayers = pkgs.symlinkJoin {
      name = "haos-extra";
      paths = extraPackages;
      buildInputs = [ pkgs.buildPackages.s6-portable-utils ];
      postBuild = ''
        cp ${entrypointScript} $out/bin/entrypoint.sh
        chmod +x $out/bin/entrypoint.sh
        mkdir -p $out/run/virtiofsd
      '';
    };

    # ------------------------------------------------------------------------
    # 6. Container config
    # ------------------------------------------------------------------------
    imageConfig = {
      Env = [
        "CPU_CORES=2"
        "RAM_SIZE=4096"
        "FORWARD_PORT=8123"
      ];
      ExposedPorts = {
        "8123/tcp" = {};
      };
      Volumes = {
      # "/storage" = {};
        "/config" = {};
      };
      Entrypoint = [ "/bin/entrypoint.sh" ];
    };

  in {
    packages.${system} = {
      haos-container = n2c.buildImage {
        name = "home-assistant";
        tag = "latest";
        fromImage = base.packages.${system}.base-debug-image;
        copyToRoot = [ extraLayers ];
        config = imageConfig;
        maxLayers = 6;
      };
      default = self.packages.${system}.haos-container;
    };
  };
}
