{
  description = "HAOS with virtio-fs shared /config (multi-arch, distroless)";

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
    # Fetch HAOS images
    # x86_64: raw .img.xz (will convert to qcow2 at runtime)
    # aarch64: direct .qcow2.xz
    # ------------------------------------------------------------------------
    haosImg_x86_64 = pkgs.fetchurl {
      url = "https://github.com/home-assistant/operating-system/releases/download/17.3/haos_generic-x86-64-17.3.img.xz";
      hash = "sha256-34ke1oHbJB65Y9mDWSEIpk/D0VaQrDO3ptHxXA/MUQo=";
      curlOpts = [ "--user-agent" "Mozilla/5.0" ];
    };

    haosXz_aarch64 = pkgs.fetchurl {
      url = "https://github.com/home-assistant/operating-system/releases/download/17.3/haos_generic-aarch64-17.3.qcow2.xz";
      hash = "sha256-9bLzUFV8//kbTS4zd3tiPAIDhY2UoRaymWLIFHq0VuU=";
      curlOpts = [ "--user-agent" "Mozilla/5.0" ];
    };

    # ------------------------------------------------------------------------
    # Helper function to build the container for a given architecture
    # ------------------------------------------------------------------------
    mkHaosContainer = { arch, isX86 ? false, haosSource, pkgs }:
      let
        extraPackages = with pkgs; [ qemu ovmf virtiofsd xz ];

        entrypointScript = pkgs.writeShellScript "entrypoint.sh" ''
          #!${pkgs.bash}/bin/bash
          set -e

          SHARED_DIR="/config"
          SOCKET_PATH="/run/virtiofsd/ha.sock"

          mkdir -p "$SHARED_DIR" "$(dirname $SOCKET_PATH)"

          echo "Starting virtiofsd, sharing $SHARED_DIR ..."
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

          IMAGE_XZ="/storage/haos.img.xz"
          IMAGE_QCOW2="/storage/haos.qcow2"

          if [ ! -f "$IMAGE_XZ" ]; then
            cp ${haosSource} "$IMAGE_XZ"
          fi

          if [ ! -f "$IMAGE_QCOW2" ]; then
            echo "Decompressing and converting disk image (first run only)..."
            unxz -k "$IMAGE_XZ"
            if [ "${isX86}" = "true" ]; then
              # Convert raw .img to qcow2
              qemu-img convert -f raw -O qcow2 "''${IMAGE_XZ%.xz}" "$IMAGE_QCOW2"
              rm "''${IMAGE_XZ%.xz}"   # remove raw to save space
            else
              # aarch64: already a qcow2, just rename
              mv "''${IMAGE_XZ%.xz}" "$IMAGE_QCOW2"
            fi
          fi

          KVM_ARGS=""
          if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
            KVM_ARGS="-enable-kvm -cpu host"
          else
            echo "WARNING: /dev/kvm not accessible – using TCG"
          fi

          exec qemu-system-${arch} \
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
            "/storage" = {};
            "/config" = {};
          };
          Entrypoint = [ "/bin/entrypoint.sh" ];
        };

      in n2c.buildImage {
        name = "home-assistant-os";
        tag = "latest";
        fromImage = base.packages.${system}.base-debug-image;
        copyToRoot = [ extraLayers ];
        config = imageConfig;
        maxLayers = 6;
      };

  in {
    packages.${system} = {
      haos-container-x86_64 = mkHaosContainer {
        arch = "x86_64";
        isX86 = true;
        haosSource = haosImg_x86_64;
        inherit pkgs;
      };
      haos-container-aarch64 = mkHaosContainer {
        arch = "aarch64";
        isX86 = false;
        haosSource = haosXz_aarch64;
        inherit pkgs;
      };
      default = self.packages.${system}.haos-container-x86_64;
    };
  };
}
