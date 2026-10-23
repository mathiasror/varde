{
  description = "varde — minimal, secure, Nix-built distroless base images";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # SBOM/scan tooling pin, separate from the image-contents `nixpkgs` above.
  # The tooling used to ride the weekly bump, so when the July 13/20 2026 bumps
  # landed a nixpkgs where sbomnix-1.8.0 no longer built (its dependency
  # python3.14-df-diskcache-0.0.2 fails to compile), every CI build job went
  # red for two weeks — a tooling breakage, not an image problem. Pinned to an
  # exact rev (the July 27 2026 nixos-unstable bump, where sbomnix builds
  # again) so it moves only when a human edits this line; bump-lock.yml
  # deliberately updates only `nixpkgs`. A weekly bump can now only break the
  # image contents actually being rebuilt, never the machinery that packages
  # them. Follows nothing — nixpkgs has no inputs of its own.
  # Bumped to the Oct 15 2026 nixos-unstable rev for syft 1.54.0, which stops
  # giving every bundled PHP extension a bare upstream CPE (anchore/syft#5102:
  # ext/curl at the PHP version was emitted as cpe:…:curl:curl:8.5.11 and
  # haxx:curl, i.e. 43 phantom curl CVEs) — the version `grype <image>` already
  # ships, so the attested SBOM and a user's scan agree again.
  inputs.nixpkgs-tools.url = "github:NixOS/nixpkgs/fe13242281a67641c0102cdb1087f0ebe586c7df";

  outputs =
    { self, nixpkgs, nixpkgs-tools }:
    let
      lib = nixpkgs.lib;
      # Linux-only: Nix can't build a Linux image on Darwin without a Linux builder.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems f;
      vardeLib = import ./lib { inherit nixpkgs; };
      vardeVex = import ./lib/vex.nix { inherit lib; };
      # OpenVEX wants RFC 3339. Use the source's commit time, not the wall
      # clock, so the document stays a pure function of the commit.
      vexTimestamp =
        let
          d = self.lastModifiedDate or "19700101000000";
          s = a: b: builtins.substring a b d;
        in
        "${s 0 4}-${s 4 2}-${s 6 2}T${s 8 2}:${s 10 2}:${s 12 2}Z";

      # Auto-discover image modules. Adding images/<name>.nix is all it takes for
      # a new image to appear in `nix build`, the SBOM apps, and CI.
      modules = lib.mapAttrs' (
        fname: _: lib.nameValuePair (lib.removeSuffix ".nix" fname) (import (./images + "/${fname}"))
      ) (lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".nix" n) (builtins.readDir ./images));

      # Dots are illegal in `nix build .#attr` paths, so 3.12 -> 3_12 for attrs;
      # the registry tag keeps the real "3.12".
      sanitize = lib.replaceStrings [ "." ] [ "_" ];

      # p11-kit 0.26.2's test-server.sh is racy when gnutls's p11tool is absent
      # (always, in the sandbox): it starts p11-kit-server, skips its only test,
      # then teardown `kill`s a server PID that has often already exited — and
      # common/test-init.sh runs under `set -euf`, so the failed kill fails the
      # whole check phase. Run 30795989594 shows the same drv passing in
      # jre:21-musl (arm64) and failing jre:25-musl (arm64) two minutes later —
      # a pure race, upstream-unfixed as of 0.26.2. Tolerating the dead server
      # keeps the other 66 checks (and the skip) intact. Musl-only on purpose:
      # glibc builds resolve from cache.nixos.org, and touching their p11-kit
      # drv would cache-miss every glibc image for no gain; musl builds come
      # from source into the varde cachix anyway, so only they pay the one-time
      # rebuild of the p11-kit -> gnutls -> cups -> temurin chain.
      p11kitTeardownRaceFix = final: prev: {
        p11-kit =
          if prev.stdenv.hostPlatform.isMusl then
            prev.p11-kit.overrideAttrs (old: {
              postPatch =
                (old.postPatch or "")
                + ''
                  substituteInPlace p11-kit/test-server.sh \
                    --replace-fail 'kill "$P11_KIT_SERVER_PID"' 'kill "$P11_KIT_SERVER_PID" 2>/dev/null || :'
                '';
            })
          else
            prev.p11-kit;
      };
      # sqlite's check phase (`make check` -> testrunner.tcl mdevtest) builds
      # fuzzcheck with ASan and UBSan, which musl does not support, so every
      # musl build fails ("FAILED: Build All-Debug (fuzzcheck-asan)" /
      # "(fuzzcheck-ubsan)", plus capi3c.test) — Hydra never builds musl, so
      # nobody upstream sees it. Every musl image reaches sqlite (python,
      # node, php, postgres, …), so this kept every musl leg red from
      # 2026-09-14 on. Musl-only for the same cache reason as p11kit above;
      # glibc sqlite still runs the full suite on Hydra, and the images'
      # runtime proof is CI's smoke tests + e2e.
      sqliteMuslNoCheck = final: prev: {
        sqlite =
          if prev.stdenv.hostPlatform.isMusl then
            prev.sqlite.overrideAttrs { doCheck = false; }
          else
            prev.sqlite;
      };
      # Two more musl-only check-phase failures from the nixpkgs of 2026-10-22
      # (02c087f3), which kept the jre and php musl legs red in bump run
      # 39850337188 on every attempt:
      #   - jemalloc 5.4.0's new unit test test_dss_primary_alloc_real_sbrk
      #     expects a real sbrk(), which musl deliberately does not provide
      #     (sbrk with a non-zero increment fails with ENOMEM), so it fails
      #     on every musl build, both arches;
      #   - boehm-gc 8.2.12's gctest aborts in incremental mode with "Signals
      #     delivery fails constantly" (seen on the jre:21-musl amd64 leg), a
      #     signal-timing test.
      # Musl-only, for the same cache reason as p11kit above; Hydra still runs
      # both suites for glibc.
      muslTestOnlyNoCheck = final: prev: {
        jemalloc =
          if prev.stdenv.hostPlatform.isMusl then
            prev.jemalloc.overrideAttrs { doCheck = false; }
          else
            prev.jemalloc;
        boehmgc =
          if prev.stdenv.hostPlatform.isMusl then
            prev.boehmgc.overrideAttrs { doCheck = false; }
          else
            prev.boehmgc;
      };
      # OpenSSL 3.5.9 (2026-09-29) fixes 13 CVEs, 4 rated High (CVE-2026-54873,
      # -72897, -84782, -84784). nixpkgs took it through staging (PR #568288),
      # which reached master on 2026-10-16 (staging-next #571813) but was still
      # missing from nixos-unstable on 2026-10-18. The tarball's sha256 is the
      # one nixpkgs master uses, so this changes the version and src only.
      # The patches are the same ones 3.5.8 uses.
      # Musl-only for the same cache reason as p11kit above: a glibc override
      # would cache-miss every glibc image's openssl dependents (python, curl,
      # postgres, php, node, ...) on both arches until the channel caught up.
      # Guarded on 3.5.8, so it turns into a no-op once a bump brings 3.5.9 or
      # newer. Delete it then. fetchurlBoot rather than fetchurl: fetchurl's
      # own curl links an override of this openssl, so a plain fetchurl here
      # would be an evaluation cycle.
      openssl359Musl = final: prev: {
        openssl_3_5 =
          if prev.stdenv.hostPlatform.isMusl && prev.openssl_3_5.version == "3.5.8" then
            prev.openssl_3_5.overrideAttrs rec {
              version = "3.5.9";
              src = final.stdenv.fetchurlBoot {
                url = "https://github.com/openssl/openssl/releases/download/openssl-${version}/openssl-${version}.tar.gz";
                hash = "sha256-YD9WAuLu8A13+9Qp003NWCK7MBdXobyc2yTGcPHrhZo=";
              };
            }
          else
            prev.openssl_3_5;
      };
      # One nixpkgs instantiation per system, shared by every consumer below.
      # Attribute sets memoize; a plain `pkgsFor = system: import nixpkgs …`
      # function does not (Nix never caches function application), so every
      # caller would pay a full nixpkgs import of its own.
      pkgsBySystem = lib.genAttrs systems (
        system:
        import nixpkgs {
          inherit system;
          overlays = [
            p11kitTeardownRaceFix
            sqliteMuslNoCheck
            muslTestOnlyNoCheck
            openssl359Musl
          ];
        }
      );

      # Every module evaluated once per system: { <image> = { description; latest?; variants; }; }
      evaluated = lib.genAttrs systems (
        system:
        lib.mapAttrs (
          image: mod:
          mod {
            pkgs = pkgsBySystem.${system};
            inherit vardeLib lib;
          }
        ) modules
      );

      # One flat list of every {image, tag, baseTag, debug, attr, sbomName,
      # drv, sbomApp} for a system: each variant, then its -debug sibling
      # (tag "<baseTag>-debug", debug = true). String fields are
      # system-independent (used to derive CI matrix).
      entriesFor =
        system:
        let
          pkgs = pkgsBySystem.${system};
          # SBOM machinery from the pinned input (see `nixpkgs-tools` above) —
          # image contents keep coming from the moving `pkgs`.
          toolsPkgs = import nixpkgs-tools { inherit system; };
        in
        lib.concatLists (
          lib.concatLists (
            lib.mapAttrsToList (
              image: m:
              lib.mapAttrsToList (
                tag: spec:
                let
                  drv = vardeLib.buildImage pkgs {
                    name = "varde-${image}";
                    inherit tag;
                    inherit (m) description;
                    inherit spec;
                  };
                  # The variant's -debug sibling: drv plus a busybox layer
                  # (lib/default.nix buildDebugImage). It is an entry of its
                  # own, so it gets its own package, SBOM app and VEX, but
                  # ciMatrix folds it into its base's row: CI builds and
                  # publishes both on one leg (see ciMatrix below).
                  debugDrv = vardeLib.buildDebugImage pkgs {
                    name = "varde-${image}";
                    tag = "${tag}-debug";
                    inherit (m) description;
                    inherit spec;
                    base = drv;
                  };
                  entry =
                    debug: drv:
                    let
                      t = if debug then "${tag}-debug" else tag;
                    in
                    {
                      inherit image debug drv;
                      tag = t;
                      baseTag = tag;
                      # `libc` is a required spec field (see the lib/default.nix header);
                      # imageContents and buildSbomApp read it without a default, so a
                      # module that bypasses mkVariants/the base specs fails here, at
                      # eval (CI's setup job evals .#ciMatrix), rather than shipping a
                      # libc the SBOM does not know about.
                      libc =
                        if spec ? libc then
                          spec.libc
                        else
                          throw "image '${image}': variant \"${tag}\" has no `libc` — build it with vardeLib.mkVariants or staticSpec/glibcSpec/muslSpec (see the lib/default.nix header)";
                      attr = "image-${image}-${sanitize t}";
                      sbomName = "sbom-${image}-${sanitize t}";
                      # SBOM of the image tarball itself (see buildSbomApp).
                      sbomApp = vardeLib.buildSbomApp pkgs toolsPkgs {
                        name = "varde-${image}-${sanitize t}";
                        inherit spec;
                        image = drv;
                      };
                    };
                in
                [
                  (entry false drv)
                  (entry true debugDrv)
                ]
              ) m.variants
            ) evaluated.${system}
          )
        );

      # Which tag each image publishes as :latest. A declared `latest` must name
      # a real variant: a plain tag for single-tag modules (static/glibc/musl),
      # or a bare version whose -musl/-glibc variant exists for libc-axis
      # (mkVariants) modules — build.yml appends the libc suffix itself. A
      # module without `latest` gets its sole plain tag; anything else errors
      # at eval (the setup job and bump-lock's sanity step eval .#latestTags),
      # rather than failing in the manifest job after every leg has built, or
      # silently re-pointing :latest at stale GHCR tags from an earlier publish.
      latestTags = lib.mapAttrs (
        image: m:
        let
          tags = lib.attrNames m.variants;
          isLibcTag = t: lib.hasSuffix "-musl" t || lib.hasSuffix "-glibc" t;
          libcAxis = lib.any isLibcTag tags;
          resolves =
            v:
            if libcAxis then
              !isLibcTag v && (lib.elem "${v}-musl" tags || lib.elem "${v}-glibc" tags)
            else
              lib.elem v tags;
        in
        if m ? latest then
          (
            if resolves m.latest then
              m.latest
            else
              throw "image '${image}': latest = \"${m.latest}\" names no variant (have: ${lib.concatStringsSep ", " tags}); fix `latest` in images/${image}.nix"
          )
        else if lib.length tags == 1 && !isLibcTag (lib.head tags) then
          lib.head tags
        else
          throw "image '${image}' needs `latest = \"<tag>\";` in images/${image}.nix (variants: ${lib.concatStringsSep ", " tags})"
      ) evaluated."x86_64-linux";

      imageAliases = {
        go = "static";
        rust = "glibc";
      };

      # Every tag a full publish moves in GHCR, for rebuild-watchdog.yml's
      # freshness check, so the watchdog follows the flake instead of keeping
      # its own list. Mirrors build.yml: the build job's per-arch tags
      # (<tag>-amd64/-arm64, one platform each), and the manifest job's lists
      # (both platforms): one per variant; for libc-axis images also the bare
      # version (default libc), :latest and, when a glibc variant of the latest
      # version exists, :latest-glibc; and for each image alias every source
      # tag plus :latest. If the manifest job's plan changes, change this too;
      # the job warns when the two disagree.
      # `nix eval --json .#publishedTags` -> [{image,tag,platforms}, ...]
      publishedTags =
        let
          arches = [
            "amd64"
            "arm64"
          ];
          both = map (a: "linux/${a}") arches;
          isLibcTag = t: lib.hasSuffix "-musl" t || lib.hasSuffix "-glibc" t;
          stripLibc = t: lib.removeSuffix "-glibc" (lib.removeSuffix "-musl" t);
          tagsOf = image: lib.attrNames evaluated."x86_64-linux".${image}.variants;
          # Every multi-arch list has a -debug twin (build.yml plan()); there
          # are no per-arch -debug tags.
          withDebug = tags: tags ++ map (t: "${t}-debug") tags;
          lists =
            image:
            let
              tags = tagsOf image;
              lv = latestTags.${image};
            in
            tags
            ++ lib.optionals (lib.any isLibcTag tags) (
              map stripLibc tags ++ [ "latest" ] ++ lib.optional (lib.elem "${lv}-glibc" tags) "latest-glibc"
            );
          forImage =
            image: _:
            map (tag: {
              inherit image tag;
              platforms = both;
            }) (withDebug (lists image))
            ++ lib.concatMap (
              tag:
              map (a: {
                inherit image;
                tag = "${tag}-${a}";
                platforms = [ "linux/${a}" ];
              }) arches
            ) (tagsOf image);
          forAlias =
            alias: src:
            map (tag: {
              image = alias;
              inherit tag;
              platforms = both;
            }) (withDebug (tagsOf src ++ [ "latest" ]));
        in
        lib.unique (
          lib.concatLists (lib.mapAttrsToList forImage evaluated."x86_64-linux")
          ++ lib.concatLists (lib.mapAttrsToList forAlias imageAliases)
        );
    in
    {
      packages = forAllSystems (
        system:
        let
          attrs = lib.listToAttrs (map (e: lib.nameValuePair e.attr e.drv) (entriesFor system));
        in
        attrs // lib.optionalAttrs (attrs ? "image-jre-21-musl") { default = attrs."image-jre-21-musl"; }
      );

      apps = forAllSystems (
        system: lib.listToAttrs (map (e: lib.nameValuePair e.sbomName e.sbomApp) (entriesFor system))
      );

      # `nix eval --json .#ciMatrix`     -> [{image,tag,attr,sbomName,libc,debugTag,debugAttr,debugSbomName}, ...]
      # `nix eval --json .#latestTags`   -> {jre="21"; python="3.14"; ...}  (version; CI resolves default libc)
      # `nix eval --json .#imageAliases` -> {go="static"; rust="glibc";}    (published as mirror digests)
      # `nix eval --json .#publishedTags` -> [{image,tag,platforms}, ...]  (every tag a publish moves)
      #
      # One row per production variant. Its -debug sibling rides on the same
      # row (debugTag/debugAttr/debugSbomName) instead of getting a row of its
      # own: build.yml builds, scans, signs and publishes it on the same leg,
      # reusing the base tarball, store closure and scanner DBs already there,
      # rather than paying a second runner, Nix install and closure fetch for
      # an image that is the base plus one busybox layer.
      ciMatrix =
        let
          entries = entriesFor "x86_64-linux";
          debugOf = lib.listToAttrs (
            map (e: lib.nameValuePair "${e.image}:${e.baseTag}" e) (lib.filter (e: e.debug) entries)
          );
        in
        map (
          e:
          let
            d = debugOf."${e.image}:${e.tag}";
          in
          {
            inherit (e)
              image
              tag
              attr
              sbomName
              libc
              ;
            debugTag = d.tag;
            debugAttr = d.attr;
            debugSbomName = d.sbomName;
          }
        ) (lib.filter (e: !e.debug) entries);

      # `nix eval --json .#vex.<system>.<sbomName>` -> the OpenVEX document for
      # that image (lib/vex.nix). CI passes it to grype (--vex) and attests it
      # next to the SBOM.
      vex = forAllSystems (
        system:
        lib.listToAttrs (
          map (
            e:
            lib.nameValuePair e.sbomName (
              vardeVex.vexFor {
                pkgs = pkgsBySystem.${system};
                inherit (e) image libc debug;
                timestamp = vexTimestamp;
                id = "https://github.com/mathiasror/varde/vex/${e.image}-${e.tag}-${system}@${self.rev or "dirty"}";
              }
            )
          ) (entriesFor system)
        )
      );
      inherit latestTags imageAliases publishedTags;
    };
}
