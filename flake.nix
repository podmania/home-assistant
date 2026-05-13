{
  description = "HAOS distroless image using nix2container";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix2container.url = "github:nlewo/nix2container";
    base.url = "github:podmania/base";
  };

  outputs = { self, nixpkgs, nix2container, base }: let
    system = builtins.currentSystem;
    pkgs = nixpkgs.legacyPackages.${system};
    n2c = nix2container.outputs.packages.${system}.nix2container;

    # Select the correct HAOS source based on architecture
    haosSource = if system == "x86_64-linux" then pkgs.fetchurl {
      url = "https://github.com/home-assistant/operating-system/releases/download/17.3/haos_generic-x86-64-17.3.img.xz";
      hash = "sha256-34ke1oHbJB65Y9mDWSEIpk/D0VaQrDO3ptHxXA/MUQo=";
      curlOpts = "--user-agent Mozilla/5.0";
    } else if system == "aarch64-linux" then pkgs.fetchurl {
      url = "https://github.com/home-assistant/operating-system/releases/download/17.3/haos_generic-aarch64-17.3.qcow2.xz";
      hash = "sha256-9bLzUFV8//kbTS4zd3tiPAIDhY2UoRaymWLIFHq0VuU=";
      curlOpts = "--user-agent Mozilla/5.0";
    } else throw "Unsupported system: ${system}";

    isX86 = system == "x86_64-linux";
    arch = if isX86 then "x86_64" else "aarch64";
    machineType = if isX86 then "q35" else "virt";
    firmwareCode = "${pkgs.OVMF.fd}/FV/" + (if isX86 then "OVMF.fd" else "QEMU_EFI.fd");
    firmwareVars = if isX86 then "${pkgs.OVMF.fd}/FV/OVMF_VARS.fd" else "/storage/efi-vars.fd";

    # Runtime dependencies
    extraPackages = with pkgs; [ qemu OVMF virtiofsd xz ];

    # Entrypoint script
    entrypointScript = pkgs.writeShellScript "entrypoint.sh" ''
      #!${pkgs.bash}/bin/bash
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
      if [ ! -f "$IMAGE_XZ" ]; then
        cp ${haosSource} "$IMAGE_XZ"
      fi
      if [ ! -f "$IMAGE_QCOW2" ]; then
        unxz -k "$IMAGE_XZ"
        if [ "${if isX86 then "true" else "false"}" = "true" ]; then
          qemu-img convert -f raw -O qcow2 "''${IMAGE_XZ%.xz}" "$IMAGE_QCOW2"
          rm "''${IMAGE_XZ%.xz}"
        else
          mv "''${IMAGE_XZ%.xz}" "$IMAGE_QCOW2"
        fi
      fi
      ${if !isX86 then ''
      if [ ! -f ${firmwareVars} ]; then
        cp ${firmwareCode} ${firmwareVars}
      fi
      '' else ""}

      if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        echo "KVM available, using hardware virtualization"
        KVM_ARGS="-enable-kvm -cpu host"
      else
        echo "WARNING: KVM not available, falling back to software emulation (TCG)" >&2
        KVM_ARGS="-accel tcg,thread=multi -cpu max"
      fi

      exec qemu-system-${arch} $KVM_ARGS \
        -M ${machineType} \
        -smp cores="''${CPU_CORES:-2}" \
        -m "''${RAM_SIZE:-4096}" \
        -drive file="$IMAGE_QCOW2",if=virtio,cache=unsafe,aio=native \
        -drive file=${firmwareCode},if=pflash,format=raw,unit=0 \
        -drive file=${firmwareVars},if=pflash,format=raw,unit=1 \
        -netdev user,id=net0,hostfwd=tcp::''${FORWARD_PORT:-8123}-:8123 \
        -device virtio-net-pci,netdev=net0 \
        -chardev socket,id=char0,path="$SOCKET_PATH" \
        -device vhost-user-fs-pci,queue-size=1024,chardev=char0,tag=config \
        -nographic -monitor none -serial mon:stdio
    '';

    # Combine extra packages and entrypoint into a single rootfs layer
    rootfs = pkgs.symlinkJoin {
      name = "haos-rootfs";
      paths = extraPackages;   # only directory paths
      buildInputs = [ pkgs.coreutils ];
      postBuild = ''
        mkdir -p $out/bin $out/run/virtiofsd
        cp ${entrypointScript} $out/bin/entrypoint.sh
        chmod +x $out/bin/entrypoint.sh
        ln -sf ${pkgs.bashInteractive}/bin/bash $out/bin/sh
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
        "/config" = {};
      };
      Entrypoint = [ "/bin/entrypoint.sh" ];
    };

  in {
    packages.${system} = {
      haos-image = n2c.buildImage {
        name = "home-assistant";
        tag = "latest";
        fromImage = base.packages.${system}.base-debug-image;
        layers = [
          (n2c.buildLayer { deps = [ haosSource ]; })
        ];
        copyToRoot = [ rootfs ];
        maxLayers = 5;
        config = imageConfig;
      };

      default = self.packages.${system}.haos-image;
    };
  };
}
