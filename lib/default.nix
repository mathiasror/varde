# Shared building blocks for every varde image.
#
# An image module (images/<name>.nix) is a function
#   { pkgs, vardeLib, lib }: { description; latest?; variants = { "<tag>" = spec; }; }
# where each `spec` is:
#   { contents ? [], entrypoint, cmd ? null, env ? [], fhs ? false }
# `contents` are language-specific store paths merged at image root (e.g. a
# runtime relocated under /runtime). Everything else below is added for free.
{ nixpkgs }:
let
  lib = nixpkgs.lib;
in
rec {
  inherit lib;

  # --- shared rootfs pieces -------------------------------------------------

  # Non-root `app` user (1000:1000); no shell is referenced (/noshell).
  mkEtc =
    pkgs:
    pkgs.runCommand "varde-etc" { } ''
      mkdir -p "$out/etc"
      printf 'root:x:0:0:root:/:/noshell\napp:x:1000:1000:app:/app:/noshell\n' > "$out/etc/passwd"
      printf 'root:x:0:\napp:x:1000:\n' > "$out/etc/group"
      printf 'hosts: files dns\n' > "$out/etc/nsswitch.conf"
    '';

  # CA bundle at the conventional path (HTTPS for Go/Rust/Python/Node).
  mkCerts =
    pkgs:
    pkgs.runCommand "varde-certs" { } ''
      mkdir -p "$out/etc/ssl/certs"
      ln -s ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt "$out/etc/ssl/certs/ca-certificates.crt"
    '';

  # Timezone database at the conventional path.
  mkTz =
    pkgs:
    pkgs.runCommand "varde-tz" { } ''
      mkdir -p "$out/usr/share"
      ln -s ${pkgs.tzdata}/share/zoneinfo "$out/usr/share/zoneinfo"
    '';

  # FHS-style glibc + libstdc++/libgcc_s so EXTERNALLY-compiled dynamic binaries
  # (a normal `cargo build`, a manylinux wheel's .so, a native node addon) find
  # their loader at /lib64/ld-linux-*.so and their libs at /lib. Opt in via
  # `fhs = true`. The symlinks target the same nixpkgs glibc used everywhere
  # else, so there is never a version mismatch.
  mkFhsEnv =
    pkgs:
    let
      libDirs = [
        "${pkgs.glibc}/lib"
        "${pkgs.stdenv.cc.cc.lib}/lib"
      ];
    in
    pkgs.runCommand "varde-fhs-env" { } ''
      mkdir -p "$out/lib" "$out/lib64"
      for d in ${lib.escapeShellArgs libDirs}; do
        for so in "$d"/*.so*; do
          [ -e "$so" ] || continue
          ln -sfn "$so" "$out/lib/$(basename "$so")"
        done
      done
      # Dynamic loader at the conventional path for both arches (/lib and /lib64).
      for ld in ${pkgs.glibc}/lib/ld-*.so*; do
        [ -e "$ld" ] || continue
        ln -sfn "$ld" "$out/lib/$(basename "$ld")"
        ln -sfn "$ld" "$out/lib64/$(basename "$ld")"
      done
      mkdir -p "$out/usr"
      ln -s /lib "$out/usr/lib"
    '';

  # Copy a package output under <subdir> (e.g. "runtime") for a clean rootfs.
  relocate =
    pkgs: name: subdir: src:
    pkgs.runCommand name { } ''
      mkdir -p "$out/${subdir}"
      cp -a ${src}/. "$out/${subdir}/"
    '';

  # --- assembly -------------------------------------------------------------

  commonEnv = [
    "LANG=C.UTF-8"
    "LC_ALL=C.UTF-8"
    "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
    "SSL_CERT_DIR=/etc/ssl/certs"
    "TZDIR=/usr/share/zoneinfo"
  ];

  # The full content set of an image: shared scaffolding + the module's bits.
  imageContents =
    pkgs: spec:
    [
      (mkEtc pkgs)
      (mkCerts pkgs)
      (mkTz pkgs)
    ]
    ++ lib.optional (spec.fhs or false) (mkFhsEnv pkgs)
    ++ (spec.contents or [ ]);

  buildImage =
    pkgs:
    {
      name,
      tag,
      description,
      spec,
    }:
    pkgs.dockerTools.buildLayeredImage {
      inherit name tag;
      contents = imageContents pkgs spec;
      extraCommands = ''
        mkdir -p app tmp
        chmod 1777 tmp
      '';
      fakeRootCommands = ''
        chown -R 1000:1000 ./app
      '';
      config = {
        User = "1000:1000";
        WorkingDir = "/app";
        Entrypoint = spec.entrypoint;
        Env =
          commonEnv
          ++ lib.optional (spec.fhs or false) "LD_LIBRARY_PATH=/lib:/lib64"
          ++ (spec.env or [ ]);
        Labels = {
          "org.opencontainers.image.title" = name;
          "org.opencontainers.image.description" = description;
          "org.opencontainers.image.base.name" = "scratch";
        };
      }
      // lib.optionalAttrs (spec ? cmd && spec.cmd != null) { Cmd = spec.cmd; };
    };

  # CycloneDX SBOM (with CPEs) over the runtime closure of everything in the
  # image — system packages (glibc, zlib, …) plus the language runtime. Exposed
  # as an app because sbomnix needs nix-store access (cannot run in a sandbox).
  buildSbomApp =
    pkgs:
    { name, spec }:
    let
      closure = pkgs.runCommand "${name}-closure" { contents = imageContents pkgs spec; } ''
        mkdir -p "$out"
        for p in $contents; do ln -s "$p" "$out/$(basename "$p")"; done
      '';
      app = pkgs.writeShellApplication {
        name = "${name}-sbom";
        # sbomnix 1.8 parses `nix derivation show` and requires the modern
        # `inputs` schema, but the nixpkgs `sbomnix` *wrapper* forces an older
        # bundled Nix (2.31) whose output still uses legacy `inputDrvs` — which
        # sbomnix then rejects. Put a current Nix (new schema) on PATH and call
        # sbomnix's underlying entry point directly, bypassing that wrapper.
        runtimeInputs = [ pkgs.nixVersions.latest ];
        text = ''
          out="''${1:-${name}.cdx.json}"
          case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
          # Run in a temp dir: sbomnix also drops sbom.spdx.json/sbom.csv in CWD.
          work="$(mktemp -d)"
          ( cd "$work" && ${pkgs.sbomnix}/bin/.sbomnix-wrapped "${closure}" --cdx "$out" )
          echo "Wrote CycloneDX SBOM (system packages + runtime) to $out"
        '';
      };
    in
    {
      type = "app";
      program = "${app}/bin/${name}-sbom";
    };
}
