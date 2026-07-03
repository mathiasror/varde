# Shared building blocks for every varde image.
#
# An image module (images/<name>.nix) is a function
#   { pkgs, vardeLib, lib }: { description; latest?; variants = { "<tag>" = spec; }; }
# where each `spec` is:
#   { contents ? [], entrypoint, cmd ? null, env ? [], libc, fhs ? false,
#     stopSignal ? null, sbomExtraComponents ? [ ] }
# `contents` are language-specific store paths merged at image root (e.g. a
# runtime relocated under /runtime). `libc` ("musl" | "glibc" | null) is set by
# mkVariants or the base specs below — flake.nix reads it for the CI matrix and
# mkLibcEnv builds the FHS layout from it when `fhs = true`. `stopSignal` maps
# to the OCI StopSignal for daemons whose clean-shutdown signal isn't SIGTERM
# (see images/postgres.nix). Everything else below is added for free.
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

  # FHS-style loader + libc/libstdc++/libgcc_s so EXTERNALLY-compiled dynamic
  # binaries (a normal `cargo`/`gcc` build, a manylinux/musllinux wheel's .so, a
  # native node addon) find their loader at /lib(64)/ld-*.so and their libs at
  # /lib. Opt in via `fhs = true`. `libc` selects glibc or musl; the targets come
  # from the same package set used for the image's runtime, so there is never a
  # version mismatch.
  mkLibcEnv =
    pkgs: libc:
    let
      sel = if libc == "musl" then pkgs.pkgsMusl else pkgs;
      libcPkg = if libc == "musl" then sel.musl else sel.glibc;
      cxx = sel.stdenv.cc.cc.lib; # libstdc++.so.6 + libgcc_s.so.1
      libDirs = [
        "${libcPkg}/lib"
        "${cxx}/lib"
      ];
    in
    pkgs.runCommand "varde-${libc}-env" { } ''
      mkdir -p "$out/lib" "$out/lib64"
      for d in ${lib.escapeShellArgs libDirs}; do
        for so in "$d"/*.so*; do
          [ -e "$so" ] || continue
          ln -sfn "$so" "$out/lib/$(basename "$so")"
        done
      done
      # Dynamic loader at the conventional path(s): glibc ld-linux-*.so (both /lib
      # and /lib64) and musl ld-musl-<arch>.so.1 (/lib). One glob covers both.
      for ld in ${libcPkg}/lib/ld-*.so*; do
        [ -e "$ld" ] || continue
        ln -sfn "$ld" "$out/lib/$(basename "$ld")"
        ln -sfn "$ld" "$out/lib64/$(basename "$ld")"
      done
      mkdir -p "$out/usr"
      ln -s /lib "$out/usr/lib"
    '';

  # Expose a package output under <subdir> (e.g. "runtime") for a clean rootfs.
  # A symlink, not a copy: the copied binaries' RPATHs keep referencing the
  # original store path, so dockerTools ships the closure regardless — a copy
  # would put the whole payload in the image twice (python/node/jre near-double).
  relocate =
    pkgs: name: subdir: src:
    pkgs.runCommand name { } ''
      mkdir -p "$out"
      ln -s ${src} "$out/${subdir}"
    '';

  # --- libc axis ------------------------------------------------------------

  # Cross version-tags with libcs into libc-qualified variants. `spec` is a
  # function of the libc's package set (`pkgs` for glibc, `pkgs.pkgsMusl` for
  # musl), so the runtime is built against the right libc. A version may restrict
  # `libcs` (e.g. jre-17 is glibc-only where no musl prebuilt exists).
  #   versions :: { "<tag>" = { spec = libcPkgs: <spec-without-libc>; libcs ? [ "musl" "glibc" ]; }; }
  #   result   :: { "<tag>-<libc>" = <spec with libc set>; }
  mkVariants =
    pkgs:
    { versions }:
    lib.listToAttrs (lib.concatLists (lib.mapAttrsToList (
      tag: v:
      map (
        libc:
        let
          libcPkgs = if libc == "musl" then pkgs.pkgsMusl else pkgs;
        in
        lib.nameValuePair "${tag}-${libc}" ((v.spec libcPkgs) // { inherit libc; })
      ) (v.libcs or [ "musl" "glibc" ])
    ) versions));

  # Compiled-binary bases (single-variant, entrypoint runs /app/app). The libc is
  # the image's identity, so these are not on the libc-tag axis.
  staticSpec = { entrypoint = [ "/app/app" ]; libc = null; }; # scratch-like, no loader
  glibcSpec = {
    entrypoint = [ "/app/app" ];
    libc = "glibc";
    fhs = true;
  };
  muslSpec = {
    entrypoint = [ "/app/app" ];
    libc = "musl";
    fhs = true;
  };

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
    ++ lib.optional (spec.fhs or false) (mkLibcEnv pkgs (spec.libc or "glibc"))
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
        # Contents are merged by symlink, leaving the identity files pointing at
        # absolute /nix/store paths. Docker 29 resolves them via Go's os.Root,
        # which rejects absolute symlinks (exec user lookup breaks), so
        # materialize them as regular files.
        for f in etc/passwd etc/group etc/nsswitch.conf; do
          if [ -L "$f" ]; then
            cp --remove-destination "$(readlink -f "$f")" "$f"
          fi
        done
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
          "org.opencontainers.image.source" = "https://github.com/mathiasror/varde";
          "org.opencontainers.image.url" = "https://rorvik.xyz";
          "org.opencontainers.image.licenses" = "Apache-2.0";
          "org.opencontainers.image.base.name" = "scratch";
        };
      }
      // lib.optionalAttrs (spec ? cmd && spec.cmd != null) { Cmd = spec.cmd; }
      // lib.optionalAttrs (spec ? stopSignal && spec.stopSignal != null) {
        StopSignal = spec.stopSignal;
      };
    };

  # One hand-authored CycloneDX component carrying an exact NVD CPE identity.
  # `product` is the CPE product field (may contain CPE escapes, e.g.
  # erlang\/otp); `name` is the plain component/purl name when they differ.
  sbomComponent =
    {
      vendor,
      product,
      version,
      name ? product,
    }:
    {
      type = "application";
      "bom-ref" = "varde-extra-${name}-${version}";
      inherit name version;
      cpe = "cpe:2.3:a:${vendor}:${product}:${version}:*:*:*:*:*:*:*";
      purl = "pkg:generic/${name}@${version}";
    };

  # CycloneDX SBOM (with CPEs) over the runtime closure of everything in the
  # image — system packages (glibc, zlib, …) plus the language runtime. Exposed
  # as an app because sbomnix needs nix-store access (cannot run in a sandbox).
  #
  # The generated SBOM is best-effort in two ways this app corrects by
  # appending hand-authored components:
  #   1. sbomnix derives every CPE as vendor = product = pname, but NVD files
  #      CVEs under normalized vendors (gnu:glibc, oracle:mysql,
  #      python_software_foundation:cpython, f5:nginx, …) — a wrong vendor
  #      matches nothing, silently. The libc component is appended here from
  #      spec.libc; runtimes with a non-obvious NVD identity append theirs via
  #      spec.sbomExtraComponents (find the identity with
  #      `grype db search pkg <name>`), with the version wired to the same
  #      package binding that builds the image so a nixpkgs bump moves both.
  #   2. Pruned runtimes (mysql, rabbitmq/erlang — and the stripped python/node
  #      copies) sever their store references to the upstream package, so the
  #      shipped software is not even a named component in its own closure.
  buildSbomApp =
    pkgs:
    { name, spec }:
    let
      closure = pkgs.runCommand "${name}-closure" { contents = imageContents pkgs spec; } ''
        mkdir -p "$out"
        for p in $contents; do ln -s "$p" "$out/$(basename "$p")"; done
      '';
      libcComponents =
        if (spec.libc or null) == "musl" then
          [
            (sbomComponent {
              vendor = "musl-libc";
              product = "musl";
              version = pkgs.musl.version;
            })
          ]
        else if (spec.libc or null) == "glibc" then
          [
            (sbomComponent {
              vendor = "gnu";
              product = "glibc";
              version = pkgs.glibc.version;
            })
          ]
        else
          [ ]; # varde-static ships no libc
      extraComponents = libcComponents ++ (spec.sbomExtraComponents or [ ]);
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
          ${lib.optionalString (extraComponents != [ ]) ''
            # NVD-identity components (see the comment on buildSbomApp).
            ${pkgs.jq}/bin/jq --argjson extra ${lib.escapeShellArg (builtins.toJSON extraComponents)} \
              '.components += $extra' "$out" > "$out.tmp" && mv "$out.tmp" "$out"
          ''}
          echo "Wrote CycloneDX SBOM (system packages + runtime) to $out"
        '';
      };
    in
    {
      type = "app";
      program = "${app}/bin/${name}-sbom";
    };
}
