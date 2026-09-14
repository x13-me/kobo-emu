{
  description = "Kobo Touch N905 (i.MX508 / Cortex-A8) emulator: boot stock firmware under QEMU (TCG)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  # Newer nixpkgs whose qemu (11.1.x) is close to the eink-emulator fork's
  # 11.0.2 base, so its patches have a chance of applying to the fork.
  inputs.nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs, nixpkgs-unstable }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forEachSystem = nixpkgs.lib.genAttrs supportedSystems;
      pkgsFor = system: import nixpkgs { inherit system; };

      emulatorToolchain = pkgs: with pkgs; [
        qemu
        gdb
        dtc
        e2fsprogs
        mtools
        ubootTools
        curl
        unzip
        xz
        gnutar
        file
        python3
        # User-mode track (scripts/run-usermode.sh + shims/): zig cross-builds
        # the ARM LD_PRELOAD shim (zig cc -target arm-linux-gnueabihf.2.11);
        # strace debugs guest syscalls; shellcheck + findutils keep the
        # hermetic `nix run` PATH complete (find, timeout, shellcheck).
        zig
        strace
        shellcheck
        findutils
        # Scripts assume these under `nix run`'s hermetic PATH (writeShellApplication
        # only wraps runtimeInputs): boot-kobo.sh needs timeout(1)+grep,
        # build-sd.sh needs sfdisk.
        coreutils
        gnugrep
        util-linux
      ];
    in
    {
      packages = forEachSystem (system:
        let pkgs = pkgsFor system; in
        {
          fetch-firmware = pkgs.writeShellApplication {
            name = "fetch-firmware";
            runtimeInputs = with pkgs; [ curl unzip coreutils gnugrep gnutar ];
            text = builtins.readFile ./scripts/fetch-firmware.sh;
          };
          kobo-emu = pkgs.writeShellApplication {
            name = "kobo-emu";
            runtimeInputs = emulatorToolchain pkgs;
            text = builtins.readFile ./scripts/boot-kobo.sh;
          };
          build-sd = pkgs.writeShellApplication {
            name = "build-sd";
            runtimeInputs = emulatorToolchain pkgs;
            text = builtins.readFile ./scripts/build-sd.sh;
          };
          # Track B: user-mode Kobo userspace under qemu-arm with fb/touch
          # shims (no machine model needed). See scripts/run-usermode.sh.
          kobo-usermode = pkgs.writeShellApplication {
            name = "kobo-usermode";
            runtimeInputs = emulatorToolchain pkgs;
            text = builtins.readFile ./scripts/run-usermode.sh;
          };
          # Track A: QEMU fork with the imx50-kobotouch machine
          # (katadelos/qemu, branch eink-emulator). Built from the newer
          # nixpkgs so the 11.x build inputs/patches match the fork's base.
          qemu-kobo =
            let upkgs = import nixpkgs-unstable { inherit system; }; in
            upkgs.qemu.overrideAttrs (old: {
              version = "11.0.2-kobo+eink.973f5a8";
              src = pkgs.fetchFromGitHub {
                owner = "katadelos";
                repo = "qemu";
                rev = "973f5a8d7f4f54ab27c5198edb1fa9207671e945"; # eink-emulator branch tip (2026-09-04)
                hash = "sha256-BBL+IXqPDvXgQXeTo7CvuPxwATftQEH1MkU0tAESFMs=";
              };
              # skip-macos-icon.patch is already contained in the fork
              # (patch detects as reversed); drop macOS-only patches.
              # qemu-kobo-pll-lock.patch is our Track A fix: the i.MX50
              # guest relocks PLLs with UPEN alone (no RST), so model LRF
              # as establishing instantly on enable (see patches/).
              patches = (builtins.filter
                (p: baseNameOf (toString p) != "skip-macos-icon.patch")
                old.patches) ++ [ ./patches/qemu-kobo-pll-lock.patch ./patches/qemu-kobo-i2c-fix.patch ./patches/qemu-kobo-ddr-type.patch ];
              # The fork is a git checkout: meson subprojects (keycodemapdb,
              # berkeley-{softfloat,testfloat}, libvfio-user, ...) are unvendored
              # .wrap files, and meson cannot fetch them inside the nix sandbox
              # (no network -> "Subproject keycodemapdb is buildable: NO").
              # Vendor every missing C subproject directory from the pristine
              # upstream release tarball (upkgs.qemu.src, NOT old.src: with
              # finalAttrs-style overrideAttrs, old.* re-resolves against
              # the overridden version, so old.src points at a nonexistent
              # qemu-<our-version>.tar.xz). upkgs.qemu.src is a .tar.xz FILE,
              # not a directory, so extract it once and copy from the tree.
              # Rust *-rs wraps have no vendored sources in the tarball
              # either; meson skips them when no rustc is present (upstream
              # provides none in nativeBuildInputs), as do system-provided
              # (dtc, slirp via nixpkgs inputs) and default-disabled
              # (libblkio) wraps — leave those for meson to resolve.
              # Fail fast if any other wrap names a dir neither tree provides.
              postUnpack = (old.postUnpack or "") + ''
                upstreamDir="$(mktemp -d)"
                tar -xf "${upkgs.qemu.src}" -C "$upstreamDir"
                upstreamRoot=$(echo "$upstreamDir"/qemu-*/)
                for wrap in "$sourceRoot"/subprojects/*.wrap; do
                  name="$(basename "$wrap" .wrap)"
                  if [[ ! -d "$sourceRoot/subprojects/$name" ]]; then
                    if [[ -d "$upstreamRoot/subprojects/$name" ]]; then
                      echo "qemu-kobo: vendoring subproject $name from upstream tarball"
                      cp -r "$upstreamRoot/subprojects/$name" "$sourceRoot/subprojects/$name"
                      chmod -R u+w "$sourceRoot/subprojects/$name"
                    elif [[ "$name" == *-rs || "$name" == dtc || "$name" == slirp || "$name" == libblkio ]]; then
                      echo "qemu-kobo: leaving subproject $name for meson (mirrors upstream: system lib or rust-disabled)"
                    else
                      echo "qemu-kobo: ERROR: subproject '$name' missing from fork and upstream tarball" >&2
                      exit 1
                    fi
                  fi
                done
              '';
            });
          default = self.packages.${system}.kobo-emu;
        });

      apps = forEachSystem (system: {
        kobo-emu = {
          type = "app";
          program = nixpkgs.lib.getExe self.packages.${system}.kobo-emu;
        };
        fetch-firmware = {
          type = "app";
          program = nixpkgs.lib.getExe self.packages.${system}.fetch-firmware;
        };
        build-sd = {
          type = "app";
          program = nixpkgs.lib.getExe self.packages.${system}.build-sd;
        };
        kobo-usermode = {
          type = "app";
          program = nixpkgs.lib.getExe self.packages.${system}.kobo-usermode;
        };
        default = self.apps.${system}.kobo-emu;
      });

      devShells = forEachSystem (system:
        let pkgs = pkgsFor system; in
        {
          default = pkgs.mkShell {
            name = "kobo-emu-dev";
            packages = emulatorToolchain pkgs;
            shellHook = ''
              echo "kobo-emu dev shell ready"
              qemu-system-arm --version | head -1
            '';
          };
        });
    };
}
