{
  description = "HAOS with virtio-fs and USB passthrough";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix2container.url = "github:nlewo/nix2container";
    base.url = "github:podmania/base";
  };

  outputs = { self, nixpkgs, nix2container, base }:
    let
      mkSystem = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          n2c = nix2container.outputs.packages.${system}.nix2container;

          # Dummy hashes
          haosImg_x86_64 = pkgs.fetchurl {
            url = "https://github.com/home-assistant/operating-system/releases/download/17.3/haos_generic-x86-64-17.3.img.xz";
            hash = "sha256-0000000000000000000000000000000000000000000000000000=";
            curlOpts = "--user-agent Mozilla/5.0";
          };
          haosXz_aarch64 = pkgs.fetchurl {
            url = "https://github.com/home-assistant/operating-system/releases/download/17.3/haos_generic-aarch64-17.3.qcow2.xz";
            hash = "sha256-0000000000000000000000000000000000000000000000000000=";
            curlOpts = "--user-agent Mozilla/5.0";
          };

          mkHaosContainer = { arch, isX86 ? false, haosSource }:
            let
              extraPackages = with pkgs; [ qemu OVMF virtiofsd xz ];

              entrypoint = pkgs.writeShellScript "entrypoint.sh" (builtins.readFile ./entrypoint.sh);

              entrypointFixed = pkgs.runCommand "entrypoint-fixed" {} ''
                sed -e "s|\${OVMF_FD}|${pkgs.OVMF.fd}/FV|g" \
                    -e "s|\${OVMF_VARS}|${pkgs.OVMF.fd}/FV|g" \
                    -e "s|\${haosSource}|${haosSource}|g" \
                    -e "s|isX86=\"false\"|isX86=\"${if isX86 then "true" else "false"}\"|g" \
                    ${entrypoint} > $out
                chmod +x $out
              '';

              baseEnv = pkgs.buildEnv {
                name = "haos-base";
                paths = extraPackages;
                pathsToLink = [ "/bin" ];
              };

              extraLayers = pkgs.symlinkJoin {
                name = "haos-extra";
                paths = [ baseEnv entrypointFixed ];
                buildInputs = [ pkgs.coreutils ];
                postBuild = ''
                  mkdir -p $out/run/virtiofsd
                  ln -sf ${entrypointFixed} $out/bin/entrypoint.sh
                  ln -sf ${pkgs.bashInteractive}/bin/bash $out/bin/sh
                '';
              };

              imageConfig = {
                Env = [ "CPU_CORES=2" "RAM_SIZE=4096" "FORWARD_PORT=8123" ];
                ExposedPorts = { "8123/tcp" = {}; };
                Volumes = { "/storage" = {}; "/config" = {}; };
                Entrypoint = [ "/bin/entrypoint.sh" ];
              };

            in n2c.buildImage {
              name = "home-assistant-os";
              tag = "latest";
              fromImage = base.packages.${system}.base-debug-image;
              copyToRoot = [ extraLayers ];
              maxLayers = 6;
              config = imageConfig;
            };

        in {
          haos-container-x86_64 = mkHaosContainer { arch = "x86_64"; isX86 = true; haosSource = haosImg_x86_64; };
          haos-container-aarch64 = mkHaosContainer { arch = "aarch64"; isX86 = false; haosSource = haosXz_aarch64; };
        };
    in
    {
      packages = {
        x86_64-linux = mkSystem "x86_64-linux";
        aarch64-linux = mkSystem "aarch64-linux";
      };
    };
}
