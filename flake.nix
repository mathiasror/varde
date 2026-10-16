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
  inputs.nixpkgs-tools.url = "github:NixOS/nixpkgs/624af665418d3c65d544145b4d34ad696439570e";

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

      # One flat list of every {image, tag, attr, sbomName, drv, sbomApp} for a
      # system. String fields are system-independent (used to derive CI matrix).
      entriesFor =
        system:
        let
          pkgs = pkgsBySystem.${system};
          # SBOM machinery from the pinned input (see `nixpkgs-tools` above) —
          # image contents keep coming from the moving `pkgs`.
          toolsPkgs = import nixpkgs-tools { inherit system; };
        in
        lib.concatLists (
          lib.mapAttrsToList (
            image: m:
            lib.mapAttrsToList (tag: spec: {
              inherit image tag;
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
              attr = "image-${image}-${sanitize tag}";
              sbomName = "sbom-${image}-${sanitize tag}";
              drv = vardeLib.buildImage pkgs {
                name = "varde-${image}";
                inherit tag;
                inherit (m) description;
                inherit spec;
              };
              sbomApp = vardeLib.buildSbomApp pkgs toolsPkgs {
                name = "varde-${image}-${sanitize tag}";
                inherit spec;
              };
            }) m.variants
          ) evaluated.${system}
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

      # `nix eval --json .#ciMatrix`     -> [{image,tag,attr,sbomName,libc}, ...]
      # `nix eval --json .#latestTags`   -> {jre="21"; python="3.13"; ...}  (version; CI resolves default libc)
      # `nix eval --json .#imageAliases` -> {go="static"; rust="glibc";}    (published as mirror digests)
      ciMatrix = map (e: { inherit (e) image tag attr sbomName libc; }) (entriesFor "x86_64-linux");
      inherit latestTags;
      imageAliases = {
        go = "static";
        rust = "glibc";
      };
    };
}
