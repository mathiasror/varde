# Shared building blocks for every varde image.
#
# An image module (images/<name>.nix) is a function
#   { pkgs, vardeLib, lib }: { description; latest?; variants = { "<tag>" = spec; }; }
# `latest` must name a variant: the plain tag for a single-tag module, or the
# bare version (no libc suffix) for an mkVariants module — flake.nix's
# latestTags rejects anything else at eval time. Each `spec` is:
#   { contents ? [], entrypoint, cmd ? null, env ? [], libc, fhs ? false,
#     stopSignal ? null, sbomExtraComponents ? [ ], sbomStripCpes ? [ ],
#     closureAllow ? [ ], strip ? true }
# `contents` are language-specific store paths merged at image root (e.g. a
# runtime relocated under /runtime). `libc` ("musl" | "glibc" | null) is set by
# mkVariants or the base specs below — flake.nix reads it for the CI matrix (and
# rejects a variant without it at eval) and mkLibcEnv builds the FHS layout from
# it when `fhs = true`. `stopSignal` maps
# to the OCI StopSignal for daemons whose clean-shutdown signal isn't SIGTERM
# (see images/postgres.nix and images/nginx.nix). `strip` (default true)
# strips ELF symbol tables out of the assembled image (see stripImage below);
# set `strip = false` for a variant whose binaries must keep .symtab — e.g.
# one that reads its own symbols at runtime, or that breaks or cannot be
# vouched for after stripping. Everything else below is added for free.
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

  # --- CA trust -------------------------------------------------------------

  # NSS labels of roots varde distrusts on top of nixpkgs' cacert — the list
  # NixOS's own security.pki module carries (nixpkgs#576390), for images that
  # never see NixOS. The eMudhra intermediate key compromise (Oct 2026,
  # https://emudhra.we-have-a-problem.com/, Mozilla bug 2083449): eight
  # intermediates whose private keys are recoverable from their certificates,
  # each issued under `emSign ECC Root CA - G3` AND cross-signed by Sectigo's
  # `AAA Certificate Services` ("Comodo AAA Services root" in NSS; Mozilla
  # already trusts it for email only, but CVE-2026-111943 — and every bundle
  # consumer that ignores OpenSSL trust rules — is why NixOS drops it
  # entirely). NSS 3.131.1 removes the three emSign roots itself, and
  # buildcatrust fails (exit 3) on a blocklisted label the store no longer
  # has, so those three apply only below that version: the weekly bump that
  # brings 3.131.1 retires them on its own, and checkDistrust below proves
  # the upstream bundle still rejects the chains.
  distrustedRoots =
    cacert:
    [ "Comodo AAA Services root" ]
    ++ lib.optionals (lib.versionOlder cacert.version "3.131.1") [
      "emSign ECC Root CA - G3"
      "emSign Root CA - C1"
      "emSign ECC Root CA - C3"
    ];

  mkCacert = pkgs: pkgs.cacert.override { blacklist = distrustedRoots pkgs.cacert; };

  # Fails unless varde's trust really rejects the compromised chains in
  # ./distrust (public certificates; provenance in its README). Each chain is
  # first verified against its own root alone — it must pass, proving the
  # fixture is valid and the check can see it — then against `bundles`, where
  # it must fail. A typo'd label in distrustedRoots is a silent no-op to
  # cacert; this turns it into a red build. -no_check_time: a leaf expiring
  # must never make the check pass vacuously.
  checkDistrust =
    pkgs: bundles:
    pkgs.runCommand "varde-distrust-check" { nativeBuildInputs = [ pkgs.openssl ]; } ''
      d=${./distrust}
      verify() { openssl verify -purpose sslserver -no_check_time "$@" >/dev/null 2>&1; }
      for pair in emsign:emsign-ecc-root-ca-g3 aaa:aaa-certificate-services; do
        chain="''${pair%%:*}" root="''${pair#*:}"
        verify -CAfile "$d/$root.pem" -untrusted "$d/$chain-intermediates.pem" "$d/$chain-leaf.pem" \
          || { echo "distrust check: fixture '$chain' does not verify against its own root" >&2; exit 1; }
        for b in ${lib.escapeShellArgs bundles}; do
          if verify -CAfile "$b" -untrusted "$d/$chain-intermediates.pem" "$d/$chain-leaf.pem"; then
            echo "distrust check: $b still trusts the compromised '$chain' chain" >&2
            exit 1
          fi
        done
        echo "distrust check: '$chain' chain rejected by every bundle"
      done
      touch "$out"
    '';

  # CA bundle at the conventional path (HTTPS for Go/Rust/Python/Node — node
  # is built with --openssl-use-def-ca-store, so it reads this too, not its
  # compiled-in roots).
  mkCerts =
    pkgs:
    let
      cacert = mkCacert pkgs;
      certs = "${cacert}/etc/ssl/certs";
      check = checkDistrust pkgs [
        "${certs}/ca-bundle.crt"
        "${certs}/ca-no-trust-rules-bundle.crt"
      ];
    in
    pkgs.runCommand "varde-certs" { } ''
      # Interpolating the distrust check (${check}) makes it an input: no
      # image builds unless its bundle rejects the compromised chains.
      mkdir -p "$out/etc/ssl/certs"
      ln -s ${certs}/ca-bundle.crt "$out/etc/ssl/certs/ca-certificates.crt"
    '';

  # PKCS12 trust store for JREs that ship their own (Temurin's lib/security/
  # cacerts is the CA list of the OpenJDK source, frozen at release — it
  # still held `emSign ECC Root CA - G3` after NSS dropped it). Built from
  # cacert's server-auth-only bundle, NOT ca-bundle.crt: keytool ignores
  # OpenSSL trust rules, so an email-only root there would become a TLS root
  # in Java. Unencrypted and MAC-less like upstream's cacerts, because the
  # JDK opens it without a password. The keytool is the build host's; the
  # format is plain PKCS12, readable by every JRE varde ships (17+).
  mkJavaTrustStore =
    pkgs:
    let
      bundle = "${mkCacert pkgs}/etc/ssl/certs/ca-no-trust-rules-bundle.crt";
    in
    pkgs.runCommand "varde-java-cacerts"
      {
        nativeBuildInputs = [ pkgs.buildPackages.jdk_headless ];
        # The same proof as the PEM bundle, against the exact input.
        check = checkDistrust pkgs [ bundle ];
      }
      ''
        # One file per certificate, named after the NSS label printed above it.
        awk '/^-----BEGIN CERTIFICATE-----/ { n++; f = sprintf("cert-%03d.pem", n); print label > (f ".label") }
             f { print > f }
             /^-----END CERTIFICATE-----/ { close(f); f = "" }
             !/^-----/ && !f && NF { label = $0 }' ${bundle}
        for c in cert-*.pem; do
          alias="$(tr 'A-Z' 'a-z' < "$c.label" | tr -cs 'a-z0-9' '_' | sed 's/_$//')_''${c//[!0-9]/}"
          keytool -J-Dkeystore.pkcs12.certProtectionAlgorithm=NONE -J-Dkeystore.pkcs12.macAlgorithm=NONE \
            -importcert -noprompt -storetype PKCS12 -keystore "$out" -storepass changeit \
            -alias "$alias" -file "$c" >/dev/null
        done
        want=$(ls cert-*.pem | wc -l)
        got=$(keytool -list -storetype PKCS12 -keystore "$out" -storepass changeit | grep -c trustedCertEntry)
        [ "$want" = "$got" ] || { echo "java trust store: $got entries, bundle has $want" >&2; exit 1; }
        echo "java trust store: $got roots from ${bundle}"
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
      # Dynamic loader at the conventional paths: every ld-*.so* (glibc's
      # ld-linux-*.so, musl's ld-musl-<arch>.so.1) is linked into both /lib and
      # /lib64. Only glibc's PT_INTERP uses /lib64; the musl /lib64 link is
      # inert but harmless, and one glob covers both libcs.
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
    lib.listToAttrs (
      lib.concatLists (
        lib.mapAttrsToList (
          tag: v:
          map
            (
              libc:
              let
                libcPkgs = if libc == "musl" then pkgs.pkgsMusl else pkgs;
              in
              lib.nameValuePair "${tag}-${libc}" ((v.spec libcPkgs) // { inherit libc; })
            )
            (
              v.libcs or [
                "musl"
                "glibc"
              ]
            )
        ) versions
      )
    );

  # Compiled-binary bases (single-variant, entrypoint runs /app/app). The libc is
  # the image's identity, so these are not on the libc-tag axis.
  staticSpec = {
    entrypoint = [ "/app/app" ];
    libc = null;
  }; # scratch-like, no loader
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
    ++ lib.optional (spec.fhs or false) (mkLibcEnv pkgs spec.libc)
    ++ (spec.contents or [ ]);

  # --- contents-closure guard ------------------------------------------------

  # Store-path NAMES no varde image may ship: shells (the distroless promise),
  # coreutils, the package managers a runtime could smuggle in (nodejs' `npm`
  # output, python's pip), and -dev outputs (build-material leakage). POSIX
  # EREs matched against the <name> part of /nix/store/<hash>-<name>. The
  # guard is exactly this list — a shell nixpkgs names differently would slip
  # through, so extend it rather than assume. -bin outputs are deliberately
  # not banned: utility CLIs (sqlite-bin, zstd-bin) only ever entered a
  # closure via a propagating -dev referrer, which the -dev ban already severs
  # — and legitimate contents could plausibly carry a -bin name. pip's store
  # name is python3.<minor>-pip-<ver>, hence the prefix form (a `-pip$` suffix
  # would never match it).
  closureDenyPatterns = [
    "^(bash|dash|busybox|mksh|zsh|toybox|ksh|oksh|loksh|fish|tcsh|yash|nushell|es|rc)-"
    "^coreutils-"
    "-npm$"
    "^python3\\.[0-9]+-pip-"
    "-dev$"
  ];

  # Fails the image build if the CONTENTS' runtime closure ships anything
  # matching closureDenyPatterns. Deliberately checks the contents closure via
  # closureInfo, NOT the image derivation's build-time closure — the latter
  # always contains bash. Per-image exemptions via spec.closureAllow: EREs
  # matched against the FULL /nix/store/<hash>-<name> path (not just the
  # name), so an exemption can pin one exact derivation — postgres' deliberate
  # /bin/sh anchors `${p.busybox-sandbox-shell}` and admits nothing else that
  # happens to be named busybox-<version>. This turns the README's "no shell"
  # from an intention into an invariant: a nixpkgs bump that grows a shell,
  # coreutils, a package-manager output or a -dev output in any image's
  # closure turns the build red instead of publishing it.
  closureGuard =
    pkgs:
    {
      name,
      contents,
      allow ? [ ],
    }:
    pkgs.runCommand "${name}-closure-guard"
      {
        closure = pkgs.closureInfo { rootPaths = contents; };
        denyRegex = lib.concatStringsSep "|" closureDenyPatterns;
        # "^$" never matches a store path; it keeps an empty allow list a
        # valid ERE.
        allowRegex = lib.concatStringsSep "|" (allow ++ [ "^$" ]);
      }
      ''
        # closureInfo's registration file is the full reference graph — per
        # record: path, narHash, narSize, deriver (may be empty), N, then N
        # reference lines. Collect reverse edges so a violation names its
        # referrer, not just the offender.
        edges=$(mktemp)
        while IFS= read -r p; do
          IFS= read -r _narhash
          IFS= read -r _narsize
          IFS= read -r _deriver
          IFS= read -r n
          i=0
          while [ "$i" -lt "$n" ]; do
            IFS= read -r ref
            [ "$ref" = "$p" ] || printf '%s %s\n' "$ref" "$p" >> "$edges"
            i=$((i + 1))
          done
        done < "$closure/registration"

        bad=0
        while IFS= read -r p; do
          nm="''${p#/nix/store/}"
          nm="''${nm#*-}"
          if [[ "$nm" =~ $denyRegex ]] && ! [[ "$p" =~ $allowRegex ]]; then
            echo "closure guard: forbidden store path in image contents closure: $p" >&2
            grep -F -- "$p " "$edges" | while IFS= read -r edge; do
              echo "  referenced by: ''${edge#* }" >&2
            done
            bad=1
          fi
        done < "$closure/store-paths"
        if [ "$bad" != 0 ]; then
          echo "closure guard: ${name} ships a path on the closure deny list (shells, coreutils, npm/pip, -dev outputs; see above and closureDenyPatterns in lib/default.nix)" >&2
          exit 1
        fi
        touch "$out"
      '';

  buildImage =
    pkgs:
    {
      name,
      tag,
      description,
      spec,
    }:
    let
      contents = imageContents pkgs spec;
      guard = closureGuard pkgs {
        name = "${name}-${tag}";
        inherit contents;
        allow = spec.closureAllow or [ ];
      };
      args = imageArgs { inherit name tag contents guard spec description; };
    in
    # strip = false builds exactly the derivation this function built before
    # stripping existed (same drv, same store path), so opting out is free.
    if spec.strip or true then
      stripImage pkgs (pkgs.dockerTools.streamLayeredImage args)
    else
      pkgs.dockerTools.buildLayeredImage args;

  # The dockerTools arguments of an image, shared by the stripped
  # (streamLayeredImage + stripImage) and unstripped (buildLayeredImage) paths.
  imageArgs =
    {
      name,
      tag,
      contents,
      guard,
      spec,
      description,
    }:
    {
      inherit name tag contents;
      extraCommands = ''
        # Interpolating the closure guard (${guard}) makes it an input of this
        # layer derivation: the image cannot build unless the guard passed.
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
          commonEnv ++ lib.optional (spec.fhs or false) "LD_LIBRARY_PATH=/lib:/lib64" ++ (spec.env or [ ]);
        Labels = {
          "org.opencontainers.image.title" = name;
          "org.opencontainers.image.description" = description;
          "org.opencontainers.image.source" = "https://github.com/mathiasror/varde";
          "org.opencontainers.image.url" = "https://rorvik.xyz/varde/";
          "org.opencontainers.image.licenses" = "Apache-2.0";
          "org.opencontainers.image.base.name" = "scratch";
        };
      }
      // lib.optionalAttrs (spec ? cmd && spec.cmd != null) { Cmd = spec.cmd; }
      // lib.optionalAttrs (spec ? stopSignal && spec.stopSignal != null) {
        StopSignal = spec.stopSignal;
      };
    };

  # buildLayeredImage with ELF symbol tables stripped from the layers: the
  # stream script's uncompressed docker-archive is piped through
  # strip-image.py (its header has the details) and gzipped exactly as
  # buildLayeredImage gzips it, under the same `<name>.tar.gz` output name —
  # which CI's cachix pushFilter keys on to keep image tarballs out of the
  # cache — and with the same passthru (imageTag, stream, …).
  #
  # Why at assembly time: nixpkgs strips debug info only (-S), leaving
  # .symtab/.strtab in ~98% of a closure's ELF files, and rebuilding packages
  # with --strip-all would change every store hash — every glibc variant would
  # lose cache.nixos.org and compile from source. Rewriting file contents
  # inside the layer tarballs leaves every store path NAME untouched (RPATHs,
  # PT_INTERP, symlinks, syft's Nix cataloger all key on names) while keeping
  # buildLayeredImage's one-layer-per-store-path layout, which a stripped
  # closure copied in by extraCommands (includeStorePaths = false) would
  # collapse into a single layer. Measured on the published images: −0.1 MB
  # (memcached) to −5 MB (mysql) gzipped per image, with syft's component set
  # (names, versions, CPEs, catalogers) identical before and after —
  # the version strings its binary classifiers match live in .rodata, which
  # strip never touches.
  #
  # The strip tool and python come from the image's own `pkgs` (glibc set,
  # cache.nixos.org): build-time only, never in the image closure. The result
  # is a pure function of the stream and llvm-strip, so images stay
  # reproducible.
  stripImage =
    pkgs: stream:
    pkgs.runCommand "${baseNameOf stream.imageName}.tar.gz"
      {
        inherit (stream) imageName;
        passthru = stream.passthru // {
          inherit (stream) imageTag;
          inherit stream;
        };
        nativeBuildInputs = [ pkgs.pigz ];
      }
      ''
        set -o pipefail
        ${stream} \
          | ${pkgs.python3.interpreter} -I ${./strip-image.py} \
              ${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-strip \
          | pigz -p"$NIX_BUILD_CORES" -nTR > "$out"
      '';

  # One hand-authored CycloneDX component carrying an exact NVD CPE identity.
  # `product` is the CPE product field (may contain CPE escapes, e.g.
  # erlang\/otp); `name` is the plain component/purl name when they differ.
  #
  # An extra component is THE identity of its software: buildSbomApp drops
  # every syft-derived component whose CPE has the same vendor:product (e.g.
  # syft's binary-cataloger `oracle:openjdk`, `nodejs:node.js`), so one CVE
  # yields one finding, not one per cataloger. `supersedes` lists further
  # vendor:product pairs that name the same software under another NVD
  # identity (syft's `python_software_foundation:python` for CPython) and
  # must be dropped too. Carried as CycloneDX properties so the component
  # stays schema-valid.
  sbomComponent =
    {
      vendor,
      product,
      version,
      name ? product,
      supersedes ? [ ],
    }:
    {
      type = "application";
      "bom-ref" = "varde-extra-${name}-${version}";
      inherit name version;
      cpe = "cpe:2.3:a:${vendor}:${product}:${version}:*:*:*:*:*:*:*";
      purl = "pkg:generic/${name}@${version}";
    }
    // lib.optionalAttrs (supersedes != [ ]) {
      properties = map (value: {
        name = "varde:supersedes";
        inherit value;
      }) supersedes;
    };

  # jq program for buildSbomApp: drop syft components an extra component
  # supersedes (same CPE vendor:product as an extra, or listed in an extra's
  # varde:supersedes properties — matched on .cpe AND syft's alternative
  # syft:cpe23 properties), prune their dangling dependency edges, then append
  # the extras. Splitting a CPE on ":" is safe: CPE escapes are `\/`, `\.`, …,
  # never `\:` in the vendor/product fields we emit.
  sbomDedupeJq = toolsPkgs: toolsPkgs.writeText "varde-sbom-dedupe.jq" ''
    def cpeKey: split(":") | "\(.[3]):\(.[4])";
    def cpesOf: [.cpe // empty]
      + [(.properties // [])[] | select(.name == "syft:cpe23") | .value];
    def superseded($ids): cpesOf | any(.[]; cpeKey | IN($ids[]));
    ($extra | map(.cpe | cpeKey)
      + map((.properties // [])[] | select(.name == "varde:supersedes") | .value)) as $ids
    | ([.components[] | select(superseded($ids)) | ."bom-ref" // empty]) as $dropped
    | .components |= map(select(superseded($ids) | not))
    | if has("dependencies") then
        .dependencies |= map(
          select(.ref | IN($dropped[]) | not)
          | if has("dependsOn") then .dependsOn |= map(select(IN($dropped[]) | not)) else . end)
      else . end
    | .components += $extra
  '';

  # CycloneDX SBOM (with CPEs) of the built image — system packages (glibc,
  # zlib, …) plus the language runtime — read by syft straight from the image
  # tarball. syft's Nix cataloger recognises the /nix/store paths inside the
  # layers, i.e. exactly the runtime closure that ships, and it is the same
  # cataloger `grype <image>` runs, so the SBOM CI scans and attests matches
  # what a user gets from scanning the pulled image.
  #
  # Reading the image, not the Nix store, is deliberate. The previous
  # generator (sbomnix) walked the store closure, so `nix run` had to realise
  # every package in it even when the image tarball itself came from cache —
  # and with musl builds evicted from Cachix, each SBOM step recompiled
  # openssl/cmake/postgresql/… from source (45 min for postgres:17-musl in
  # run 39024610044). The tarball is all this app needs.
  #
  # The generated SBOM is best-effort in two ways this app corrects by
  # appending hand-authored components:
  #   1. syft derives Nix packages' CPEs as vendor = product = pname, but NVD
  #      files CVEs under normalized vendors (gnu:glibc, oracle:mysql,
  #      python_software_foundation:cpython, f5:nginx, …) — a wrong vendor
  #      matches nothing, silently. The libc component is appended here from
  #      spec.libc; runtimes with a non-obvious NVD identity append theirs via
  #      spec.sbomExtraComponents (find the identity with
  #      `grype db search pkg <name>`), with the version wired to the same
  #      package binding that builds the image so a nixpkgs bump moves both.
  #   2. Pruned runtimes (mysql, rabbitmq/erlang — and the stripped python/node
  #      copies) sever their store references to the upstream package, so the
  #      shipped software is not even a named component in its own closure.
  # and one it corrects by removing identities:
  #   3. A component can carry a CPE that names a DIFFERENT product. PHP is
  #      the case: every bundled extension (ext/curl, ext/calendar, …) is
  #      cataloged at the PHP version, and its CPE collides with an unrelated
  #      NVD product — syft < 1.54 emitted cpe:…:curl:curl:8.5.11 for
  #      curl.so (43 phantom curl CVEs), and php-calendar:php-calendar is a
  #      separate PHP web app in NVD. spec.sbomStripCpes lists
  #      { foundBy ? <syft cataloger>; name = <regex on component name>; }
  #      rules; matching components keep their name/version/purl but lose
  #      every CPE (the `cpe` field and syft's extra syft:cpe23 properties,
  #      which grype also reads). Only for components whose code is already
  #      covered by another component's correct CPE — for PHP, php:php on
  #      the php/php-cli/php-fpm components — so no real CVE goes unmatched.
  #
  # Two package sets, deliberately: `pkgs` (the moving image nixpkgs) supplies
  # the component versions — those MUST track what is actually shipped.
  # `toolsPkgs` (the flake's pinned `nixpkgs-tools` input) supplies the
  # machinery: syft, jq, and the writeShellApplication wrapper. Split after the
  # July 2026 weekly bumps, where the SBOM tool of the day (sbomnix) stopped
  # building and that one tooling breakage failed every image's CI job for two
  # weeks — the tooling must not ride the same moving nixpkgs as the images it
  # packages.
  buildSbomApp =
    pkgs: toolsPkgs:
    {
      name,
      spec,
      image,
    }:
    let
      # NVD identities per libc; a null libc (varde-static) contributes none.
      # `libc` is required (flake.nix's entriesFor throws on a spec without
      # it), so no default here: a fallback could append a libc component the
      # image does not actually ship.
      libcIds = {
        musl = {
          vendor = "musl-libc";
          product = "musl";
          version = pkgs.musl.version;
        };
        glibc = {
          vendor = "gnu";
          product = "glibc";
          version = pkgs.glibc.version;
        };
      };
      libc = spec.libc;
      libcComponents = lib.optionals (libc != null) [ (sbomComponent libcIds.${libc}) ];
      extraComponents = libcComponents ++ (spec.sbomExtraComponents or [ ]);
      stripCpes = spec.sbomStripCpes or [ ];
      # Drop the CPEs of components matching a spec.sbomStripCpes rule (see
      # 3. above). Runs before the extras are merged in.
      stripJq = toolsPkgs.writeText "${name}-sbom-strip.jq" ''
        def foundBy: [(.properties // [])[] | select(.name == "syft:package:foundBy") | .value][0];
        def stripped($rules): foundBy as $fb | .name as $n
          | any($rules[]; (.foundBy == null or .foundBy == $fb) and (.name as $re | $n | test($re)));
        .components |= map(
          if stripped($strip) then
            del(.cpe) | .properties = [(.properties // [])[] | select(.name != "syft:cpe23")]
          else . end)
      '';
      app = toolsPkgs.writeShellApplication {
        name = "${name}-sbom";
        runtimeInputs = [ toolsPkgs.gzip ];
        text = ''
          out="''${1:-${name}.cdx.json}"
          case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
          work="$(mktemp -d)"
          trap 'rm -rf "$work"' EXIT
          # syft's docker-archive source rejects a gzipped tarball ("invalid
          # tar header"), and buildLayeredImage emits .tar.gz.
          gzip -dc ${image} > "$work/image.tar"
          SYFT_CHECK_FOR_APP_UPDATE=false ${toolsPkgs.syft}/bin/syft -q \
            "docker-archive:$work/image.tar" -o "cyclonedx-json=$out"
          ${lib.optionalString (stripCpes != [ ]) ''
            ${toolsPkgs.jq}/bin/jq --argjson strip ${lib.escapeShellArg (builtins.toJSON stripCpes)} \
              -f ${stripJq} "$out" > "$work/stripped.cdx.json"
            mv "$work/stripped.cdx.json" "$out"
          ''}
          ${lib.optionalString (extraComponents != [ ]) ''
            # NVD-identity components (see the comment on buildSbomApp). Two
            # separate statements, not an `&&` list: bash exempts every command
            # but the last of an `&&` list from errexit, so a failing jq would
            # skip the mv and let the app report success with the raw syft
            # output — which still passes CI's "components non-empty" check
            # while lacking exactly the components this step exists to add.
            # The temp file lives in $work so the EXIT trap cleans it up.
            # The extras replace any syft component with the same NVD identity
            # (see sbomComponent / sbomDedupeJq): syft's binary cataloger
            # finds e.g. python3.13 as `python_software_foundation:python`
            # while the extra is `…:cpython`, and both matched every CPython
            # CVE — two alerts per CVE. One identity per runtime, always the
            # extra: its version is wired to the Nix binding, not a heuristic.
            ${toolsPkgs.jq}/bin/jq --argjson extra ${lib.escapeShellArg (builtins.toJSON extraComponents)} \
              -f ${sbomDedupeJq toolsPkgs} "$out" > "$work/augmented.cdx.json"
            mv "$work/augmented.cdx.json" "$out"
            # Post-conditions: every appended component (bom-ref varde-extra-*,
            # see sbomComponent) must be present in the written file, and no
            # non-extra component may still carry an extra's CPE identity.
            ${toolsPkgs.jq}/bin/jq -e --argjson n ${toString (lib.length extraComponents)} \
              '(.components | map(select((."bom-ref" // "") | startswith("varde-extra-"))) | length) == $n' \
              "$out" > /dev/null
            ${toolsPkgs.jq}/bin/jq -e \
              '([.components[] | select((."bom-ref" // "") | startswith("varde-extra-")) | .cpe | split(":") | "\(.[3]):\(.[4])"]) as $ids
               | all(.components[] | select((."bom-ref" // "") | startswith("varde-extra-") | not);
                     [.cpe // empty][] | split(":") | "\(.[3]):\(.[4])" | IN($ids[]) | not)' \
              "$out" > /dev/null
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
